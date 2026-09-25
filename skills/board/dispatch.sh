#!/usr/bin/env bash
# Spawn (or resume) one detached board agent in its own git worktree.
#
# The card in Linear is the lock. This script assumes the caller has ALREADY
# moved the card out of Todo — into Plan for a fresh build, since that is where
# a dispatched card starts. A spawn that precedes the move gets dispatched twice
# by the next tick.
#
#   dispatch.sh --ticket ABC-42 --role plan   --attempt 1 --prompt-file plan.md
#   dispatch.sh --ticket ABC-42 --role build  --attempt 1 --prompt-file brief.md
#   dispatch.sh --ticket ABC-42 --role review --attempt 1 --slot a \
#               --ref <pr-head-sha> --prompt-file review.md
#   dispatch.sh --ticket ABC-42 --role build  --attempt 1 --resume \
#               --reason ci-fix --prompt-file findings.md
#   dispatch.sh --ticket cleanup --role cleanup --attempt <yyyymmddHHMM> \
#               --prompt-file cleanup.md
#
# Prints the resolved agent id on success.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SKILL_DIR/config.sh"

# Strips TMPDIR from the preflight, resume and spawn calls below. See the
# note above `agent_tmp_for` for why.
NO_TMPDIR=(env -u TMPDIR)

TICKET="" ROLE="" ATTEMPT="" SLOT="" REF="" PROMPT_FILE="" RESUME="" REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --attempt) ATTEMPT="$2"; shift 2 ;;
    --slot) SLOT="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --reason) REASON="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TICKET" ]] || die "--ticket is required"
[[ "$ROLE" == "plan" || "$ROLE" == "build" || "$ROLE" == "review" || "$ROLE" == "cleanup" ]] \
  || die "--role must be plan, build, review or cleanup"
[[ -n "$ATTEMPT" ]] || die "--attempt is required"
[[ -n "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "--prompt-file must be readable"

# --reason is required on a build resume and refused everywhere else: it feeds
# reconcile.py's build_attempts arithmetic (a ci-fix or retry resume charges an
# attempt, a fix resume does not), so a resume it cannot classify must not
# proceed silently, and a role or spawn that arithmetic never reads must not
# carry one to go stale.
REASON_BAD=""
if [[ -n "$RESUME" && "$ROLE" == "build" ]]; then
  case "$REASON" in
    ci-fix|fix|retry) ;;
    *) REASON_BAD=1 ;;
  esac
elif [[ -n "$REASON" ]]; then
  REASON_BAD=1
fi
[[ -z "$REASON_BAD" ]] || die "--reason must be ci-fix, fix or retry, and only on --resume --role build"

NAME="$(agent_name "$TICKET" "$ROLE" "${ATTEMPT}${SLOT}")"
PROMPT="$(cat "$PROMPT_FILE")"
[[ -n "${PROMPT//[[:space:]]/}" ]] || die "prompt file is empty"

# Never spawn an agent into a machine that cannot build. On 2026-08-02 two
# consecutive attempts on one card were lost to a `/tmp` over its user quota:
# the first died mid-test-run leaving no branch and no pull request, and the
# second was dispatched into the identical broken environment because nothing
# looked. The
# gate belongs here rather than only in SKILL.md so that it holds however the
# script is called — by the tick, by a resume, or by hand.
#
# This runs on the resume path too. A resumed agent runs exactly the same tests
# as a fresh one and dies exactly the same way.
if ! PREFLIGHT="$("${NO_TMPDIR[@]}" "$SKILL_DIR/preflight.py" --quiet 2>&1)"; then
  printf '%s\n' "$PREFLIGHT" >&2
  die "environment is unfit to build; refusing to dispatch $NAME.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
fi

