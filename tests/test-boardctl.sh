#!/usr/bin/env bash
# bin/boardctl is the only writer of $FOREMAN_HOME/boards.toml. Prove:
# `add` appends a board bin/boards.py can then read, refuses a duplicate name
# and a repo with no board.toml, and reverts boards.toml (leaving it
# byte-identical, with no leftover temp file) when the file that write would
# produce does not parse; `remove` deletes one board's table, leaves its
# runtime directory alone, and reverts the same way; `list` and `status`
# read boards.toml through bin/boards.py; `halt`/`resume` toggle
# $FOREMAN_HOME/instances/<name>/HALT even before that directory otherwise
# exists, and refuse an undeclared board; `cleanup` deletes
# instances/<name>/last-cleanup (a no-op when it is not there) and refuses an
# undeclared board without creating its runtime directory.
#
# `add` writes no priority line unless `--priority N` is passed, and refuses a
# priority that is not a non-negative integer, leaving boards.toml
# byte-identical.
#
# No network is reached anywhere here: `add` never calls bin/resolve-ids.py, so
# there is no Linear stub to start.
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
fail_hard() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[[ -x "$boardctl" ]] || fail_hard "$boardctl is missing or not executable"

# run <home> <args...> -- boardctl with FOREMAN_HOME pinned at a scratch
# directory, so nothing here can ever touch a real ~/.foreman.
run() {
  local home="$1"; shift
  FOREMAN_HOME="$home" "$boardctl" "$@"
}

new_home() { mktemp -d "$work_dir/home.XXXXXX"; }

# A repo every case here can point --repo at: the smallest board.toml
# bin/contract.py accepts, from the shared fixture (tests/lib/
# instance-fixture.sh) so this file does not re-derive contract.py's own
# required-key list.
new_target() {
  local dir; dir="$(mktemp -d "$work_dir/target.XXXXXX")"
  fixture_board_toml "$dir"
  printf '%s' "$dir"
}

# =============================================================================
# Case: add appends a board that bin/boards.py can then read back
# =============================================================================
home1="$(new_home)"
target1="$(new_target)"
if run "$home1" add alpha --repo "$target1" >"$work_dir/add1.out" 2>"$work_dir/add1.err"; then
  listing="$(run "$home1" list)"
  if [[ "$listing" == *"alpha"* && "$listing" == *"$target1"* ]]; then
    ok "add appends a board that bin/boards.py can then read back"
  else
    not_ok "add appends a board that bin/boards.py can then read back: list was: $listing"
  fi
else
  not_ok "add appends a board that bin/boards.py can then read back: add failed: $(cat "$work_dir/add1.err")"
fi

# =============================================================================
# Case: add records an optional --key-file
# =============================================================================
home2="$(new_home)"
target2="$(new_target)"
key2="$work_dir/other.key"
printf 'secret\n' >"$key2"
run "$home2" add withkey --repo "$target2" --key-file "$key2" \
  >"$work_dir/add2.out" 2>"$work_dir/add2.err"
if grep -qF "key = \"$key2\"" "$home2/boards.toml" 2>/dev/null; then
  ok "add records an optional --key-file"
else
  not_ok "add records an optional --key-file: $(cat "$home2/boards.toml" 2>&1)"
fi

# =============================================================================
# Case: add REFUSES a name that already exists, leaving boards.toml unchanged
# =============================================================================
before="$(cat "$home1/boards.toml")"
status=0
run "$home1" add alpha --repo "$target1" \
  >"$work_dir/add3.out" 2>"$work_dir/add3.err" || status=$?
after="$(cat "$home1/boards.toml")"
if [[ $status -ne 0 ]] && [[ "$after" == "$before" ]] \
    && grep -qi "alpha" "$work_dir/add3.err"; then
  ok "add REFUSES a name that already exists, leaving boards.toml unchanged"
else
  not_ok "add REFUSES a name that already exists, leaving boards.toml unchanged: status=$status err=$(cat "$work_dir/add3.err")"
fi

# =============================================================================
# Case: add REFUSES a repo with no board.toml, naming the path
# =============================================================================
home3="$(new_home)"
no_toml="$work_dir/no-toml-repo"
mkdir -p "$no_toml"
status=0
run "$home3" add nokt --repo "$no_toml" \
  >"$work_dir/add4.out" 2>"$work_dir/add4.err" || status=$?
if [[ $status -ne 0 ]] \
    && [[ "$(cat "$work_dir/add4.err")" == *"no board.toml"* ]] \
    && [[ "$(cat "$work_dir/add4.err")" == *"$no_toml"* ]] \
    && [[ ! -e "$home3/boards.toml" ]]; then
  ok "add REFUSES a repo with no board.toml, naming the path"
