#!/usr/bin/env bash
# Claim: config.sh refuses a HOST_MAX_CONCURRENT that is not a positive whole
# number, by name, instead of handing it on.
#
# The value went straight through to reconcile.py's machine ceiling. `four`, `0`
# or `4 ` is a ceiling nobody can check, and a gate fed one either dies deep in
# Python with a message about something else or passes a dispatch it should
# have weighed.
set -uo pipefail
# shellcheck source=lib/without-board.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/without-board.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work/target"
git init -q -b main "$target"
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" alpha "$target"

load() { # <HOST_MAX_CONCURRENT>
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha HOST_MAX_CONCURRENT="$1" \
    bash -c '. "$1" && printf "loaded %s\n" "$HOST_MAX_CONCURRENT"' _ "$root/skills/board/config.sh" 2>&1
}

for value in four 0 -2 "4 "; do
  out="$(load "$value")" && bad "HOST_MAX_CONCURRENT=[$value] loaded: $out" \
    || { grep -q 'HOST_MAX_CONCURRENT' <<<"$out" \
      && ok "HOST_MAX_CONCURRENT=[$value] is refused by name" \
      || bad "HOST_MAX_CONCURRENT=[$value] was refused without naming it: $out"; }
done
out="$(load 6)"
[[ "$out" == "loaded 6" ]] && ok "a positive whole number loads" || bad "HOST_MAX_CONCURRENT=6 did not load: $out"

[[ "$fail" -eq 0 ]] && printf 'PASS: a host ceiling that is not a number is refused\n'
exit "$fail"
