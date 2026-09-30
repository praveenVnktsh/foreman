#!/usr/bin/env bash
# `evidence.sh main <path>` reads origin's default branch, never a tag of the same name.
#
# Found auditing the board on 2026-09-30. evidence.sh fetched the bare refspec
# `main`, and git resolves a bare name through refs/tags/ BEFORE refs/heads/.
# A tag named `main` on origin was served under a provenance line naming
# origin/main, so a tick weighing a finding read bytes that are not on the
# branch it merges into. It also read `main` on a target whose default branch
# is something else.
#
# Only the network is replaced, by a local bare origin. evidence.sh, config.sh
# and git run for real.

set -euo pipefail
# Run directly, too, in a card agent: clear the board it inherits.
# shellcheck source=lib/without-board.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/without-board.sh"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$repo_root/skills/board/evidence.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
export BOARD_HOME="$work_dir/board-home"

inst_home="$work_dir/foreman-home"
fixture_add_instance "$inst_home" fixture
export HOME="$inst_home" FOREMAN_HOME="$inst_home/.foreman" FOREMAN_INSTANCE=fixture

failures=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

git_q() {
  git -c user.name="Evidence Test" -c user.email="evidence-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# make_origin <name> <default-branch>: a bare origin whose default branch holds
# `on the branch`, carrying a tag named `main` that points at a commit holding
# `on the tag`. Prints the path of a clone of it.
make_origin() {
  local name="$1" branch="$2" seed="$work_dir/$1-seed" origin="$work_dir/$1.git"
  git_q init -q -b "$branch" "$seed"
  fixture_board_toml "$seed"
  echo "on the branch" > "$seed/release.sh"
  git_q -C "$seed" add -A
  git_q -C "$seed" commit -q -m "the real branch"
  git_q -C "$seed" checkout -q -b decoy
  echo "on the tag" > "$seed/release.sh"
  git_q -C "$seed" commit -q -am "the decoy"
  git_q -C "$seed" checkout -q "$branch"
  git_q -C "$seed" tag main decoy
  git_q clone -q --bare "$seed" "$origin"
  git_q -C "$origin" symbolic-ref HEAD "refs/heads/$branch"
  git_q clone -q "$origin" "$work_dir/$name-tick"
  echo "$work_dir/$name-tick"
}

name="a tag named main on origin is not read as the main branch"
tick="$(make_origin tagged main)"
status=0
out="$(REPO="$tick" "$evidence" main release.sh 2>"$work_dir/tagged.err")" || status=$?
if [[ "$status" -eq 0 && "$out" == "on the branch" ]] \
   && grep -q 'origin/main' "$work_dir/tagged.err"; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, stderr: $(cat "$work_dir/tagged.err"))"
fi

name="a default branch other than main is the branch read"
tick="$(make_origin trunked trunk)"
status=0
out="$(REPO="$tick" "$evidence" main release.sh 2>"$work_dir/trunked.err")" || status=$?
if [[ "$status" -eq 0 && "$out" == "on the branch" ]] \
   && grep -q 'origin/trunk' "$work_dir/trunked.err"; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, stderr: $(cat "$work_dir/trunked.err"))"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all default-branch evidence cases passed"
