#!/usr/bin/env bash
# resolve-ids.py is the one moment a name is trusted. Prove it verifies
# everything it resolves, refuses on the two mismatches that matter, refuses
# on ambiguity, and never corrupts ids.env on a partial failure.
#
# Every case here runs against tests/lib/linear-stub.py, a local http.server
# standing in for Linear's GraphQL endpoint. No case reaches api.linear.app --
# a test that needed a real credential to pass would fail in CI and get
# deleted.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
resolve_ids="$repo_root/bin/resolve-ids.py"
stub="$repo_root/tests/lib/linear-stub.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$resolve_ids" ]] || {
  echo "FAIL: $resolve_ids is missing or not executable" >&2
  exit 1
}

work_dir="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" >/dev/null 2>&1 || true
  [[ -n "$STUB_PID" ]] && wait "$STUB_PID" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail=0
fail_hard() {
  echo "FAIL: $1" >&2
  exit 1
}
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# --- fixture instance, shared by every case -----------------------------------
#
# resolve-ids.py shells out to config.sh, which since Task 3 requires a
# FOREMAN_INSTANCE and an instance directory declaring a REPO whose board.toml
# passes bin/contract.py. One instance, reused for every case: the two REFUSE
# cases and the ambiguity case never touch ids.env, and the atomic-write case
# depends on this being the *same* instance across two runs.
home="$work_dir/home"
target="$work_dir/target"
mkdir -p "$target"
fixture_board_toml "$target"   # [linear] team = "PRA", project = "fixture"
fixture_add_instance "$home" fixture "$target"
inst_home="$home/.foreman/instances/fixture"
printf 'test-linear-key\n' > "$inst_home/linear.key"
chmod 600 "$inst_home/linear.key"

run_resolve() {
  # run_resolve <api-url>  -- exit code and stdout/stderr land in $work_dir/out.*
  HOME="$home" FOREMAN_INSTANCE=fixture \
    "$resolve_ids" --instance fixture --api-url "$1" \
    >"$work_dir/out.log" 2>"$work_dir/err.log"
}

start_stub() {
  # start_stub <scenario.json>  -- sets STUB_URL, blocks until the port is up
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

read_id() { # <file> <KEY>
  local line
  line="$(grep "^$2=" "$1" || true)"
  printf '%s' "${line#*=}"
}

file_mode() { # <file> -- prints an octal string like "600"
  python3 -c '
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
' "$1"
}

# =============================================================================
# Case A: the happy path -- team, project, five states, and both label paths
# (reuse an existing one, create a missing one) all in one resolved ids.env.
# =============================================================================

happy_log="$work_dir/happy-requests.log"
cat >"$work_dir/happy.json" <<JSON
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
    {"id": "label-needsmerge",       "name": "needs-merge"}
  ],
  "log": "$happy_log"
}
JSON
# board-failed is deliberately absent above -- ensure_labels() must create it.

start_stub "$work_dir/happy.json"
if run_resolve "$STUB_URL"; then
  ids_env="$inst_home/ids.env"
  [[ -f "$ids_env" ]] || fail_hard "resolve-ids succeeded but wrote no ids.env"

  if [[ "$(read_id "$ids_env" LINEAR_TEAM_ID)" == "team-1" && \
        "$(read_id "$ids_env" LINEAR_PROJECT_ID)" == "proj-1" ]]; then
    ok "resolves team and project by name into ids.env"
  else
    not_ok "resolves team and project by name into ids.env: $(cat "$ids_env")"
  fi

  if [[ "$(read_id "$ids_env" STATE_PLANNED)" == "state-backlog" && \
        "$(read_id "$ids_env" STATE_TO_PICK_UP)" == "state-todo" && \
        "$(read_id "$ids_env" STATE_IN_PROGRESS)" == "state-inprogress" && \
        "$(read_id "$ids_env" STATE_IN_REVIEW)" == "state-inreview" && \
        "$(read_id "$ids_env" STATE_MERGED)" == "state-done" ]]; then
    ok "resolves the five states by name"
  else
    not_ok "resolves the five states by name: $(cat "$ids_env")"
  fi

  created_id="$(read_id "$ids_env" LABEL_BOARD_FAILED)"
  create_calls="$(grep -c '^mutation CreateLabel ' "$happy_log" || true)"
  if [[ "$created_id" == created-* ]] \
       && grep -q "^mutation CreateLabel .*\"board-failed\"" "$happy_log" \
       && [[ "$create_calls" -eq 1 ]]; then
    ok "creates a label that does not exist and records its id"
  else
    not_ok "creates a label that does not exist: id=[$created_id] creates=[$create_calls] log=$(cat "$happy_log")"
  fi

  if [[ "$(read_id "$ids_env" LABEL_FOLLOW_UP)" == "label-followup" && \
        "$(read_id "$ids_env" LABEL_FOLLOW_UPS_WRITTEN)" == "label-followupswritten" && \
        "$(read_id "$ids_env" LABEL_NEEDS_MERGE)" == "label-needsmerge" && \
        "$create_calls" -eq 1 ]]; then
    ok "reuses a label that does exist rather than creating a second"
  else
    not_ok "reuses a label that does exist: $(cat "$ids_env")"
  fi

  mode="$(file_mode "$ids_env")"
  if [[ "$mode" == "600" ]]; then
    ok "ids.env is mode 0600"
  else
    not_ok "ids.env is mode 0600: got $mode"
  fi

  baseline_content="$(cat "$ids_env")"
