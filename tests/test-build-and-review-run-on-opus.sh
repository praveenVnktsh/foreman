#!/usr/bin/env bash
# Building and reviewing run on `opus`, and no fallback moves a build agent or
# anything it spawns off it.
#
# `opus` is the ceiling once a plan exists. A build agent executes design
# decisions the plan already made, and a reviewer reads a diff nobody else will
# read again before it merges. Both stay at the strongest model the board will
# spend on code.
#
# The subagent assertion is the regression check. An earlier attempt exported
# `CLAUDE_CODE_SUBAGENT_MODEL=fable` from this same dispatch, which pushed every
# subagent a build spawned down to the tier that is supposed to draw plans, not
# execute them -- silently, because a subagent that names no model of its own
# says nothing about which one it got.
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
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected --model $want, got $got"
  fi
}

dispatch_fixture_run --ticket PRA-1 --role build --attempt 1
check_model "a build dispatch runs on opus" "'opus'"

subagent_model="$(cat "$DISPATCH_SUBAGENT_MODEL_LOG" 2>/dev/null || true)"
if [[ "$subagent_model" == "<unset>" ]]; then
  ok "a build agent's subagents are given no model of their own"
elif [[ "$subagent_model" == "fable" ]]; then
  bad "a build agent's subagents are pushed to fable by CLAUDE_CODE_SUBAGENT_MODEL"
else
  ok "a build agent's subagents fall back to $subagent_model, not fable"
fi

dispatch_fixture_run --ticket PRA-2 --role review --attempt 1 --slot a \
  --ref "$DISPATCH_SEED_SHA"
check_model "a review dispatch runs on opus" "'opus'"

[[ "$fail" -eq 0 ]] && printf 'PASS: build and review dispatches run on opus\n'
exit "$fail"
