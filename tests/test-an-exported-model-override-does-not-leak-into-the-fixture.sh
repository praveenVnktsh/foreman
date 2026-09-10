#!/usr/bin/env bash
# An operator's exported PLAN_MODEL, BUILD_MODEL or REVIEW_MODEL must not reach
# `dispatch-fixture.sh`'s child dispatches and defeat config.sh's fallbacks.
#
# `config.sh` sets `PLAN_MODEL="${PLAN_MODEL-fable}"`, `BUILD_MODEL="${BUILD_MODEL:-opus}"`
# and `REVIEW_MODEL="${REVIEW_MODEL:-opus}"`. Before dispatch_fixture_setup started
# clearing the three, an operator who had PLAN_MODEL=haiku exported in their own
# shell -- for a real board run, unrelated to this test suite -- inherited it into
# every dispatch-fixture.sh run: `${PLAN_MODEL-fable}` never fires, because the
# ambient export already answered the question config.sh asks. That turned
# test-the-plan-stage-dispatches-on-fable.sh and test-build-and-review-run-on-opus.sh
# red on a correctly configured machine, with nothing in the diff under review to
# blame.
#
# This test cannot assert on dispatch-fixture.sh's internals -- doing so would
# pin the fix to today's implementation. It runs the two model tests themselves as
# child processes, with all three variables exported to a value that is none of
# config.sh's defaults, and requires them to still pass. That is the regression
# in the only form that matters: the tests those operators actually run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# Neither a default nor a value either test asserts for any other reason, so a
# pass cannot be a coincidence of the override matching what config.sh would
# have chosen anyway.
export PLAN_MODEL=haiku BUILD_MODEL=haiku REVIEW_MODEL=haiku

run_test() { # $1 path relative to repo_root, $2 description
  local rel="$1" desc="$2" out
  local path="$repo_root/$rel"
  if out="$(bash "$path" 2>&1)"; then
    ok "$desc"
  else
    bad "$desc"
    printf -- '----- output of %s -----\n%s\n-------------------------------\n' \
      "$rel" "$out" >&2
  fi
}

run_test "tests/test-the-plan-stage-dispatches-on-fable.sh" \
  "the plan stage still dispatches on fable with PLAN_MODEL exported to haiku"
run_test "tests/test-build-and-review-run-on-opus.sh" \
  "build and review still dispatch on opus with BUILD_MODEL and REVIEW_MODEL exported to haiku"

[[ "$fail" -eq 0 ]] &&
  printf 'PASS: an exported model override does not leak into the fixture\n'
exit "$fail"