else
  not_ok "add REFUSES a repo with no board.toml, naming the path: status=$status err=$(cat "$work_dir/add4.err")"
fi

# =============================================================================
# Case: add REFUSES an instance name containing a hyphen
# =============================================================================
home4="$(new_home)"
status=0
run "$home4" add "bad-name" --repo "$target1" \
  >"$work_dir/add5.out" 2>"$work_dir/add5.err" || status=$?
if [[ $status -ne 0 ]] && [[ "$(cat "$work_dir/add5.err")" == *invalid* ]] \
    && [[ ! -e "$home4/boards.toml" ]]; then
  ok "add REFUSES a board name containing a hyphen"
else
  not_ok "add REFUSES a board name containing a hyphen: status=$status err=$(cat "$work_dir/add5.err")"
fi

# =============================================================================
# Case: add reverts boards.toml when the result would not parse
#
# The pre-existing file already fails to load -- one declared board's repo
# was removed out from under it -- for a reason that has nothing to do with
# the board being added. add must still refuse: appending a valid table to
# an invalid file produces another invalid file, and bin/boards.py's own
# validation walks every board, not just the new one.
# =============================================================================
home5="$(new_home)"
mkdir -p "$home5"
good5="$(new_target)"
stale5="$(new_target)"
cat >"$home5/boards.toml" <<TOML
[boards.good]
repo = "$good5"

[boards.stale]
repo = "$stale5"
TOML
rm -rf "$stale5"
before5="$(cat "$home5/boards.toml")"

new5="$(new_target)"
status=0
run "$home5" add newname --repo "$new5" \
  >"$work_dir/add6.out" 2>"$work_dir/add6.err" || status=$?
after5="$(cat "$home5/boards.toml")"
leftover="$(find "$home5" -maxdepth 1 -type f ! -name boards.toml 2>/dev/null)"
if [[ $status -ne 0 ]] && [[ "$after5" == "$before5" ]] && [[ -z "$leftover" ]]; then
  ok "add reverts boards.toml when the result would not parse"
else
  not_ok "add reverts boards.toml when the result would not parse: status=$status changed=$([[ "$after5" != "$before5" ]] && echo yes || echo no) leftover=$leftover err=$(cat "$work_dir/add6.err")"
fi

# =============================================================================
# Case: remove deletes one board's table and leaves its runtime directory alone
# =============================================================================
home6="$(new_home)"
target6a="$(new_target)"
target6b="$(new_target)"
run "$home6" add keep --repo "$target6a" >/dev/null 2>&1
run "$home6" add drop --repo "$target6b" >/dev/null 2>&1
mkdir -p "$home6/instances/drop/cards"
printf 'history\n' >"$home6/instances/drop/cards/note"

run "$home6" remove drop >"$work_dir/rm1.out" 2>"$work_dir/rm1.err"
listing6="$(run "$home6" list)"
if [[ "$listing6" == *"keep"* ]] && [[ "$listing6" != *"drop"* ]] \
    && [[ -f "$home6/instances/drop/cards/note" ]] \
    && grep -q "$home6/instances/drop" "$work_dir/rm1.out"; then
  ok "remove deletes one board's table and leaves its runtime directory alone"
else
  not_ok "remove deletes one board's table and leaves its runtime directory alone: listing=$listing6 out=$(cat "$work_dir/rm1.out")"
fi

# =============================================================================
# Case: remove REFUSES an undeclared board name
# =============================================================================
status=0
run "$home6" remove nosuch >"$work_dir/rm2.out" 2>"$work_dir/rm2.err" || status=$?
if [[ $status -ne 0 ]] && grep -qi "nosuch" "$work_dir/rm2.err"; then
  ok "remove REFUSES an undeclared board name"
else
  not_ok "remove REFUSES an undeclared board name: status=$status err=$(cat "$work_dir/rm2.err")"
fi

# =============================================================================
# Case: remove reverts boards.toml when the result would still not parse
# =============================================================================
home7="$(new_home)"
good7="$(new_target)"
stale7="$(new_target)"
cat >"$home7/boards.toml" <<TOML
[boards.good]
repo = "$good7"

[boards.stale]
repo = "$stale7"
TOML
rm -rf "$stale7"
before7="$(cat "$home7/boards.toml")"

status=0
run "$home7" remove good >"$work_dir/rm3.out" 2>"$work_dir/rm3.err" || status=$?
after7="$(cat "$home7/boards.toml")"
leftover7="$(find "$home7" -maxdepth 1 -type f ! -name boards.toml 2>/dev/null)"
if [[ $status -ne 0 ]] && [[ "$after7" == "$before7" ]] && [[ -z "$leftover7" ]]; then
  ok "remove reverts boards.toml when the result would still not parse"