else
  fail_hard "the happy-path run itself failed: $(cat "$work_dir/err.log")"
fi
stop_stub

# =============================================================================
# Case: REFUSES when the to-pick-up state is not of type `unstarted`
# =============================================================================

cat >"$work_dir/bad_state_type.json" <<JSON
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",        "type": "started"},
    {"id": "state-inprogress", "name": "In Progress", "type": "started"},
    {"id": "state-inreview",   "name": "In Review",   "type": "started"},
    {"id": "state-done",       "name": "Done",        "type": "completed"}
  ],
  "labels": []
}
JSON
start_stub "$work_dir/bad_state_type.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when the to-pick-up state is not of type \`unstarted\`: exited 0"
else
  if grep -q 'unstarted' "$work_dir/err.log"; then
    ok "REFUSES when the to-pick-up state is not of type \`unstarted\`"
  else
    not_ok "REFUSES when the to-pick-up state is not of type \`unstarted\`: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

# =============================================================================
# Case: REFUSES when a resolved label id belongs to a differently-named label
# =============================================================================

cat >"$work_dir/label_mismatch.json" <<JSON
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
    {"id": "label-followup", "name": "follow-up"}
  ],
  "label_id_lies": {"label-followup": "not-follow-up"}
}
JSON
start_stub "$work_dir/label_mismatch.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when a resolved label id belongs to a differently-named label: exited 0"
else
  if grep -q 'follow-up' "$work_dir/err.log" && grep -q 'not-follow-up' "$work_dir/err.log"; then
    ok "REFUSES when a resolved label id belongs to a differently-named label"
  else
    not_ok "REFUSES when a resolved label id belongs to a differently-named label: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

# =============================================================================
# Case: REFUSES when two projects in the team share the requested name
# =============================================================================

cat >"$work_dir/ambiguous_project.json" <<JSON
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [
    {"id": "proj-1", "name": "fixture", "teamId": "team-1"},
    {"id": "proj-2", "name": "fixture", "teamId": "team-1"}
  ]
}
JSON
start_stub "$work_dir/ambiguous_project.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when two projects in the team share the requested name: exited 0"
else
  if grep -q 'proj-1' "$work_dir/err.log" && grep -q 'proj-2' "$work_dir/err.log"; then
    ok "REFUSES when two projects in the team share the requested name"
  else
    not_ok "REFUSES when two projects in the team share the requested name: did not name both ids: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

# =============================================================================
# Case: writes ids.env atomically -- a run that fails partway leaves the
# previous ids.env byte-identical. Reuses the SAME instance as case A, so
# "the previous file" is the ids.env the happy path already wrote.
# =============================================================================

cat >"$work_dir/fails_third_query.json" <<JSON
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
  ],
  "fail_after": 2
}
JSON
# team (1st) and project (2nd) succeed; the states query (3rd) gets a 500.
start_stub "$work_dir/fails_third_query.json"
if run_resolve "$STUB_URL"; then
  not_ok "writes ids.env atomically: the partial-failure run unexpectedly succeeded"
else
  after_content="$(cat "$inst_home/ids.env")"
  if [[ "$after_content" == "$baseline_content" ]] && grep -qi '500\|induced failure' "$work_dir/err.log"; then
    ok "writes ids.env atomically (a failed run leaves the previous file intact)"
  else
    not_ok "writes ids.env atomically: file changed or wrong error. before=[$baseline_content] after=[$after_content] err=$(cat "$work_dir/err.log")"
  fi
fi
stop_stub

exit "$fail"
