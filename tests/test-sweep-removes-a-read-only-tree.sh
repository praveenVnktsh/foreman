#!/usr/bin/env bash
# Claim: `sweep.sh --orphans` removes an orphaned worktree and scratch dir that
# hold read-only directories, and still sweeps everything after them.
#
# Go writes its module cache read-only, so a build's scratch can hold a tree
# `rm -rf` refuses. The first refusal ended the whole sweep under `set -e`:
# every later worktree, scratch dir and leaked ref stayed, on every pass, until
# someone deleted the tree by hand. The sweep now makes such a tree writable and
# deletes it again.
#
# `claude` is the only external boundary stubbed; its registry is empty, so
# every tree here is an orphan.
set -uo pipefail
# shellcheck source=lib/without-board.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/without-board.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work/target"
git init -q -b main "$target"
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" alpha "$target"

stub="$work/bin"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\n[[ "$1" == agents ]] && echo "[]"\nexit 0\n' >"$stub/claude"
chmod +x "$stub/claude"

run() { env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha PATH="$stub:$PATH" "$@"; }

# A module cache as Go leaves it: a directory of read-only files, itself
# read-only.
read_only_cache() { # <dir>
  mkdir -p "$1/pkg/mod/example.com/m@v1"
  printf 'package m\n' >"$1/pkg/mod/example.com/m@v1/m.go"
  chmod -R a-w "$1/pkg"
}

first="$target/.claude/worktrees/foreman-alpha-PRA-1"
second="$target/.claude/worktrees/foreman-alpha-PRA-2"
mkdir -p "$first" "$second"
read_only_cache "$first"
scratch="$(run "$root/bin/tmp-dir.sh" "$first")"
mkdir -p "$scratch"
read_only_cache "$scratch"

out="$(run bash "$root/skills/board/sweep.sh" --orphans 2>&1)"
status=$?
[[ "$status" -eq 0 ]] && ok "the sweep exits zero" || bad "the sweep exited $status: $out"
[[ ! -e "$first" ]] && ok "an orphaned worktree holding a read-only tree is removed" \
  || bad "the read-only worktree survived: $out"
[[ ! -e "$scratch" ]] && ok "and so is its read-only scratch" \
  || bad "the read-only scratch survived: $out"
[[ ! -e "$second" ]] && ok "and the sweep goes on to the next worktree" \
  || bad "the sweep stopped before the next worktree: $out"

[[ "$fail" -eq 0 ]] && printf 'PASS: the sweep removes a read-only tree\n'
exit "$fail"