else
  not_ok "remove reverts boards.toml when the result would still not parse: status=$status changed=$([[ "$after7" != "$before7" ]] && echo yes || echo no) leftover=$leftover7"
fi

# =============================================================================
# Case: list names every board and the repo each serves
# =============================================================================
home8="$(new_home)"
target8a="$(new_target)"
target8b="$(new_target)"
run "$home8" add alpha --repo "$target8a" >/dev/null 2>&1
run "$home8" add beta --repo "$target8b" >/dev/null 2>&1
listing8="$(run "$home8" list)"
if [[ "$listing8" == *"alpha"* && "$listing8" == *"$target8a"* \
   && "$listing8" == *"beta"* && "$listing8" == *"$target8b"* ]]; then
  ok "list names every board and the repo each serves"
else
  not_ok "list names every board and the repo each serves: $listing8"
fi

# =============================================================================
# Case: status reports the repo and defaults to unresolved ids and running
# =============================================================================
status_out="$(run "$home8" status alpha)"
if [[ "$status_out" == *"$target8a"* ]] \
    && [[ "$status_out" == *"not resolved"* ]] \
    && [[ "$status_out" == *"running"* ]]; then
  ok "status reports the repo and defaults to unresolved ids and running"
else
  not_ok "status reports the repo and defaults to unresolved ids and running: $status_out"
fi

# =============================================================================
# Case: status reports ids resolved once ids.env exists
#
# boardctl never writes ids.env itself -- bin/resolve-ids.py does, as a
# cache -- so this test creates it directly rather than driving resolution.
# =============================================================================
mkdir -p "$home8/instances/alpha"
: >"$home8/instances/alpha/ids.env"
status_out2="$(run "$home8" status alpha)"
if echo "$status_out2" | grep -qE "^ids: *resolved$"; then
  ok "status reports ids resolved once ids.env exists"
else
  not_ok "status reports ids resolved once ids.env exists: $status_out2"
fi

# =============================================================================
# Case: status REFUSES a board that is not declared
# =============================================================================
status=0
run "$home8" status nosuch >"$work_dir/status_bad.out" 2>"$work_dir/status_bad.err" || status=$?
if [[ $status -ne 0 ]] && grep -qi "nosuch" "$work_dir/status_bad.err"; then
  ok "status REFUSES a board that is not declared"
else
  not_ok "status REFUSES a board that is not declared: status=$status err=$(cat "$work_dir/status_bad.err")"
fi

# =============================================================================
# Case: halt creates HALT even before the runtime directory otherwise exists
#
# `add` never creates $FOREMAN_HOME/instances/<name>/ any more -- only a tick
# does, on that board's first run. An operator must still be able to halt a
# board before it has ever ticked.
# =============================================================================
home9="$(new_home)"
target9="$(new_target)"
run "$home9" add solo --repo "$target9" >/dev/null 2>&1
[[ -d "$home9/instances/solo" ]] && fail_hard "test setup bug: instances/solo already exists before halt"

run "$home9" halt solo >"$work_dir/halt1.out" 2>"$work_dir/halt1.err"
if [[ -f "$home9/instances/solo/HALT" ]]; then
  ok "halt creates HALT even before the runtime directory otherwise exists"
else
  not_ok "halt creates HALT even before the runtime directory otherwise exists: $(cat "$work_dir/halt1.err")"
fi

status_out3="$(run "$home9" status solo)"
if [[ "$status_out3" == *"halted"* ]]; then
  ok "status reports halted after halt"
else
  not_ok "status reports halted after halt: $status_out3"
fi

# =============================================================================
# Case: resume removes HALT
# =============================================================================
run "$home9" resume solo >"$work_dir/resume1.out" 2>"$work_dir/resume1.err"
if [[ ! -e "$home9/instances/solo/HALT" ]]; then
  ok "resume removes HALT"
else
  not_ok "resume removes HALT"
fi
status_out4="$(run "$home9" status solo)"
if [[ "$status_out4" == *"running"* ]]; then
  ok "status reports running after resume"
else
  not_ok "status reports running after resume: $status_out4"
fi

# =============================================================================
# Case: halt and resume REFUSE an undeclared board
# =============================================================================
status=0
run "$home9" halt nosuch >"$work_dir/halt2.out" 2>"$work_dir/halt2.err" || status=$?
if [[ $status -ne 0 ]] && [[ ! -e "$home9/instances/nosuch" ]]; then
  ok "halt REFUSES an undeclared board"