# THE EDGE-TRIGGER MUST BE ALIVE BEFORE ANYTHING IS DISPATCHED.
#
# A board whose Monitor is not armed still works: it dispatches, reviews and
# merges. It is slower by up to one TICK_INTERVAL_MINUTES on every finished
# agent, and no surface says so -- waiting looks exactly like running. Measured
# 2026-09-22 across five cards, dispatch to first commit ran from 38 minutes to
# 33 hours, against about five minutes for a hand-driven pull request in the
# same window.
#
# HELD HERE AND NOT ONLY IN SKILL.md, for the reason the preflight above is: a
# tick asked in prose to stop when a Monitor fails to arm may carry on instead,
# and that is the failure this gate exists to remove.
#
# MACHINE-WIDE, not this board alone. A rejected Monitor call is evidence about
# the harness contract, and every board on this machine shares one harness. A
# HALTED board is excluded: SKILL.md tells the tick to arm one Monitor for every
# board that is not halted, so counting a halted board's stale stamp made
# `boardctl halt` refuse every dispatch on every other board.
#
# `ok`, NOT `halt_ok`. This gate reads the tight window, because it runs inside
# a pass moments after the tick armed that pass's Monitors. supervise.sh reads
# the wide one, because it fires from cron at any moment -- including the
# heartbeat wait, where a Monitor capped at MONITOR_TIMEOUT_SECONDS has already
# expired on a healthy machine. config.sh derives both and states the
# arithmetic.
if ! STAMPS="$("$SKILL_DIR/reconcile.py" --monitor-stamps)"; then
  die "could not read the machine's monitor stamps; refusing to dispatch $NAME.
reconcile.py's own message is above: a boards.toml that will not load, or
foreman's own scripts being unrunnable.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
fi
# "reconcile.py ran and printed a verdict this gate cannot read" is NOT "the
# verdict is stale". A bare `if ! ... | python3 -c '...json.load...'` used to
# conflate the two: ANY exception in that inline script -- garbage on stdout,
# truncated output, a changed key name -- made the pipeline exit non-zero,
# which this gate read the same as "not ok" and answered with "no board...has
# a live agent Monitor", a raw Python traceback on stderr, and an empty
# "Stale or missing:" list. That sends the operator to arm a Monitor that is
# already armed, for a fault that is actually an unreadable reader. The inline
# python below catches its own parse errors and reports the distinction on
# stdout instead, so this gate can route on it without a traceback ever
# reaching the operator.
#
# THE CAPTURE ITSELF MUST NOT BE ABLE TO END THE SCRIPT OR TO PASS. It runs as
# the condition of an `if`, so a python3 that is off PATH, not executable or
# killed exits 127 or 137 here instead of tripping `set -e` into a bare,
# messageless exit. The verdict is then blanked, and the blank falls through to
# the "could not read" refusal below.
STAMPS_VERDICT=""
if ! STAMPS_VERDICT="$(printf '%s' "$STAMPS" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ok = bool(d["ok"])
except Exception as exc:
    print("UNREADABLE")
    print("%s: %s" % (type(exc).__name__, exc))
    sys.exit(0)
if ok:
    print("OK")
else:
    print("STALE")
    print(" ".join(d.get("stale") or []))
')"; then
  STAMPS_VERDICT=""
fi
STAMPS_STATUS="${STAMPS_VERDICT%%$'\n'*}"
STAMPS_DETAIL="${STAMPS_VERDICT#*$'\n'}"
# An empty verdict carries no detail either, and the branch below supplies its
# own wording for that case.
[[ "$STAMPS_VERDICT" == *$'\n'* ]] || STAMPS_DETAIL=""
# ONLY THE LITERAL VERDICT `OK` LETS A DISPATCH THROUGH, and every other value
# refuses. A command substitution hands back an empty string when python3 never
# ran -- off PATH, not executable, killed by the OOM reaper -- so a gate that
# routed only on the two named verdicts would fall through all of them and
# dispatch. The `if ! ... | python3 ...` form this replaced failed closed on
# exactly that, and the slot ceilings above record what the other way costs: a
# ceiling that could not read its own input silently stopped holding. A gate
# that cannot read its input refuses.
if [[ "$STAMPS_STATUS" == "STALE" ]]; then
  die "no board on this machine has a live agent Monitor; refusing to dispatch $NAME.
