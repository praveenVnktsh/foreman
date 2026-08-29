#!/usr/bin/env bash
# Spawn (or resume) one detached board agent in its own git worktree.
#
# The card in Linear is the lock. This script assumes the caller has ALREADY
# moved the card into In progress — a spawn that precedes the move gets
# dispatched twice by the next tick.
#
#   dispatch.sh --ticket MUR-42 --role build  --attempt 1 --prompt-file brief.md
#   dispatch.sh --ticket MUR-42 --role review --attempt 1 --slot a \
#               --ref <pr-head-sha> --prompt-file review.md
#   dispatch.sh --ticket MUR-42 --role build  --attempt 1 --resume \
#               --prompt-file findings.md
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
[[ "$ROLE" == "build" || "$ROLE" == "review" ]] || die "--role must be build or review"
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

if [[ "$ROLE" == "build" ]]; then
  WORKTREE="$(worktree_path "$TICKET")"
  MODEL="$BUILD_MODEL"
else
  WORKTREE="$(worktree_path "${TICKET}-${ROLE}-${ATTEMPT}${SLOT}")"
  MODEL="$REVIEW_MODEL"
fi

# Resolve an agent by its deterministic name. This is what makes the sidecar
# disposable: the name is derivable, so the session id never has to be remembered.
#
# `--bg --resume` FORKS — it starts a new session id and inherits the name, so
# several agents legitimately share one name. The newest is the live one, so
# always sort by startedAt and take the last. Taking the first resumes a dead
# session and silently loses every turn since.
lookup_session() {
  claude agents --json --all 2>/dev/null | python3 -c '
import json,sys
want=sys.argv[1]
try: agents=json.load(sys.stdin)
except Exception: sys.exit(0)
matches=[a for a in agents if a.get("name")==want]
if matches:
    print(max(matches, key=lambda a: a.get("startedAt") or 0).get("sessionId",""))
' "$NAME"
}

EXTRA=()
[[ -n "$MAX_BUDGET_USD" ]] && EXTRA=(--max-budget-usd "$MAX_BUDGET_USD")
# `--dangerously-skip-permissions` IS `--permission-mode bypassPermissions`;
# passing both conflicts, so it is one or the other. Either way the last flag
# before the prompt is non-variadic, which is what keeps the prompt from being
# swallowed. This applies to RESUME too — a resumed agent with no permission
# flag blocks on its first Bash call exactly like a fresh one.
#
# "0" is off too, not just empty: `-n` alone reads the STRING "0" as
# non-empty, i.e. "on" -- exactly the value an operator would type expecting
# it to mean off, and previously the one value that could never turn this off
# at all (config.sh's old `:-` also silently reinstated the default for an
# explicitly empty override). Both are honoured now.
if [[ -n "$AGENT_SKIP_PERMISSIONS" && "$AGENT_SKIP_PERMISSIONS" != "0" ]]; then
  EXTRA+=(--dangerously-skip-permissions)
else
  EXTRA+=(--permission-mode acceptEdits)
fi
set -- ${EXTRA[@]+"${EXTRA[@]}"}

if [[ -n "$BOARD_DRY_RUN" ]]; then
  printf 'DRY RUN: would %s %s (model=%s worktree=%s ref=%s)\n' \
    "${RESUME:+resume}${RESUME:-spawn}" "$NAME" "$MODEL" "$WORKTREE" "${REF:-origin/main}"
  exit 0
fi

if [[ -n "$RESUME" ]]; then
  SESSION="$(lookup_session)"
  [[ -n "$SESSION" ]] || die "no agent named $NAME to resume"
  # Resuming into a deleted working directory produces a second silent failure,
  # so this refuses instead. The caller's fallback is a FRESH dispatch at the
  # next attempt number, which rebuilds the worktree from origin/main — the
  # agent loses its context but the card keeps moving. See SKILL.md step 2.
  [[ -d "$WORKTREE" ]] || die "worktree $WORKTREE is gone; cannot resume $NAME.
Dispatch fresh (drop --resume, use the next attempt number) instead."
  cd "$WORKTREE"
  claude --bg --resume "$SESSION" "$@" "$PROMPT" >/dev/null
  card_log "$TICKET" "$(printf '{"action":"resume","name":"%s","session":"%s"}' "$NAME" "$SESSION")"
  printf '%s\n' "$SESSION"
  exit 0
fi

# Creating a worktree touches shared git metadata, so serialize it the way
# builds.locks does. `claude -w` would create the worktree LOCKED, which
# `git worktree prune` can never reap — so add it explicitly instead.
[[ "$ROLE" == "build" || -n "$REF" ]] || die "--ref is required for a review agent"
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
  if [[ "$ROLE" == "build" ]]; then
    git -C "$REPO" worktree add --quiet -B "$(branch_name "$TICKET")" "$WORKTREE" origin/main
  else
    git -C "$REPO" worktree add --quiet --detach "$WORKTREE" "$REF"
  fi
' || die "could not create worktree $WORKTREE (exit $?)"

# The target's own setup step -- `uv sync`, `npm ci`, whatever a fresh checkout
# needs before its test command can run at all -- against the worktree just cut
# from origin/main, before any agent sees it. Build only: a review worktree
# never builds anything, it reads a diff with `gh pr diff`, so paying a second
# `bootstrap.command` per reviewer would buy nothing.
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

# bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
# error, not an empty expansion. The `+` form is the portable way to say
# "expand only if set".
# A review worktree is throwaway and never merged, so acceptEdits is contained;
# the reviewer needs write access only to drop its findings under BOARD_HOME.
#
# ORDER IS LOAD-BEARING. `--add-dir <directories...>` and `--tools <tools...>`
# are VARIADIC: whatever follows them is eaten as another value. A prompt placed
# after one produces an agent that starts, authenticates, and then sits at an
# empty prompt box forever — `state: blocked`, no transcript, no error.
# Keep a non-variadic flag (`--permission-mode`) immediately before the prompt.
# Create the scratch dir paired with this worktree. It is NOT exported as
# TMPDIR here and must not be: a background agent inherits its environment from
# the shared `claude daemon`, not from this script, so every agent after the
# first would receive the first one's value. Measured 2026-08-02 — a reviewer
# and an unrelated ticket's build both reported the same ticket and role in
# their environment. A target's own TEST_COMMAND asks the same bin/tmp-dir.sh
# this does, keyed on the worktree it is running in — the one per-agent fact
# that cannot go stale. sweep.sh reaps it.
mkdir -p "$(agent_tmp_for "$WORKTREE")"

cd "$WORKTREE"
claude --bg \
  --name "$NAME" \
  --model "$MODEL" \
  --add-dir "$BOARD_HOME" \
  "$@" \
  "$PROMPT" >/dev/null

SESSION="$(lookup_session)"
[[ -n "$SESSION" ]] || die "spawned $NAME but it never registered with claude agents"

mkdir -p "$(card_dir "$TICKET")"
card_log "$TICKET" "$(printf '{"action":"spawn","name":"%s","session":"%s","worktree":"%s","role":"%s","attempt":"%s"}' \
  "$NAME" "$SESSION" "$WORKTREE" "$ROLE" "${ATTEMPT}${SLOT}")"
printf '%s\n' "$SESSION"
