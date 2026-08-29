#!/usr/bin/env bash
# bin/boardctl is the only writer of instance.env and linear.key. Prove:
# `add` creates an instance and resolves its ids through a stub Linear API;
# `add` refuses rather than clobbers an existing instance or a repo with no
# board.toml; the linear key lands at mode 0600 and is never printed; halt
# and resume toggle $INSTANCE_HOME/HALT and status reports which; and list
# names every instance and the repo it serves.
#
# No case reaches api.linear.app -- FOREMAN_LINEAR_API_URL points boardctl's
# `add` at tests/lib/linear-stub.py, the same local http.server stub
# tests/test-resolve-ids.sh already uses.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
boardctl="$repo_root/bin/boardctl"
stub="$repo_root/tests/lib/linear-stub.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" >/dev/null 2>&1 || true
  [[ -n "$STUB_PID" ]] && wait "$STUB_PID" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
fail_hard() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[[ -x "$boardctl" ]] || fail_hard "$boardctl is missing or not executable"

start_stub() {
  # start_stub <scenario.json> -- sets STUB_URL, blocks until the port is up.
  local scenario="$1" port_file="$work_dir/stub.port"
  rm -f "$port_file"
  python3 "$stub" "$scenario" >"$port_file" 2>"$work_dir/stub.err" &
  STUB_PID=$!
  local tries=0
  until [[ -s "$port_file" ]]; do
    tries=$((tries + 1))
    if [[ $tries -gt 100 ]]; then
      fail_hard "stub server never printed a port: $(cat "$work_dir/stub.err")"
    fi
    kill -0 "$STUB_PID" 2>/dev/null || fail_hard "stub server exited early: $(cat "$work_dir/stub.err")"
    sleep 0.05
  done
  STUB_URL="http://127.0.0.1:$(cat "$port_file")/graphql"
}

stop_stub() {
  [[ -n "$STUB_PID" ]] || return 0
  kill "$STUB_PID" >/dev/null 2>&1 || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
}

file_mode() { # <file> -- prints an octal string like "600"
  python3 -c '
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
' "$1"
}

read_id() { # <file> <KEY>
  local line
  line="$(grep "^$2=" "$1" || true)"
  printf '%s' "${line#*=}"
}

# A scenario every "happy path" call below can resolve cleanly: one team, one
# project, all five states (typed correctly), and all four labels already
# present -- so ensure_labels() never has to create one, keeping the fixture
# boring rather than exercising resolve-ids.py's own logic a second time
# (test-resolve-ids.sh already covers that machinery in full).
happy_scenario() {
  cat >"$work_dir/happy.json" <<'JSON'
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",        "type": "unstarted"},
    {"id": "state-inprogress", "name": "In Progress", "type": "started"},
    {"id": "state-inreview",   "name": "In Review",   "type": "started"},
    {"id": "state-done",       "name": "Done",        "type": "completed"}
  ],
  "labels": [
    {"id": "label-followup",         "name": "follow-up"},
    {"id": "label-followupswritten", "name": "follow-ups-written"},
    {"id": "label-needsmerge",       "name": "needs-merge"},
    {"id": "label-boardfailed",      "name": "board-failed"}
  ]
}
JSON
  printf '%s' "$work_dir/happy.json"
}

# =============================================================================
# Case: add creates the instance and resolves its ids
# =============================================================================
home1="$work_dir/home1"
target1="$work_dir/target1"
mkdir -p "$target1"
fixture_board_toml "$target1"
key1="$work_dir/linear1.key"
printf 'test-linear-key-one\n' > "$key1"

