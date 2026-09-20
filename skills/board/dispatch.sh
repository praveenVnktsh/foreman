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
#               --prompt-file findings.md
#   dispatch.sh --ticket cleanup --role cleanup --attempt <yyyymmddHHMM> \
#               --prompt-file cleanup.md
#
# Prints the resolved agent id on success.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SKILL_DIR/config.sh"

TICKET="" ROLE="" ATTEMPT="" SLOT="" REF="" PROMPT_FILE="" RESUME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --attempt) ATTEMPT="$2"; shift 2 ;;
    --slot) SLOT="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TICKET" ]] || die "--ticket is required"
[[ "$ROLE" == "plan" || "$ROLE" == "build" || "$ROLE" == "review" || "$ROLE" == "cleanup" ]] \
  || die "--role must be plan, build, review or cleanup"
[[ -n "$ATTEMPT" ]] || die "--attempt is required"
[[ -n "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "--prompt-file must be readable"

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
if ! PREFLIGHT="$("$SKILL_DIR/preflight.py" --quiet 2>&1)"; then
  printf '%s\n' "$PREFLIGHT" >&2
  die "environment is unfit to build; refusing to dispatch $NAME.
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
  # `--settings` carries CARD_AGENT_SETTINGS on the resume path too: a resumed
  # build is a card agent, and config.sh records why every card agent needs it.
  SESSION="$("$HARNESS_SH" resume --name "$NAME" --cwd "$WORKTREE" \
    --prompt-file "$PROMPT_FILE" --settings "$CARD_AGENT_SETTINGS" \
    "${BUDGET[@]+"${BUDGET[@]}"}" \
    "${SKIP_PERMISSIONS[@]+"${SKIP_PERMISSIONS[@]}"}")"
  card_log "$TICKET" "$(printf '{"action":"resume","name":"%s","session":"%s"}' "$NAME" "$SESSION")"
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
# that cannot go stale. sweep.sh reaps it.
mkdir -p "$(agent_tmp_for "$WORKTREE")"

# The adapter resolves and prints the session id itself -- see its header --
# so a "never registered" failure surfaces as ITS non-zero exit, not a second
# lookup here.
#
# `--settings` is CARD_AGENT_SETTINGS, on every card agent and never the tick;
# config.sh records why.
#
# bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
# error, not an empty expansion. The `+` form below is the portable way to say
# "expand only if set", and BUDGET and SKIP_PERMISSIONS are both empty on an
# ordinary dispatch.
SESSION="$("$SPAWN_ADAPTER" spawn --name "$NAME" --cwd "$WORKTREE" --model "$SPAWN_MODEL" \
  --prompt-file "$PROMPT_FILE" --add-dir "$BOARD_HOME" \
  --settings "$CARD_AGENT_SETTINGS" "${BUDGET[@]+"${BUDGET[@]}"}" \
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
