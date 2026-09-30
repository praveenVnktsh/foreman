#!/usr/bin/env bash
# One board whose repository is gone -- an unmounted disk, a deleted checkout
# -- must not stop the operator from managing every other board, nor from
# removing the broken one.
#
# THE BUG. `remove` read the repository with `$(board_repo ... || true)`.
# board_repo dies, `exit` inside $(...) never reaches the `|| true`, and
# `set -e` then ended boardctl with status 1 and the message thrown away --
# with --force too. And bin/boards.py validated every board for a single-board
# lookup, so `status`, `halt`, `resume` and `cleanup` of a healthy board
# refused because of a different one.
#
# Prove: status/halt/resume/cleanup/remove of the healthy board work; the
# broken board is removable with and without --force and says why its
# repository was not checked; `list` names both, marks the broken one, and
# exits non-zero.
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

run() { local home="$1"; shift; FOREMAN_HOME="$home" "$boardctl" "$@"; }

# new_home_with_broken_alpha -- a home declaring alpha (repo gone) and beta.
new_home_with_broken_alpha() {
  local home; home="$(mktemp -d "$work_dir/home.XXXXXX")"
  local alpha beta
  alpha="$(mktemp -d "$work_dir/alpha.XXXXXX")"; fixture_board_toml "$alpha"
  beta="$(mktemp -d "$work_dir/beta.XXXXXX")"; fixture_board_toml "$beta"
  run "$home" add alpha --repo "$alpha" >/dev/null
  run "$home" add beta --repo "$beta" >/dev/null
  rm -rf "$alpha"
  printf '%s' "$home"
}

home="$(new_home_with_broken_alpha)"

for verb in status halt resume cleanup; do
  status=0
  run "$home" "$verb" beta >"$work_dir/$verb.out" 2>"$work_dir/$verb.err" || status=$?
  if [[ $status -eq 0 ]]; then
    ok "$verb of a healthy board works while another board's repo is missing"
  else
    not_ok "$verb beta: status=$status err=$(cat "$work_dir/$verb.err")"
  fi
done

status=0
listing="$(run "$home" list 2>"$work_dir/list.err")" || status=$?
if [[ $status -ne 0 ]] && [[ "$listing" == *"alpha"*"unloadable"* ]] \
   && printf '%s\n' "$listing" | grep -q "^beta	/"; then
  ok "list names every board, marks the broken one, and exits non-zero"
else
  not_ok "list with a broken board: status=$status listing=$listing err=$(cat "$work_dir/list.err")"
fi

status=0
run "$home" remove beta >/dev/null 2>"$work_dir/rm-beta.err" || status=$?
if [[ $status -eq 0 ]] && ! grep -qxF '[boards.beta]' "$home/boards.toml" \
   && grep -qxF '[boards.alpha]' "$home/boards.toml"; then
  ok "remove of a healthy board works while another board's repo is missing"
else
  not_ok "remove beta: status=$status err=$(cat "$work_dir/rm-beta.err")"
fi

status=0
run "$home" remove alpha >/dev/null 2>"$work_dir/rm-alpha.err" || status=$?
if [[ $status -eq 0 ]] && ! grep -qxF '[boards.alpha]' "$home/boards.toml" \
   && grep -q "not a directory" "$work_dir/rm-alpha.err"; then
  ok "the broken board itself is removable, and says why its repo was not checked"
else
  not_ok "remove alpha: status=$status err=$(cat "$work_dir/rm-alpha.err")"
fi

home2="$(new_home_with_broken_alpha)"
status=0
run "$home2" remove alpha --force >/dev/null 2>"$work_dir/rm-force.err" || status=$?
if [[ $status -eq 0 ]] && ! grep -qxF '[boards.alpha]' "$home2/boards.toml"; then
  ok "remove --force of the broken board works"
else
  not_ok "remove alpha --force: status=$status err=$(cat "$work_dir/rm-force.err")"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