Stale or missing: $STAMPS_DETAIL
A board whose Monitor is not armed runs at heartbeat speed and says nothing.
Arm it as skills/board/SKILL.md describes, then dispatch again at the same
attempt number.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget."
elif [[ "$STAMPS_STATUS" != "OK" ]]; then
  die "could not read the machine's monitor stamps; refusing to dispatch $NAME.
This gate could not parse reconcile.py --monitor-stamps against its own JSON
contract: ${STAMPS_DETAIL:-the reader printed no verdict at all, so python3 itself is missing or unrunnable}
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
fi

# The concurrency ceilings, held here rather than only in SKILL.md.
#
# SKILL.md states the arithmetic exactly -- a board's free slots are its
# MAX_CONCURRENT minus its cards in progress and in review -- but that is prose
# an agent is asked to follow, and prose is not a gate. On 2026-09-01 a tick
# adopted five cards left In Progress by a previous layout and dispatched a build
# for each, against a MAX_CONCURRENT of 1. The machine reached a load average of
# 14 with four builds, a tick and a self-hosted CI runner competing for 14GB, and
# an earlier OOM had already killed that runner once the same night.
#
# So this refuses, for the same reason and in the same voice as the preflight
# gate above: it holds however this script is called -- by the tick, by a resume,
# or by hand -- rather than only when the caller remembers to count first.
#
# A card that ALREADY holds a slot is not consuming a new one. A resume, a fix,
# or a reviewer for a card the board is already working must pass: refusing
# those would block every fix-dispatch behind the card's own slot. That is why
# `--host-slots` reports which tickets are holding, not just how many.
#
# The MACHINE half of the arithmetic lives in `reconcile.py --may-dispatch`,
# which weighs each board's priority so one busy board cannot hold every slot.
# It is Python, and testable; the previous inline version was shell-embedded
# python where a single apostrophe closed the surrounding quoted string and
# disabled the whole gate with no error at all.
#
# A COUNT THAT CANNOT BE TAKEN REFUSES THE DISPATCH. This used to read
# `HELD="$(... 2>/dev/null || true)"` and then skip the whole gate when HELD
# was empty, so any failure of `--host-slots` -- a boards.toml that will not
# load is enough, and one unmounted repository path is enough for that --
# disabled both ceilings with nothing at all on stderr. That
# is the same silence this comment's own 2026-09-01 paragraph records, reached
# the other way round. reconcile.py's stderr is not captured, so whatever it
# could not read is named above this refusal.
if ! HELD="$("$SKILL_DIR/reconcile.py" --host-slots)"; then
  die "could not count the machine's slots; refusing to dispatch $NAME.
reconcile.py's own message is above: a boards.toml that will not load, or
foreman's own scripts being unrunnable.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
fi
# `--host-slots` counts every board declared in this machine's boards.toml and
# keys them by the BARE board name. There is one foreman, so a board name is
# already unique here; the key used to carry an installation segment, and
# reading it with the bare name made every lookup below miss, `held` come back
# empty, and this board's own ceiling pass a dispatch through however many
# cards were already in flight -- the gate disabled with no error at all. The
# shape lives in reconcile.py:host_slots and is spelled once on each side.
SLOT_KEY="$INSTANCE"
# No `try:` around the parse and no `|| true` on the pipeline any more. HELD is
# what json.dump wrote a moment ago, so a parse that fails here says python3
# itself is broken, and answering "this card holds no slot" to that is the
# disabled gate again.
ALREADY_HOLDS="$(printf '%s' "$HELD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
board, ticket = sys.argv[1], sys.argv[2]
held = (d.get("tickets") or {}).get(board) or []
print("yes" if ticket in held else "")
' "$SLOT_KEY" "$TICKET")" || die "could not read the slot count reconcile.py printed; refusing to dispatch $NAME.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget."