start_stub "$(happy_scenario)"
if HOME="$home1" FOREMAN_LINEAR_API_URL="$STUB_URL" \
    "$boardctl" add demo --repo "$target1" --linear-key-file "$key1" \
    >"$work_dir/add1.out" 2>"$work_dir/add1.err"; then
  inst1="$home1/.foreman/instances/demo"
  if [[ -f "$inst1/instance.env" && -f "$inst1/linear.key" && -f "$inst1/ids.env" ]]; then
    if [[ "$(read_id "$inst1/ids.env" LINEAR_TEAM_ID)" == "team-1" ]]; then
      ok "add creates the instance and resolves its ids"
    else
      not_ok "add creates the instance and resolves its ids: ids.env missing LINEAR_TEAM_ID: $(cat "$inst1/ids.env")"
    fi
  else
    not_ok "add creates the instance and resolves its ids: missing files under $inst1: $(ls "$inst1" 2>&1)"
  fi
else
  not_ok "add creates the instance and resolves its ids: add failed: $(cat "$work_dir/add1.err")"
fi
stop_stub

# =============================================================================
# Case: linear.key is mode 0600 and is never echoed
# =============================================================================
if [[ -f "$inst1/linear.key" && "$(file_mode "$inst1/linear.key")" == "600" ]]; then
  ok "linear.key is mode 0600"
else
  not_ok "linear.key is mode 0600: $(file_mode "$inst1/linear.key" 2>&1)"
fi
if grep -q "test-linear-key-one" "$work_dir/add1.out" "$work_dir/add1.err" 2>/dev/null; then
  not_ok "linear.key contents are never echoed: found in add's own output"
else
  ok "linear.key contents are never echoed"
fi

# =============================================================================
# Case: add REFUSES an existing instance rather than overwriting its ids
# =============================================================================
before_ids="$(cat "$inst1/ids.env")"
start_stub "$(happy_scenario)"
status=0
HOME="$home1" FOREMAN_LINEAR_API_URL="$STUB_URL" \
  "$boardctl" add demo --repo "$target1" --linear-key-file "$key1" \
  >"$work_dir/add2.out" 2>"$work_dir/add2.err" || status=$?
stop_stub
if [[ $status -eq 0 ]]; then
  not_ok "add REFUSES an existing instance rather than overwriting its ids: second add succeeded"
elif [[ "$(cat "$inst1/ids.env")" != "$before_ids" ]]; then
  not_ok "add REFUSES an existing instance rather than overwriting its ids: ids.env changed"
elif grep -qi "demo" "$work_dir/add2.err"; then
  ok "add REFUSES an existing instance rather than overwriting its ids"
else
  not_ok "add REFUSES an existing instance rather than overwriting its ids: error did not name the instance: $(cat "$work_dir/add2.err")"
fi

# =============================================================================
# Case: add REFUSES a repo with no board.toml, naming the path
# =============================================================================
home2="$work_dir/home2"
target_no_toml="$work_dir/target-no-toml"
mkdir -p "$target_no_toml"
status=0
HOME="$home2" FOREMAN_LINEAR_API_URL="http://127.0.0.1:1/never-reached" \
  "$boardctl" add nokt --repo "$target_no_toml" --linear-key-file "$key1" \
  >"$work_dir/add3.out" 2>"$work_dir/add3.err" || status=$?
# The message must be boardctl's OWN "no board.toml" refusal, not merely
# some downstream failure that happens to also name the path (resolve-ids.py
# would eventually fail on a missing board.toml too, through config.sh and
# contract.py, and that failure also names the repo -- so a path-substring
# check alone cannot tell "boardctl refused up front" from "boardctl deferred
# to a slower, network-shaped failure"). The bogus FOREMAN_LINEAR_API_URL
# below would make that slower path fail differently (a connection error, no
# "no board.toml" text) if it were ever reached at all.
if [[ $status -ne 0 ]] \
    && [[ "$(cat "$work_dir/add3.err")" == *"no board.toml"* ]] \
    && [[ "$(cat "$work_dir/add3.err")" == *"$target_no_toml"* ]] \
    && [[ ! -e "$home2/.foreman/instances/nokt" ]]; then
  ok "add REFUSES a repo with no board.toml, naming the path"
else
  not_ok "add REFUSES a repo with no board.toml, naming the path: status=$status err=$(cat "$work_dir/add3.err") leftover=$([[ -e "$home2/.foreman/instances/nokt" ]] && echo yes || echo no)"
