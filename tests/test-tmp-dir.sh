#!/usr/bin/env bash
# `ops/tmp-dir.sh` is the only place the test-scratch path is derived. Prove it.
#
# Two callers have to agree forever: the `justfile`, whose test recipes export
# the result as TMPDIR, and the board's `config.sh`, which creates that
# directory at dispatch and reaps it in `sweep.sh`. They used to compute it
# separately and agreed only because two hardcoded strings matched, under two
# different environment variables — so moving either moved the writes without
# moving the reaper, and the only symptom was scratch accumulating forever.
#
# So most of what follows asserts *routing* rather than arithmetic: each caller
# runs against a fixture checkout whose `ops/tmp-dir.sh` is a stub printing a
# sentinel. A caller that went back to computing the path itself would return
# the real path, not the sentinel, and fail here. Checking that the two agree
# today would not catch that — two independent derivations agreed today too.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/tmp-dir.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect() {
  local want="$1" got="$2" what="$3"
  [[ "$got" == "$want" ]] || fail "$what: expected [$want], got [$got]"
}

# A checkout at a path we choose, so the "named after its own checkout" rule is
# checked against a name that cannot coincidentally be the real one.
new_checkout() {
  local dir="$work_dir/$1"
  mkdir -p "$dir/ops"
  cp "$script" "$dir/ops/tmp-dir.sh"
  echo "$dir"
}

echo "==> the no-argument form names the checkout the script is committed to"
checkout="$(new_checkout board-PRA-1)"
expect "$HOME/.murmr-board/tmp/board-PRA-1" "$("$checkout/ops/tmp-dir.sh")" "own checkout"

echo "==> an argument names that worktree instead, existing or not"
expect "$HOME/.murmr-board/tmp/board-PRA-2" \
  "$("$checkout/ops/tmp-dir.sh" /nowhere/at/all/board-PRA-2)" "worktree argument"
expect "$HOME/.murmr-board/tmp/board-PRA-2" \
  "$("$checkout/ops/tmp-dir.sh" /nowhere/at/all/board-PRA-2/)" "trailing slash"

echo "==> --root is the directory those two live in"
expect "$HOME/.murmr-board/tmp" "$("$checkout/ops/tmp-dir.sh" --root)" "--root"

echo "==> MURMR_TMP_ROOT and BOARD_HOME each move the whole thing"
expect "/scratch/board-PRA-1" \
  "$(MURMR_TMP_ROOT=/scratch "$checkout/ops/tmp-dir.sh")" "MURMR_TMP_ROOT"
expect "/elsewhere/tmp/board-PRA-1" \
  "$(BOARD_HOME=/elsewhere "$checkout/ops/tmp-dir.sh")" "BOARD_HOME"
expect "/scratch" \
  "$(MURMR_TMP_ROOT=/scratch BOARD_HOME=/elsewhere "$checkout/ops/tmp-dir.sh" --root)" \
  "MURMR_TMP_ROOT wins over BOARD_HOME"

echo "==> an unrecognized option is refused, not read as a worktree"
status=0
"$checkout/ops/tmp-dir.sh" --wat >/dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "unknown option: expected exit 2, got $status"

# --- routing -----------------------------------------------------------------

# The fixture checkout each caller runs against: the real caller, a stub script.
stub_checkout() {
  local dir="$work_dir/$1"
  mkdir -p "$dir/ops" "$dir/.claude/skills/board"
  printf '#!/usr/bin/env bash\nprintf "SENTINEL%%s\\n" "${1:+ $1}"\n' > "$dir/ops/tmp-dir.sh"
  chmod +x "$dir/ops/tmp-dir.sh"
  cp "$repo_root/justfile" "$dir/justfile"
  cp "$repo_root/.claude/skills/board/config.sh" "$dir/.claude/skills/board/config.sh"
  echo "$dir"
}

echo "==> the board asks the script for the scratch root and for each worktree"
stub="$(stub_checkout stubbed)"
board_root="$(env REPO="$stub" bash -c 'source "$REPO/.claude/skills/board/config.sh"
                                        printf "%s\n" "$AGENT_TMP_ROOT"')"
expect "SENTINEL --root" "$board_root" "config.sh AGENT_TMP_ROOT"
board_paired="$(env REPO="$stub" bash -c 'source "$REPO/.claude/skills/board/config.sh"
                                          agent_tmp_for /some/worktree/board-PRA-3')"
expect "SENTINEL /some/worktree/board-PRA-3" "$board_paired" "config.sh agent_tmp_for"

echo "==> the board stops rather than guessing when the script is unusable"
rm "$stub/ops/tmp-dir.sh"
status=0
env REPO="$stub" bash -c 'source "$REPO/.claude/skills/board/config.sh"' >/dev/null 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "config.sh sourced cleanly with no ops/tmp-dir.sh"

echo "==> the justfile exports what the script prints"
# No skip branch, deliberately. This was written to skip when `just` was absent,
# which is the state of the stock CI image -- so the one caller most likely to
# drift was the one whose assertion never ran on a pull request, and a change
# that put the derivation back in the justfile would have gone green through the
# Operations job. The workflow installs `just` for this; if that ever stops
# being true, this has to go red rather than quietly stop checking. `just` is
# the repo's top-level command surface, so requiring it to test the justfile
# costs nothing anyone was not already paying.
command -v just >/dev/null 2>&1 \
  || fail "just is not installed; it is required to check what the justfile derives"
stub="$(stub_checkout stubbed-just)"
just_value="$(just --justfile "$stub/justfile" --working-directory "$stub" --evaluate tmp_dir)"
expect "SENTINEL" "$just_value" "justfile tmp_dir"

echo "PASS"
