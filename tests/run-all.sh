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
# correct build. CI runs with a clean environment, so it never showed.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_sh="$(dirname "$here")/skills/board/config.sh"

# The names come from config.sh's declaration, never a copy here: a copy misses
# the next name added there. Parsed, not sourced, because sourcing config.sh
# needs a declared board and CI has none. An empty list would let the leak back
# in without a word, so anything but exactly one non-empty declaration refuses.
exports="$(sed -n 's/^FOREMAN_BOARD_EXPORTS="\([^"]*\)"$/\1/p' "$config_sh" 2>/dev/null)"
if [[ -z "$exports" || "$exports" == *$'\n'* ]]; then
  printf 'run-all: cannot read one FOREMAN_BOARD_EXPORTS="..." line from %s\n' "$config_sh" >&2
  exit 1
fi
unset_args=(-u FOREMAN_INSTANCE -u FOREMAN_CONFIG_INSTANCE)
for name in $exports; do
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf 'run-all: FOREMAN_BOARD_EXPORTS in %s names %q, not a variable\n' "$config_sh" "$name" >&2
    exit 1
  fi
  unset_args+=(-u "$name")
done

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
  env "${unset_args[@]}" bash "$t" || fail=1
done
if [[ $# -eq 0 ]]; then
  env "${unset_args[@]}" bash "$(dirname "$here")/bin/check-syntax.sh" || fail=1
fi
exit "$fail"