if [[ -z "$ALREADY_HOLDS" ]]; then
  # SAY THAT THIS BOARD WANTS A SLOT, before asking whether it may have one.
  # `--may-dispatch` reserves a floor only for boards that are asking, so a
  # board that never records the ask is read as idle and reserves nothing --
  # it would win its own dispatches and lose every slot it is owed to whichever
  # board asked most recently.
  #
  # Here, and not at the top of the script: a card that ALREADY holds a slot is
  # not asking for a new one, and stamping for it would keep a board's floor
  # reserved on the strength of resumes and fix-dispatches alone.
  #
  # A failed stamp WARNS rather than dies. It costs this board its share until
  # the next pass, which is unfairness and not a wrong dispatch, and every
  # cause of it -- an unwritable FOREMAN_HOME, a boards.toml that will not load
  # -- makes the two gates below die with a message that names the real fault.
  # Killing the card here would spend an attempt on a machine fault instead.
  if ! "$SKILL_DIR/reconcile.py" --wants-slot "$INSTANCE"; then
    printf 'foreman: could not record that %s wants a slot; it reserves nothing until the next pass\n' \
      "$INSTANCE" >&2
  fi
  # This board's own ceiling first, then the machine's.
  OWN="$(printf '%s' "$HELD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
board, board_max = sys.argv[1], int(sys.argv[2])
held = (d.get("tickets") or {}).get(board) or []
names = ", ".join(held)
if len(held) >= board_max:
    print(f"board {board} holds {len(held)} of {board_max} slots: {names}")
' "$SLOT_KEY" "$MAX_CONCURRENT")" || die "could not weigh this board against its own ceiling; refusing to dispatch $NAME.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget."
  # Refused the same way and for the same reason as `--host-slots` above: this
  # is the half of the arithmetic that weighs every OTHER board on the machine,
  # so a failure here is a machine ceiling nobody checked.
  if ! MACHINE="$(HOST_MAX_CONCURRENT="$HOST_MAX_CONCURRENT" \
    "$SKILL_DIR/reconcile.py" --may-dispatch "$INSTANCE")"; then
    die "could not weigh this machine's ceiling; refusing to dispatch $NAME.
reconcile.py's own message is above.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
  fi
  VERDICT="${OWN:-$MACHINE}"
  if [[ -n "$VERDICT" ]]; then
    die "at the concurrency ceiling; refusing to dispatch $NAME.
$VERDICT
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Wait for a card to release a slot, or raise the limit deliberately in the
target's board.toml (MAX_CONCURRENT) or this machine's boards.toml (priority)."
  fi
fi

# The model follows the STAGE, not the machine and not a global default. See
# PLAN_MODEL in config.sh for why the plan gets the strongest model and the
# build agents that execute it do not.
#
# A table rather than a chain: there are four roles now, each naming one model
# and one worktree shape, and a fifth would be one more row. `build` is the
# only role that writes to the card's own branch, so it is the only one cut
# with `-B <branch>`. A plan agent posts its graph to the Linear card as a
# comment and pushes nothing -- a branch on the card would be both unnecessary
# and harmful, since a build dispatched afterwards would inherit or reset it --
# so plan gets a throwaway worktree detached at origin/main, composing its own
# name the same way review composes its own from ticket, role and attempt so
# the two throwaway worktrees can never collide with each other or with the
# card's build worktree. A reviewer never writes to the branch either, so it
# gets a throwaway worktree detached at the head it is reading. A cleanup agent
# is a plan agent in every way that matters here -- it reads origin/main and
# files a card, and pushes nothing -- so it gets the identical throwaway shape,
# named from its own ticket ("cleanup") rather than a card's.
case "$ROLE" in
  plan)
    WORKTREE="$(worktree_path "${TICKET}-${ROLE}-${ATTEMPT}${SLOT}")"
    MODEL="$PLAN_MODEL"
    ;;
  build)
    WORKTREE="$(worktree_path "$TICKET")"
    MODEL="$BUILD_MODEL"
    ;;
  review)
    WORKTREE="$(worktree_path "${TICKET}-${ROLE}-${ATTEMPT}${SLOT}")"
    MODEL="$REVIEW_MODEL"
    ;;
  cleanup)
    WORKTREE="$(worktree_path "${TICKET}-${ROLE}-${ATTEMPT}${SLOT}")"
    MODEL="$CLEANUP_MODEL"
    ;;
