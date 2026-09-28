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
# FOREMAN_BOARD_EXPORTS into a card agent's environment (PRA-517), and config.sh
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

fail=0
for t in "${tests[@]}"; do
  printf '\n== %s\n' "$(basename "$t")"
  bash "$t" || fail=1
done
if [[ $# -eq 0 ]]; then
  bash "$(dirname "$here")/bin/check-syntax.sh" || fail=1
fi
exit "$fail"
