#!/usr/bin/env bash
# The shell that runs the suite must not reach the dispatches the fixture runs.
#
# Nearly every value in `config.sh` is `${NAME:-default}`, so an operator who
# exports one -- to debug a real board, which is the reason anyone exports any
# of these -- answers the question config.sh asks before it asks it. The two
# model tests then go red on a correctly configured machine, and the failure
# names the dispatch code, which is not what broke. PLAN_MODEL was the first
# report (PRA-276); CLAUDE_CODE_SUBAGENT_MODEL, REPO, FOREMAN_HOME and
# BOARD_DRY_RUN each reproduced it, and the next one is whichever variable
# someone exports next.
#
# So the claim under test is the whole class, not a list of names: the fixture
# hands a dispatch an environment it built, and nothing else. The one hole is
# a model variable a test sets on purpose AFTER dispatch_fixture_setup, which
# test-the-plan-stage-dispatches-on-fable.sh depends on and asserts for itself.
#
# This test drives the fixture directly rather than re-running the two model
# tests as children. Re-running them would pay for two full fixture setups a
# second time on every suite run, and would report an unrelated breakage in
# either child under this test's name -- pointing the reader at an environment
# leak that is not there.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# A second, complete target: a git repository with a board.toml and an origin,
# indistinguishable to dispatch.sh from the one the fixture builds. It stands
# for the repository an operator was debugging when they exported REPO.
#
# It has to be a VALID target and not an empty directory. dispatch.sh dies at
# the contract load on a directory with no board.toml, so an empty decoy could
# never receive a worktree and an assertion that it stays empty would be green
# whether the leak was closed or not.
decoy_repo="$work_dir/decoy-repo"
_dispatch_git init -q -b main "$decoy_repo"
_dispatch_git init -q --bare "$work_dir/decoy-origin.git"
fixture_board_toml "$decoy_repo"
_dispatch_git -C "$decoy_repo" add -A
_dispatch_git -C "$decoy_repo" commit -q -m Seed
_dispatch_git -C "$decoy_repo" remote add origin "$work_dir/decoy-origin.git"
_dispatch_git -C "$decoy_repo" push -q origin main

# Exported BEFORE dispatch_fixture_setup, because that is the shape of the
# failure: the operator already had these in their shell when they typed
# `tests/run-all.sh`. Each one changes what a dispatch does. `haiku` is neither
# stage's default, so a passing model assertion cannot be a coincidence.
export PLAN_MODEL=haiku BUILD_MODEL=haiku REVIEW_MODEL=haiku \
  CLAUDE_CODE_SUBAGENT_MODEL=fable \
  BOARD_DRY_RUN=1 \
  REPO="$decoy_repo" \
  FOREMAN_HOME="$work_dir/decoy-home" \
  FOREMAN_TMP_ROOT="$work_dir/decoy-tmp"

dispatch_fixture_setup "$work_dir" "$repo_root"

check_model() { # description expected-repr
  local desc="$1" want="$2" got
  got="$(dispatch_fixture_model)"
  if [[ -z "$got" ]]; then
    # BOARD_DRY_RUN and FOREMAN_HOME both land here rather than on a wrong
    # model: a dry run prints and exits before the spawn, and a FOREMAN_HOME
    # pointing elsewhere makes config.sh refuse the fixture's board outright.
    bad "$desc: the dispatch never reached \`claude --bg --model\`"
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected --model $want, got $got"
  fi
}

dispatch_fixture_run --ticket PRA-1 --role plan --attempt 1
check_model "a plan dispatch runs on fable despite the exported environment" "'fable'"

dispatch_fixture_run --ticket PRA-2 --role build --attempt 1
check_model "a build dispatch runs on opus despite the exported environment" "'opus'"

# dispatch.sh exports no CLAUDE_CODE_SUBAGENT_MODEL of its own, so the only
# way the spawned agent can carry one is the caller's shell.
subagent_model="$(cat "$DISPATCH_SUBAGENT_MODEL_LOG" 2>/dev/null || true)"
if [[ "$subagent_model" == "<unset>" ]]; then
  ok "an exported CLAUDE_CODE_SUBAGENT_MODEL does not reach the spawned agent"
else
  bad "an exported CLAUDE_CODE_SUBAGENT_MODEL does not reach the spawned agent: got $subagent_model"
fi

# REPO on its own, because it is the one leak the assertions above cannot see.
# The decoy is a valid target, so a dispatch that follows an exported REPO
# still logs the model this test wants and still reports `ok` -- while
# dispatch.sh runs `git fetch`, `git worktree add` and `git worktree remove
# -f -f` inside the repository the operator was debugging. The damage is the
# assertion, not the exit code.
#
# The others are cleared first so that none of them can kill the dispatch
# before it reaches the worktree step and hide that damage behind a pass.
unset PLAN_MODEL BUILD_MODEL REVIEW_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
  BOARD_DRY_RUN FOREMAN_HOME FOREMAN_TMP_ROOT
dispatch_fixture_run --ticket PRA-3 --role plan --attempt 1

if [[ -d "$decoy_repo/.claude/worktrees" ]]; then
  bad "an exported REPO gets no worktree cut into it: $decoy_repo/.claude/worktrees exists"
else
  ok "an exported REPO gets no worktree cut into it"
fi

[[ "$fail" -eq 0 ]] &&
  printf "PASS: the operator's environment does not reach a dispatch\n"
exit "$fail"
