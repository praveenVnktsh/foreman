#!/usr/bin/env bash
# Claim: a shell that sources config.sh for one board and then for another
# reads the second board's own contract and ids.env, not the first board's.
#
# Every key bin/boards.py, bin/contract.py and ids.env emit is read
# environment-wins, so the first board's values already in the shell used to
# answer for the second. Measured 2026-09-30 on this fixture: sourcing alpha and
# then beta left beta with alpha's REQUIRED_CHECKS and an EMPTY HIGH_RISK_PATHS
# where beta declares `db/migrations/` -- a risk gate switched off with no
# error. The cross-board guard reset only the exported names.
#
# A value the shell held BEFORE any board was read is an operator's override and
# must still win, for both boards.
set -uo pipefail
# shellcheck source=lib/without-board.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/without-board.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi }

board() { # <name> <required checks> <risk paths, TOML list body>
  git init -q -b main "$work/$1"
  printf '[linear]\nteam = "ACME"\nproject = "%s"\n[checks]\nrequired = [%s]\nci_workflow = "CI"\n[test]\ncommand = "make check"\n[risk]\npaths = [%s]\n' \
    "$1" "$2" "$3" >"$work/$1/board.toml"
}
board alpha '"Tests"' ''
board beta '"Tests", "Lint"' '"db/migrations/"'
home="$work/home"
fixture_add_board "$home" alpha "$work/alpha"
fixture_add_board "$home" beta "$work/beta"
# An ids.env key only alpha has. beta must not inherit it.
mkdir -p "$home/.foreman/instances/alpha"
printf 'STATE_TODO=alpha-todo-id\n' >"$home/.foreman/instances/alpha/ids.env"

config="$root/skills/board/config.sh"
read_twice() { # <override assignment, or empty> -> what beta sees, one per line
  env -u STATE_TODO -u HIGH_RISK_PATHS HOME="$home" FOREMAN_HOME="$home/.foreman" \
    bash -c '
      [[ -z "$1" ]] || export "$1"
      export FOREMAN_INSTANCE=alpha; . "$2"
      alpha_checks="$REQUIRED_CHECKS"
      export FOREMAN_INSTANCE=beta; . "$2"
      printf "%s\n" "$alpha_checks" "$REPO" "$REQUIRED_CHECKS" "$HIGH_RISK_PATHS" "${STATE_TODO-<unset>}"
    ' _ "$1" "$config"
}

# What beta reads in a shell of its own, the answer the second source must give.
alone="$(env -u HIGH_RISK_PATHS HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=beta \
  bash -c '. "$1"; printf "%s\n" "$REQUIRED_CHECKS"' _ "$config")"

out="$(read_twice "")"
check "alpha's own checks are read first" "Tests" "$(sed -n 1p <<<"$out")"
check "beta gets its own repository" "$work/beta" "$(sed -n 2p <<<"$out")"
check "beta gets its own required checks" "$alone" "$(sed -n 3p <<<"$out")"
check "beta gets its own risk paths" "db/migrations/" "$(sed -n 4p <<<"$out")"
check "beta does not inherit alpha's ids.env" "<unset>" "$(sed -n 5p <<<"$out")"

out="$(read_twice "HIGH_RISK_PATHS=operator/")"
check "an override set before any board is read still wins for the second board" \
  "operator/" "$(sed -n 4p <<<"$out")"

[[ "$fail" -eq 0 ]] && printf 'PASS: one shell gives each board its own contract\n'
exit "$fail"