fi

# =============================================================================
# Case: `add` reaches resolve-ids.py without crashing when NO
# FOREMAN_LINEAR_API_URL is set -- the ordinary case for every real install.
#
# bash 3.2 (this repository's own floor: macOS ships nothing newer) treats
# `"${arr[@]}"` on an EMPTY array as an unset variable under `set -u` and
# dies "unbound variable". That construct sits directly between writing
# instance.env and invoking resolve-ids.py; getting it wrong means every
# unstubbed `add` crashes before ever reaching the network, which no other
# case here would catch since every other case sets FOREMAN_LINEAR_API_URL
# and so always has a non-empty array. Caught once already during
# development, by mutation-testing a different guard away.
#
# A fake resolve-ids.py stands in -- copied installation, one script
# replaced -- so this is checked without the real one or the network, and it
# logs the args it actually received so "does not crash" and "omits
# --api-url when unset" (and includes it when set) are both checked here.
# =============================================================================
fake_install="$work_dir/fake-install"
mkdir -p "$fake_install/bin" "$fake_install/skills/board"
cp "$boardctl" "$fake_install/bin/boardctl"
cp "$repo_root/skills/board/config.sh" "$fake_install/skills/board/config.sh"
cp "$repo_root/bin/contract.py" "$fake_install/bin/contract.py"
cp "$repo_root/bin/tmp-dir.sh" "$fake_install/bin/tmp-dir.sh"
cat > "$fake_install/bin/resolve-ids.py" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys
log = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resolve.log")
with open(log, "w") as f:
    f.write(" ".join(sys.argv[1:]))
sys.exit(0)
PYEOF
chmod +x "$fake_install/bin/resolve-ids.py" "$fake_install/bin/boardctl"
resolve_log="$fake_install/bin/resolve.log"

home6="$work_dir/home6"
target6="$work_dir/target6"
mkdir -p "$target6"
fixture_board_toml "$target6"
key6="$work_dir/linear6.key"
printf 'k\n' > "$key6"

status=0
env -u FOREMAN_LINEAR_API_URL HOME="$home6" "$fake_install/bin/boardctl" \
  add withoutapi --repo "$target6" --linear-key-file "$key6" \
  >"$work_dir/add6.out" 2>"$work_dir/add6.err" || status=$?
if [[ $status -eq 0 ]] && [[ "$(cat "$resolve_log" 2>/dev/null)" != *"--api-url"* ]]; then
  ok "add reaches resolve-ids.py without crashing when FOREMAN_LINEAR_API_URL is unset, and omits --api-url"
else
  not_ok "add reaches resolve-ids.py without crashing when FOREMAN_LINEAR_API_URL is unset: status=$status err=$(cat "$work_dir/add6.err" 2>/dev/null) log=$(cat "$resolve_log" 2>/dev/null)"
fi
rm -rf "$home6"

status=0
env FOREMAN_LINEAR_API_URL="http://127.0.0.1:1/never-reached" HOME="$home6" \
  "$fake_install/bin/boardctl" add withapi --repo "$target6" --linear-key-file "$key6" \
  >"$work_dir/add7.out" 2>"$work_dir/add7.err" || status=$?
if [[ $status -eq 0 ]] && [[ "$(cat "$resolve_log" 2>/dev/null)" == *"--api-url http://127.0.0.1:1/never-reached"* ]]; then
  ok "add forwards --api-url to resolve-ids.py when FOREMAN_LINEAR_API_URL is set"
else
  not_ok "add forwards --api-url to resolve-ids.py when FOREMAN_LINEAR_API_URL is set: status=$status log=$(cat "$resolve_log" 2>/dev/null)"
fi