esac

# The model a FRESH spawn runs on once a rate limit on the role's first choice
# is accounted for. skills/board/fallback.py walks FALLBACK_TIERS down from
# $MODEL while it stays limited, never past the role's floor, and says on
# stderr when it fell back. Skipped on --resume: the adapter's resume verb takes
# no --model, so a resumed agent keeps its session's model.
#
# config.sh assigns these knobs in this shell and does not export them -- that
# file is a high-risk path, and exporting them parked a previous change. Prefix
# every one fallback.py reads, including FOREMAN_HOME (already exported) so the
# child is self-contained. A broken helper must not stop all work, so a refusal
# spawns on the first choice, the model this role ran on before fallback.py
# existed, and says why.
FIRST_CHOICE_MODEL="$MODEL"
if [[ -z "$RESUME" ]]; then
  if ! MODEL="$(FOREMAN_HOME="$FOREMAN_HOME" \
      FALLBACK_TIERS="$FALLBACK_TIERS" \
      FALLBACK_COOLDOWN_MINUTES="$FALLBACK_COOLDOWN_MINUTES" \
      PLAN_MODEL="$PLAN_MODEL" BUILD_MODEL="$BUILD_MODEL" \
      REVIEW_MODEL="$REVIEW_MODEL" CLEANUP_MODEL="$CLEANUP_MODEL" \
      PLAN_FLOOR="$PLAN_FLOOR" BUILD_FLOOR="$BUILD_FLOOR" \
      REVIEW_FLOOR="$REVIEW_FLOOR" \
      "$SKILL_DIR/fallback.py" model "$ROLE")"; then
    printf 'foreman: fallback.py refused; dispatching %s on first-choice model %s\n' \
      "$NAME" "$FIRST_CHOICE_MODEL" >&2
    MODEL="$FIRST_CHOICE_MODEL"
  fi
fi

# A TIER MAY NAME ITS HARNESS. fallback.py returns `model` or `harness:model`,
# and the harness is what lets one tick fall back across CLIs and not only
# across models. Split it here: the spawn goes through that harness's adapter,
# and the harness is recorded so reconcile.py and the registry know which one
# owns the agent. The prefix is recognised only for a known harness, so a model
# that itself contains a colon (`llama3:8b`) stays a model.
SPAWN_HARNESS="$HARNESS"
SPAWN_MODEL="$MODEL"
case "$MODEL" in
  claude:*|codex:*|opencode:*)
    SPAWN_HARNESS="${MODEL%%:*}"
    SPAWN_MODEL="${MODEL#*:}"
    ;;
esac
SPAWN_ADAPTER="$SKILL_DIR/harness/$SPAWN_HARNESS.sh"
[[ -x "$SPAWN_ADAPTER" ]] \
  || die "tier $MODEL names harness $SPAWN_HARNESS, which has no adapter at $SPAWN_ADAPTER"

# Whether to pass --skip-permissions to the adapter.
#
# "0" is off too, not just empty: `-n` alone reads the STRING "0" as
# non-empty, i.e. "on" -- exactly the value an operator would type expecting
# it to mean off, and previously the one value that could never turn this off
# at all (config.sh's old `:-` also silently reinstated the default for an
# explicitly empty override). Both are honoured now.
SKIP_PERMISSIONS=()
if [[ -n "$AGENT_SKIP_PERMISSIONS" && "$AGENT_SKIP_PERMISSIONS" != "0" ]]; then
  SKIP_PERMISSIONS=(--skip-permissions)
