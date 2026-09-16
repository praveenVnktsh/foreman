#!/usr/bin/env bash
# The cleanup role runs on CLEANUP_MODEL, in a throwaway worktree detached at
# origin/main -- a plan agent in every way that matters, since it reads main
# and files a card without ever pushing. See
# docs/specs/2026-09-15-cleanup-and-light-review-design.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

check_model() { # description expected-repr
  local desc="$1" want="$2" got
  got="$(dispatch_fixture_model)"
  if [[ -z "$got" ]]; then
    bad "$desc: the dispatch never reached \`claude --bg --model\`"
    dispatch_fixture_show_run_log
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected --model $want, got $got"
  fi
}

# CLEANUP_MODEL is not one of dispatch-fixture.sh's model knobs -- it does not
# reach the dispatch through the environment the way PLAN_MODEL does, it
# reaches it the way the design spec configures it: board.toml's own
# [cleanup] table, read straight off disk by contract.py. The fixture's
# board.toml declares no such table, so contract.py emits an empty
# CLEANUP_MODEL and config.sh's own fallback (`${CLEANUP_MODEL:-$PLAN_MODEL}`)
# is what has to answer -- the plan model, `fable`, is the default this run
# proves.
dispatch_fixture_run --ticket cleanup --role cleanup --attempt 1
check_model "a cleanup dispatch falls back to the plan model" "'fable'"

printf '[cleanup]\nmodel = "sonnet"\n' >> "$_DISPATCH_TARGET/board.toml"
dispatch_fixture_run --ticket cleanup --role cleanup --attempt 1
check_model "board.toml's cleanup.model overrides the default" "'sonnet'"

# The agent name is what watch-agents.py and reconcile.py match a dispatched
# agent by. A cleanup agent is not a card, so it is named from its own
# ticket ("cleanup") like any other role, not from a Linear card key.
if grep -qx 'foreman/demo/cleanup/cleanup-1' "$DISPATCH_ARGV_LOG"; then
  ok "a cleanup agent is named foreman/[<installation>/]<board>/cleanup/cleanup-<attempt>"
else
  bad "a cleanup agent is named foreman/[<installation>/]<board>/cleanup/cleanup-<attempt>: got $(grep -A1 -x -- --name "$DISPATCH_ARGV_LOG" | tail -1)"
fi

# Detached at origin/main, exactly like plan: the agent reads main and files a
# card, and pushes nothing, so it needs no branch of its own. A worktree on a
# branch would sit there for a later build dispatch on an unrelated ticket
# named "cleanup" to inherit or reset.
cleanup_worktree="$_DISPATCH_TARGET/.claude/worktrees/foreman-demo-cleanup-cleanup-1"
if [[ -d "$cleanup_worktree" ]]; then
  if git -C "$cleanup_worktree" symbolic-ref -q HEAD >/dev/null 2>&1; then
    bad "a cleanup worktree is detached, not on a branch"
  else
    ok "a cleanup worktree is detached, not on a branch"
  fi
else
  bad "a cleanup worktree is detached, not on a branch: no worktree found at $cleanup_worktree"
  dispatch_fixture_show_run_log
fi

# reconcile.py's review_verdict reads "the fix was pushed" as the pull
# request head having moved past the sha the reviewer read, so the spawn
# record has to carry that sha. A review dispatch is given one with --ref;
# this proves it lands in the card's history rather than being dropped on
# the way to card_log.
review_ref="$DISPATCH_SEED_SHA"
dispatch_fixture_run --ticket PRA-9 --role review --attempt 1 --ref "$review_ref"
history_file="$DISPATCH_HOME/.foreman/instances/demo/cards/PRA-9/history.jsonl"
if [[ -f "$history_file" ]] && grep -q "\"ref\":\"$review_ref\"" "$history_file"; then
  ok "a review dispatch's history line carries the ref it was given"
else
  bad "a review dispatch's history line carries the ref it was given: no such line in $history_file"
  dispatch_fixture_show_run_log
  [[ -f "$history_file" ]] && cat "$history_file" >&2
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: the cleanup role dispatches\n'
exit "$fail"
