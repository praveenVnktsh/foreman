#!/usr/bin/env bash
# `boardctl forget` deletes an UNDECLARED board's runtime directory. On a
# case-insensitive filesystem -- macOS by default -- instances/ALPHA and
# instances/alpha are one directory, so `forget ALPHA` passed the exact-name
# "is it declared" check and deleted the live board alpha's card history.
#
# Prove: forget refuses a name that matches a declared board ignoring case;
# forget refuses a name whose directory on disk is spelled differently (an
# orphan named `ghost` is not forgotten as GHOST); both leave the directory
# intact; and the exact spelling still forgets.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
boardctl="$repo_root/bin/boardctl"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

run() { FOREMAN_HOME="$home" "$boardctl" "$@"; }

home="$work_dir/home"
mkdir -p "$home"
target="$work_dir/target"
mkdir -p "$target"
fixture_board_toml "$target"
run add alpha --repo "$target" >/dev/null
mkdir -p "$home/instances/alpha/cards/PRA-1" "$home/instances/ghost/cards/PRA-2"

status=0
run forget ALPHA >/dev/null 2>"$work_dir/alpha.err" || status=$?
if [[ $status -ne 0 ]] && [[ -d "$home/instances/alpha/cards/PRA-1" ]] \
   && grep -q "still declared" "$work_dir/alpha.err"; then
  ok "forget refuses a declared board's name in another case"
else
  not_ok "forget ALPHA: status=$status err=$(cat "$work_dir/alpha.err") alpha-left=$([[ -d "$home/instances/alpha" ]] && echo yes || echo no)"
fi

status=0
run forget GHOST >/dev/null 2>"$work_dir/ghost.err" || status=$?
if [[ $status -ne 0 ]] && [[ -d "$home/instances/ghost/cards/PRA-2" ]]; then
  ok "forget refuses a name whose directory is spelled differently on disk"
else
  not_ok "forget GHOST: status=$status err=$(cat "$work_dir/ghost.err")"
fi

status=0
run forget ghost >/dev/null 2>"$work_dir/ghost-exact.err" || status=$?
if [[ $status -eq 0 ]] && [[ ! -d "$home/instances/ghost" ]] && [[ -d "$home/instances/alpha" ]]; then
  ok "forget with the exact spelling deletes only that orphan"
else
  not_ok "forget ghost: status=$status err=$(cat "$work_dir/ghost-exact.err")"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
