#!/usr/bin/env bash
# Every test, in one command, so `test.command` in board.toml has something to
# name. Runs them all before reporting: stopping at the first failure hides how
# much is broken, which matters when an agent is the one reading the output.
#
#     tests/run-all.sh                      every test-*.sh, then the syntax check
#     tests/run-all.sh test-a.sh test-b.sh  only the named tests
#
# EVERY TEST RUNS WITHOUT THE BOARD IT RUNS UNDER. dispatch.sh pins
# FOREMAN_INSTANCE, FOREMAN_CONFIG_INSTANCE and every name in
# FOREMAN_BOARD_EXPORTS into a card agent's environment, and config.sh
# is environment-wins. Measured 2026-09-25 in a foreman card agent: four tests
# read those values as if an operator had set them, and this suite exited 1 on a
# correct build. CI runs with a clean environment, so it never showed. The lib
# clears them here, and every test inherits the cleared environment.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/without-board.sh
source "$here/lib/without-board.sh"

tests=()
if [[ $# -eq 0 ]]; then
  tests=("$here"/test-*.sh)
else
  for name in "$@"; do
    if [[ ! -f "$here/$name" ]]; then
      printf 'run-all: no test %s in %s\n' "$name" "$here" >&2
      exit 1
    fi
    tests+=("$here/$name")
  done
fi

# A hung test stalls the whole suite and the card behind it. Each test gets
# TEST_TIMEOUT_SECONDS (default 600). macOS has no `timeout`, so a watchdog
# kills the test's process group: `set -m` while it launches makes the test lead
# its own group, so its children die with it.
timeout_s="${TEST_TIMEOUT_SECONDS:-600}"

run_with_timeout() {  # $1 test path -> exit status; 124 when it timed out
  local flag pid wd rc
  flag="$(mktemp)"
  set -m
  bash "$1" &
  pid=$!
  set +m
  (
    sleep "$timeout_s"
    printf 'timeout\n' >"$flag"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  ) &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [[ -s "$flag" ]]; then rc=124; fi
  rm -f "$flag"
  return "$rc"
}

fail=0
for t in "${tests[@]}"; do
  printf '\n== %s\n' "$(basename "$t")"
  run_with_timeout "$t"
  rc=$?
  if [[ $rc -eq 124 ]]; then
    printf 'FAIL %s timed out after %ss\n' "$(basename "$t")" "$timeout_s" >&2
    fail=1
  elif [[ $rc -ne 0 ]]; then
    fail=1
  fi
done
if [[ $# -eq 0 ]]; then
  bash "$(dirname "$here")/bin/check-syntax.sh" || fail=1
fi
exit "$fail"