fi

# The per-agent spend ceiling, when the operator set one. Passed to the
# adapter on the spawn AND the resume path: a resumed agent spends the same way
# a fresh one does. Only harness/claude.sh can hold it; the other two refuse it
# by name, so a MAX_BUDGET_USD on a codex or opencode installation fails every
# dispatch loudly rather than running uncapped in silence.
BUDGET=()
[[ -z "$MAX_BUDGET_USD" ]] || BUDGET=(--max-budget-usd "$MAX_BUDGET_USD")

if [[ -n "$BOARD_DRY_RUN" ]]; then
  printf 'DRY RUN: would %s %s (model=%s worktree=%s ref=%s)\n' \
    "${RESUME:+resume}${RESUME:-spawn}" "$NAME" "$MODEL" "$WORKTREE" "${REF:-origin/main}"
  exit 0
fi

# This dispatch's board, pinned in the agent's own settings. A `claude --bg`
# session is not started from this process: it is handed to a pre-warmed
# `claude bg-spare`, whose environment was captured when an EARLIER spawn
# started it -- the same mechanism the TMPDIR note below records. Measured
# 2026-09-22 on a foreman cleanup agent: its environment and its 51-minute-old
# parent spare both held FOREMAN_INSTANCE, FOREMAN_CONFIG_INSTANCE and REPO of
# another board, and its first evidence.sh answered from that board's
# repository. config.sh's cross-board guard cannot catch it, because both
# markers named the same wrong board. Settings `env` travels in this spawn's
# argv, so the spare cannot overwrite it.
#
# The names come from FOREMAN_BOARD_EXPORTS, never a second list here, plus the
# two markers config.sh keys its guard on. Built with json.dumps because a path
# can hold a quote. A name that is not in this process's environment is a
# config.sh that no longer exports it, and an agent pinned to half a board is
# the bug this exists to close, so that refuses.
# shellcheck disable=SC2086 # split on purpose: one name per word
AGENT_SETTINGS="$(python3 - "$CARD_AGENT_SETTINGS" \
  FOREMAN_INSTANCE FOREMAN_CONFIG_INSTANCE $FOREMAN_BOARD_EXPORTS <<'PY'
import json, os, sys
settings = json.loads(sys.argv[1])
missing = [n for n in sys.argv[2:] if n not in os.environ]
if missing:
    sys.exit("foreman: cannot pin the agent's board; not exported: " + " ".join(missing))
settings["env"] = {n: os.environ[n] for n in sys.argv[2:]}
print(json.dumps(settings))
PY
)" || die "could not build $NAME's settings; refusing to dispatch it"

if [[ -n "$RESUME" ]]; then
  # Resuming into a deleted working directory produces a silent failure, so
  # this refuses instead. The caller's fallback is a FRESH dispatch at the
  # next attempt number, which rebuilds the worktree from origin/main — the
  # agent loses its context but the card keeps moving. See SKILL.md step 2.
  [[ -d "$WORKTREE" ]] || die "worktree $WORKTREE is gone; cannot resume $NAME.
