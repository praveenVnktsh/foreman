#!/usr/bin/env bash
# Every test, in one command, so `test.command` in board.toml has something to
# name. Runs them all before reporting: stopping at the first failure hides how
# much is broken, which matters when an agent is the one reading the output.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$here"/test-*.sh; do
  printf '\n== %s\n' "$(basename "$t")"
  bash "$t" || fail=1
done
bash "$(dirname "$here")/bin/check-syntax.sh" || fail=1
exit "$fail"
