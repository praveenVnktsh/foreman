#!/usr/bin/env bash
# `bin/tmp-dir.sh` is the only place the agent-scratch path is derived. Prove it.
#
# It used to have two callers that had to agree forever: the `justfile`, whose
# test recipes exported the result as TMPDIR, and the board's `config.sh`,
# which creates that directory at dispatch and reaps it in `sweep.sh`. They
# computed it separately and agreed only because two hardcoded strings
# matched, under two different environment variables -- so moving either
# moved the writes without moving the reaper, and the only symptom was
# scratch accumulating forever. foreman carries no justfile of its own; the
# reasoning still holds because the second author is now the target's own
# test runner, invoked through TEST_COMMAND with whatever TMPDIR config.sh
# hands it -- so the routing check below still matters, just with one fewer
# fixture to build.
#
# Most of what follows asserts *routing* rather than arithmetic: config.sh is
# sourced against a fixture installation whose `bin/tmp-dir.sh` is a stub
# printing a sentinel. A caller that went back to computing the path itself
# would return the real path, not the sentinel, and fail here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/tmp-dir.sh"

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
  mkdir -p "$dir/bin"
  cp "$script" "$dir/bin/tmp-dir.sh"
  echo "$dir"
}

echo "==> the no-argument form names the checkout the script is committed to"
checkout="$(new_checkout board-PRA-1)"
expect "$HOME/.foreman/tmp/board-PRA-1" "$("$checkout/bin/tmp-dir.sh")" "own checkout"

echo "==> an argument names that worktree instead, existing or not"
expect "$HOME/.foreman/tmp/board-PRA-2" \
  "$("$checkout/bin/tmp-dir.sh" /nowhere/at/all/board-PRA-2)" "worktree argument"
expect "$HOME/.foreman/tmp/board-PRA-2" \
  "$("$checkout/bin/tmp-dir.sh" /nowhere/at/all/board-PRA-2/)" "trailing slash"

echo "==> --root is the directory those two live in"
expect "$HOME/.foreman/tmp" "$("$checkout/bin/tmp-dir.sh" --root)" "--root"

echo "==> FOREMAN_TMP_ROOT and BOARD_HOME each move the whole thing"
expect "/scratch/board-PRA-1" \
  "$(FOREMAN_TMP_ROOT=/scratch "$checkout/bin/tmp-dir.sh")" "FOREMAN_TMP_ROOT"
expect "/elsewhere/tmp/board-PRA-1" \
  "$(BOARD_HOME=/elsewhere "$checkout/bin/tmp-dir.sh")" "BOARD_HOME"
expect "/scratch" \
  "$(FOREMAN_TMP_ROOT=/scratch BOARD_HOME=/elsewhere "$checkout/bin/tmp-dir.sh" --root)" \
  "FOREMAN_TMP_ROOT wins over BOARD_HOME"

echo "==> an unrecognized option is refused, not read as a worktree"
status=0
"$checkout/bin/tmp-dir.sh" --wat >/dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "unknown option: expected exit 2, got $status"

# --- routing -----------------------------------------------------------------
#
# Under the instance model config.sh lives at one real path in the foreman
# installation and is never copied into a target checkout, so the fixture here
# is a stub *installation* -- config.sh and contract.py copied unchanged, and
# bin/tmp-dir.sh replaced with a sentinel -- pointed at a separate, minimal
# target directory through instance.env, the same wiring
# test-config-resolves-instance.sh exercises.

stub_installation() {
  local dir="$work_dir/$1"
  mkdir -p "$dir/skills/board" "$dir/bin"
  printf '#!/usr/bin/env bash\nprintf "SENTINEL%%s\\n" "${1:+ $1}"\n' > "$dir/bin/tmp-dir.sh"
  chmod +x "$dir/bin/tmp-dir.sh"
  cp "$repo_root/skills/board/config.sh" "$dir/skills/board/config.sh"
  cp "$repo_root/bin/contract.py" "$dir/bin/contract.py"
  echo "$dir"
}

target_stub() {
  local dir="$work_dir/$1"; mkdir -p "$dir"
  cat >"$dir/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
  echo "$dir"
}

instance_home() {
  local dir="$work_dir/$1" target="$2"
  mkdir -p "$dir/.foreman/instances/demo"
  printf 'REPO=%s\n' "$target" >"$dir/.foreman/instances/demo/instance.env"
  echo "$dir"
}

echo "==> the board asks bin/tmp-dir.sh for the scratch root, not the target"
install="$(stub_installation stubbed)"
target="$(target_stub target-a)"
home="$(instance_home home-a "$target")"
board_root="$(env HOME="$home" FOREMAN_INSTANCE=demo bash -c \
  "source '$install/skills/board/config.sh'; printf '%s\n' \"\$AGENT_TMP_ROOT\"")"
expect "SENTINEL --root" "$board_root" "config.sh AGENT_TMP_ROOT"

echo "==> the board stops rather than guessing when the script is unusable"
rm "$install/bin/tmp-dir.sh"
status=0
env HOME="$home" FOREMAN_INSTANCE=demo bash -c \
  "source '$install/skills/board/config.sh'" >/dev/null 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "config.sh sourced cleanly with no bin/tmp-dir.sh"

# NOTE: agent_tmp_for() is not exercised here. Its body still asks
# "$REPO/ops/tmp-dir.sh" -- $REPO being the *target*, which under the instance
# model ships no such script -- because Task 3 (task-3-decisions.md section 4)
# deliberately leaves every function body in config.sh, including this one,
# for Task 5 to rewrite. Routing coverage for it belongs with that rewrite.

echo "PASS"