# =============================================================================
# Case: an instance name with a hyphen is refused at creation (decisions §4) --
# config.sh would refuse it on the instance's very first tick regardless; this
# proves the operator learns immediately, not then.
# =============================================================================
home3="$work_dir/home3"
status=0
HOME="$home3" "$boardctl" add "bad-name" --repo "$target1" --linear-key-file "$key1" \
  >"$work_dir/add4.out" 2>"$work_dir/add4.err" || status=$?
if [[ $status -ne 0 ]] && [[ "$(cat "$work_dir/add4.err")" == *invalid* ]] \
    && [[ ! -e "$home3/.foreman/instances/bad-name" ]]; then
  ok "add REFUSES an instance name containing a hyphen"
else
  not_ok "add REFUSES an instance name containing a hyphen: status=$status err=$(cat "$work_dir/add4.err")"
fi

# =============================================================================
# Case: a resolve-ids failure leaves no half-created instance behind
# =============================================================================
home4="$work_dir/home4"
target4="$work_dir/target4"
mkdir -p "$target4"
fixture_board_toml "$target4"
status=0
# fail_after: 1 means even the first query (Team) gets HTTP 500.
cat >"$work_dir/broken.json" <<JSON
{"teams": [], "fail_after": 1, "log": "$work_dir/broken-requests.log"}
JSON
start_stub "$work_dir/broken.json"
HOME="$home4" FOREMAN_LINEAR_API_URL="$STUB_URL" \
  "$boardctl" add brk --repo "$target4" --linear-key-file "$key1" \
  >"$work_dir/add5.out" 2>"$work_dir/add5.err" || status=$?
stop_stub
if [[ $status -ne 0 ]] && [[ ! -e "$home4/.foreman/instances/brk" ]]; then
  ok "a resolve-ids failure leaves no half-created instance behind"
else
  not_ok "a resolve-ids failure leaves no half-created instance behind: status=$status leftover=$([[ -e "$home4/.foreman/instances/brk" ]] && echo yes || echo no)"
fi

# =============================================================================
# Case: halt creates HALT; resume removes it; status reports which
# =============================================================================
if HOME="$home1" "$boardctl" status demo 2>"$work_dir/status1.err" | grep -qi "running"; then
  ok "status reports running before halt"
else
  not_ok "status reports running before halt: $(cat "$work_dir/status1.err")"
fi

HOME="$home1" "$boardctl" halt demo >"$work_dir/halt.out" 2>"$work_dir/halt.err"
if [[ -f "$inst1/HALT" ]]; then
  ok "halt creates HALT"
else
  not_ok "halt creates HALT: $(cat "$work_dir/halt.err")"
fi

if HOME="$home1" "$boardctl" status demo 2>"$work_dir/status2.err" | grep -qi "halted"; then
  ok "status reports halted after halt"
else
  not_ok "status reports halted after halt: $(cat "$work_dir/status2.err")"
fi

HOME="$home1" "$boardctl" resume demo >"$work_dir/resume.out" 2>"$work_dir/resume.err"
if [[ ! -e "$inst1/HALT" ]]; then
  ok "resume removes HALT"
else
  not_ok "resume removes HALT"
fi

if HOME="$home1" "$boardctl" status demo 2>"$work_dir/status3.err" | grep -qi "running"; then
  ok "status reports running after resume"
else
  not_ok "status reports running after resume: $(cat "$work_dir/status3.err")"
fi

# =============================================================================
# Case: list names every instance and the repo each serves
# =============================================================================
home5="$work_dir/home5"
target5a="$work_dir/target5a"
target5b="$work_dir/target5b"
mkdir -p "$target5a" "$target5b"
fixture_board_toml "$target5a"
fixture_board_toml "$target5b"
fixture_add_instance "$home5" alpha "$target5a"
fixture_add_instance "$home5" beta "$target5b"
listing="$(HOME="$home5" "$boardctl" list)"
if [[ "$listing" == *"alpha"* && "$listing" == *"$target5a"* \
   && "$listing" == *"beta"* && "$listing" == *"$target5b"* ]]; then
  ok "list names every instance and the repo each serves"
else
  not_ok "list names every instance and the repo each serves: $listing"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