else
  not_ok "halt REFUSES an undeclared board: status=$status err=$(cat "$work_dir/halt2.err") created=$([[ -e "$home9/instances/nosuch" ]] && echo yes || echo no)"
fi

status=0
run "$home9" resume nosuch >"$work_dir/resume2.out" 2>"$work_dir/resume2.err" || status=$?
if [[ $status -ne 0 ]]; then
  ok "resume REFUSES an undeclared board"
else
  not_ok "resume REFUSES an undeclared board: status=$status"
fi

# =============================================================================
# Case: cleanup removes an existing last-cleanup stamp
# =============================================================================
mkdir -p "$home9/instances/solo"
: >"$home9/instances/solo/last-cleanup"
status=0
run "$home9" cleanup solo >"$work_dir/cleanup1.out" 2>"$work_dir/cleanup1.err" || status=$?
if [[ $status -eq 0 ]] && [[ ! -e "$home9/instances/solo/last-cleanup" ]]; then
  ok "cleanup removes an existing last-cleanup stamp"
else
  not_ok "cleanup removes an existing last-cleanup stamp: status=$status err=$(cat "$work_dir/cleanup1.err")"
fi

# =============================================================================
# Case: cleanup with no stamp still exits 0 -- removing a stamp that is not
# there is the same outcome, not an error
# =============================================================================
status=0
run "$home9" cleanup solo >"$work_dir/cleanup2.out" 2>"$work_dir/cleanup2.err" || status=$?
if [[ $status -eq 0 ]]; then
  ok "cleanup with no stamp present still exits 0"
else
  not_ok "cleanup with no stamp present still exits 0: status=$status err=$(cat "$work_dir/cleanup2.err")"
fi

# =============================================================================
# Case: cleanup REFUSES an undeclared board, creating no directory
# =============================================================================
status=0
run "$home9" cleanup nosuch >"$work_dir/cleanup3.out" 2>"$work_dir/cleanup3.err" || status=$?
if [[ $status -ne 0 ]] && [[ ! -e "$home9/instances/nosuch" ]]; then
  ok "cleanup REFUSES an undeclared board, creating no directory"
else
  not_ok "cleanup REFUSES an undeclared board, creating no directory: status=$status err=$(cat "$work_dir/cleanup3.err") created=$([[ -e "$home9/instances/nosuch" ]] && echo yes || echo no)"
fi

# =============================================================================
# Priorities `add` writes
#
# There is one foreman, so `add` writes no priority line -- the implicit
# priority 1. --priority N still writes a floor for a board that wants one.
# =============================================================================

# board_priority <foreman_home> <name> -- PRIORITY as bin/boards.py reads it.
board_priority() {
  FOREMAN_HOME="$1" "$repo_root/bin/boards.py" "$2" | tr '\0' '\n' \
    | awk 'prev == "PRIORITY" { print; exit } { prev = $0 }'
}

if ! grep -q '^priority' "$home1/boards.toml"; then
  ok "add writes no priority line"
else
  not_ok "add writes no priority line: $(cat "$home1/boards.toml")"
fi

got="$(board_priority "$home1" alpha 2>&1)"
if [[ "$got" == "1" ]]; then
  ok "bin/boards.py reads PRIORITY 1 for a board added with no priority"
else
  not_ok "bin/boards.py reads PRIORITY 1 for a board added with no priority: got [$got]"
fi

home16="$(new_home)"
run "$home16" add chosen --repo "$(new_target)" --priority 3 >/dev/null 2>"$work_dir/prio2.err" || true
if grep -qx 'priority = 3' "$home16/boards.toml" 2>/dev/null \
    && [[ "$(grep -c '^priority' "$home16/boards.toml")" == "1" ]]; then
  ok "--priority 3 writes priority = 3 in the default installation"
else
  not_ok "--priority 3 writes priority = 3 in the default installation: $(cat "$work_dir/prio2.err") $(cat "$home16/boards.toml" 2>&1)"
fi

for bad_priority in -1 x; do
  cp "$home16/boards.toml" "$work_dir/prio-before.toml"
  status=0
  run "$home16" add refused --repo "$(new_target)" --priority "$bad_priority" \
    >/dev/null 2>"$work_dir/prio-bad.err" || status=$?
  if [[ $status -ne 0 ]] && cmp -s "$work_dir/prio-before.toml" "$home16/boards.toml"; then
    ok "--priority $bad_priority is refused and boards.toml is left byte-identical"
  else
    not_ok "--priority $bad_priority is refused and boards.toml is left byte-identical: status=$status err=$(cat "$work_dir/prio-bad.err")"
  fi
done

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