Dispatch fresh (drop --resume, use the next attempt number) instead."
  # The adapter resolves the session by name and prints it; see its header for
  # the lookup rule (newest startedAt wins). A failed resolve or resume is the
  # adapter's own refusal, so its non-zero exit is this script's non-zero exit.
  #
  # `--settings` carries AGENT_SETTINGS on the resume path too: a resumed
  # build is a card agent, and a resume is handed to a spare the same way a
  # spawn is. config.sh records why every card agent needs CARD_AGENT_SETTINGS.
  SESSION="$("${NO_TMPDIR[@]}" "$HARNESS_SH" resume --name "$NAME" --cwd "$WORKTREE" \
    --prompt-file "$PROMPT_FILE" --settings "$AGENT_SETTINGS" \
    "${BUDGET[@]+"${BUDGET[@]}"}" \
    "${SKIP_PERMISSIONS[@]+"${SKIP_PERMISSIONS[@]}"}")"
  # A build resume states and logs why: reconcile.py's build_attempts charges a
  # ci-fix or retry resume and not a fix resume, and it reads that off this
  # row's own "role" and "reason" fields. A resume of any other role writes the
  # row it always has -- no role key -- so reconcile.py's plan_rounds keeps
  # counting only rows with role=plan and never double-counts one of these.
  if [[ "$ROLE" == "build" ]]; then
    card_log "$TICKET" "$(printf '{"action":"resume","name":"%s","session":"%s","role":"%s","reason":"%s"}' \
      "$NAME" "$SESSION" "$ROLE" "$REASON")"
  else
    card_log "$TICKET" "$(printf '{"action":"resume","name":"%s","session":"%s"}' "$NAME" "$SESSION")"
  fi
  printf '%s\n' "$SESSION"
  exit 0
fi

# Creating a worktree touches shared git metadata, so serialize it the way
# builds.locks does. `claude -w` would create the worktree LOCKED, which
# `git worktree prune` can never reap — so add it explicitly instead.
[[ "$ROLE" != "review" || -n "$REF" ]] || die "--ref is required for a review agent"
mkdir -p "$(dirname "$WORKTREE")"
export REPO TICKET WORKTREE ROLE REF
# `branch_name` has to be exported as a FUNCTION, not just called before this
# block and stashed in a variable, because the withlock.py-wrapped script below
# runs in its own bash -c subshell that inherits the environment but not this
# process's shell functions.
export -f branch_name
"$SKILL_DIR/withlock.py" "$REPO/.git/board-worktree.lock" 120 -- bash -c '
  set -euo pipefail
  git -C "$REPO" fetch --quiet origin
  if [[ -d "$WORKTREE" ]]; then
    git -C "$REPO" worktree remove -f -f "$WORKTREE" 2>/dev/null || true
  fi
  git -C "$REPO" worktree prune
  if [[ "$ROLE" == "review" ]]; then
    git -C "$REPO" worktree add --quiet --detach "$WORKTREE" "$REF"
  elif [[ "$ROLE" == "plan" || "$ROLE" == "cleanup" ]]; then
    # A plan always reads origin/main -- there is no branch to detach at yet,
    # since the plan agent is the one that has not run. Detached, like review,
    # because this worktree is thrown away: the plan posts its graph to the
    # Linear card as a comment and never pushes, so a branch cut here would
    # sit on the card for a later build dispatch to inherit or reset. A
    # cleanup agent reads main and files a card the same way a plan agent
    # does, and pushes nothing either, so it needs no branch of its own.
    git -C "$REPO" worktree add --quiet --detach "$WORKTREE" origin/main
  else
    git -C "$REPO" worktree add --quiet -B "$(branch_name "$TICKET")" "$WORKTREE" origin/main
  fi
' || die "could not create worktree $WORKTREE (exit $?)"

# The target's own setup step -- `uv sync`, `npm ci`, whatever a fresh checkout
# needs before its test command can run at all -- against the worktree just cut
# from origin/main, before any agent sees it. Build only: a review worktree
# never builds anything, it reads a diff with `gh pr diff`, so paying a second
# `bootstrap.command` per reviewer would buy nothing. A plan agent reads the
# code and draws a graph, and runs no tests, so it pays nothing either.
#
# This gates instead of warning, same as the preflight check above and for the
# same reason. An agent dropped into a worktree whose dependencies never
# installed spends its whole attempt discovering that and reports it as a
# problem with the code -- the exact failure this whole script exists to keep
# off the ticket's attempt budget. `BOOTSTRAP_COMMAND` is empty for a target
# that declares no `[bootstrap]` table (bin/contract.py's default), and an
# empty command is nothing to run, not a command that trivially "succeeds".
if [[ "$ROLE" == "build" && -n "$BOOTSTRAP_COMMAND" ]]; then
  if ! BOOTSTRAP_OUT="$(cd "$WORKTREE" && bash -c "$BOOTSTRAP_COMMAND" 2>&1)"; then
    printf '%s\n' "$BOOTSTRAP_OUT" >&2
    die "bootstrap command \`$BOOTSTRAP_COMMAND\` failed in $WORKTREE; refusing to dispatch $NAME.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the environment, then dispatch again at the same attempt number."
  fi
fi

# Create the scratch dir paired with this worktree. It is NOT exported as
# TMPDIR here and must not be: a background agent inherits its environment from
# the shared `claude daemon`, not from this script, so every agent after the
# first would receive the first one's value. Measured 2026-08-02 — a reviewer
# and an unrelated ticket's build both reported the same ticket and role in
# their environment. A target's own TEST_COMMAND asks the same bin/tmp-dir.sh
# this does, keyed on the worktree it is running in — the one per-agent fact
# that cannot go stale. sweep.sh reaps it. The board's own identity cannot be
# keyed on the worktree, so it rides in AGENT_SETTINGS' `env` instead (above the
# resume path, measured 2026-09-22).
#
# The tick itself now runs under a per-pass TMPDIR that detached.sh deletes at
# pass end (docs/plans/2026-09-23-per-run-tmpdir.md). That is exactly the
# value this script must not let a card agent inherit either: a claude spare
# that captured it would hand a later resume a directory that is already
# gone, and preflight would probe the root disk while a running claude agent
# still writes to the real /tmp -- gate and agent would measure different
# disks. NO_TMPDIR strips it from the preflight call above and the resume and
# spawn calls below, so all three measure the same /tmp this script itself
# inherited.
mkdir -p "$(agent_tmp_for "$WORKTREE")"

# The adapter resolves and prints the session id itself -- see its header --
# so a "never registered" failure surfaces as ITS non-zero exit, not a second
# lookup here.
#
# `--settings` is CARD_AGENT_SETTINGS plus this board's `env`, on every card
# agent and never the tick; config.sh records why the first, and the note above
# the resume path why the second.
#
# bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
# error, not an empty expansion. The `+` form below is the portable way to say
# "expand only if set", and BUDGET and SKIP_PERMISSIONS are both empty on an
# ordinary dispatch.
SESSION="$("${NO_TMPDIR[@]}" "$SPAWN_ADAPTER" spawn --name "$NAME" --cwd "$WORKTREE" --model "$SPAWN_MODEL" \
  --prompt-file "$PROMPT_FILE" --add-dir "$BOARD_HOME" \
  --settings "$AGENT_SETTINGS" "${BUDGET[@]+"${BUDGET[@]}"}" \
  "${SKIP_PERMISSIONS[@]+"${SKIP_PERMISSIONS[@]}"}")" \
  || die "spawned $NAME but the adapter never reported a session id"

mkdir -p "$(card_dir "$TICKET")"
# "ref" carries the sha a reviewer read (empty for a role that has none, plan
# and cleanup among them). reconcile.py's review_verdict reads "the fix was
# pushed" as the pull request head having moved past the sha the reviewer
# read, and until this the spawn record kept no memory of what that was.
#
# "model" is what this spawn ran on, and "first_choice" what the role would
# have run on with no rate limit. reconcile.py reads "model" back so the tick
# marks the model that was actually refused.
card_log "$TICKET" "$(printf '{"action":"spawn","name":"%s","session":"%s","worktree":"%s","role":"%s","attempt":"%s","ref":"%s","model":"%s","first_choice":"%s","harness":"%s"}' \
  "$NAME" "$SESSION" "$WORKTREE" "$ROLE" "${ATTEMPT}${SLOT}" "$REF" "$MODEL" "$FIRST_CHOICE_MODEL" "$SPAWN_HARNESS")"
printf '%s\n' "$SESSION"
