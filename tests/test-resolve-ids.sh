#!/usr/bin/env bash
# resolve-ids.py is the one moment a name is trusted. Prove it verifies
# everything it resolves, refuses on the two mismatches that matter, refuses
# on ambiguity, and never corrupts ids.env on a partial failure.
#
# Also prove where the credential comes from and what ids.env is. The key is
# per Linear WORKSPACE ($FOREMAN_HOME/linear.key, or --key-file for a board in
# another workspace), not per board -- ten boards used to mean ten copies of
# one secret to rotate. ids.env is a CACHE: deleting it must cost one
# re-resolve, never a broken board.
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

# The workspace credential, one copy for every board in this FOREMAN_HOME.
# FOREMAN_HOME is a temporary directory here; the real ~/.foreman is never
# read or written by this test.
foreman_home="$home/.foreman"
workspace_key="$foreman_home/linear.key"
printf 'test-linear-key\n' > "$workspace_key"
chmod 600 "$workspace_key"

run_resolve() {
  # run_resolve <api-url> [extra args...]  -- output lands in $work_dir/out.*
  local api_url="$1"; shift
  HOME="$home" FOREMAN_HOME="$foreman_home" FOREMAN_INSTANCE=fixture \
    "$resolve_ids" --instance fixture --api-url "$api_url" "$@" \
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
# Case A: the happy path -- team, project, the states, the column the board
# creates for itself, and both label paths (reuse an existing one, create a
# missing one) all in one resolved ids.env.
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
    ok "resolves the operator's own states by name"
  else
    not_ok "resolves the operator's own states by name: $(cat "$ids_env")"
  fi

  # `Needs Answers` is deliberately absent from the fixture above. No Linear
  # team ships a column the board invented, so a board that refused over its
  # absence could never resolve its ids on a fresh fork at all -- and a card
  # labelled human-cobuild would have nowhere to wait for its operator.
  parked_id="$(read_id "$ids_env" STATE_NEEDS_ANSWERS)"
  state_creates="$(grep -c '^mutation CreateState ' "$happy_log" || true)"
  if [[ "$parked_id" == created-state-* && "$state_creates" -eq 1 ]] \
       && grep -q '^mutation CreateState .*"name": "Needs Answers"' "$happy_log" \
       && grep -q '^mutation CreateState .*"type": "started"' "$happy_log"; then
    ok "creates the Needs Answers column when the team does not have one"
  else
    not_ok "creates the Needs Answers column: id=[$parked_id] creates=[$state_creates] log=$(cat "$happy_log")"
  fi

  # The operator sets human-cobuild and the board only ever reads it -- but a
  # label nobody can put on a card is not a feature, so it is created like the
  # four the board writes itself.
  cobuild_id="$(read_id "$ids_env" LABEL_HUMAN_COBUILD)"
  if [[ "$cobuild_id" == created-* ]] \
       && grep -q '^mutation CreateLabel .*"human-cobuild"' "$happy_log"; then
    ok "creates the human-cobuild label so an operator has one to apply"
  else
    not_ok "creates the human-cobuild label: id=[$cobuild_id] log=$(cat "$happy_log")"
  fi

  created_id="$(read_id "$ids_env" LABEL_BOARD_FAILED)"
  # Two labels are missing from the fixture below on purpose: board-failed and
  # human-cobuild. Three of the five are present, so this count is also what
  # proves the present ones were reused rather than created a second time.
  create_calls="$(grep -c '^mutation CreateLabel ' "$happy_log" || true)"
  if [[ "$created_id" == created-* ]] \
       && grep -q "^mutation CreateLabel .*\"board-failed\"" "$happy_log" \
       && [[ "$create_calls" -eq 2 ]]; then
    ok "creates a label that does not exist and records its id"
  else
    not_ok "creates a label that does not exist: id=[$created_id] creates=[$create_calls] log=$(cat "$happy_log")"
  fi

  if [[ "$(read_id "$ids_env" LABEL_FOLLOW_UP)" == "label-followup" && \
        "$(read_id "$ids_env" LABEL_FOLLOW_UPS_WRITTEN)" == "label-followupswritten" && \
        "$(read_id "$ids_env" LABEL_NEEDS_MERGE)" == "label-needsmerge" && \
        "$create_calls" -eq 2 ]]; then
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

# =============================================================================
# Case: ids.env is a cache -- deleting it costs one re-resolve, not a board
#
# Every id in it is derived from the target's own board.toml plus Linear, so
# absence must be recoverable rather than fatal. Same stub, still running, so
# the rebuilt file must come back byte-identical to the one just deleted.
# =============================================================================

rm -f "$inst_home/ids.env"
if run_resolve "$STUB_URL"; then
  rebuilt="$(cat "$inst_home/ids.env" 2>/dev/null || true)"
  if [[ "$rebuilt" == "$baseline_content" ]]; then
    ok "a missing ids.env is re-resolved, not fatal"
  else
    not_ok "a missing ids.env is re-resolved, not fatal: rebuilt=[$rebuilt] expected=[$baseline_content]"
  fi
else
  not_ok "a missing ids.env is re-resolved, not fatal: the run refused: $(cat "$work_dir/err.log")"
fi

# =============================================================================
# Case: REFUSES when the workspace key file is missing, naming its path
#
# A stale per-board copy is left at the old $INSTANCE_HOME/linear.key on
# purpose. Reading that one back would make a rotated workspace key look
# applied while one board kept authenticating with the revoked secret --
# exactly the failure moving the key to one place per workspace removes.
# =============================================================================

mv "$workspace_key" "$work_dir/workspace.key.hidden"
printf 'stale-per-board-key\n' > "$inst_home/linear.key"
chmod 600 "$inst_home/linear.key"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when the workspace key file is missing: exited 0, and a stale per-board key is still readable at $inst_home/linear.key"
else
  if grep -q "$workspace_key" "$work_dir/err.log"; then
    ok "REFUSES when the workspace key file is missing, naming its path"
  else
    not_ok "REFUSES when the workspace key file is missing: did not name $workspace_key: $(cat "$work_dir/err.log")"
  fi
fi

# =============================================================================
# Case: --key-file is read instead of the workspace default
#
# This is how a board in a DIFFERENT Linear workspace gets its own credential.
# The workspace default is still moved away, so a run that succeeds can only
# have read the path that was passed.
# =============================================================================

other_key="$work_dir/other-workspace.key"
printf 'other-workspace-key\n' > "$other_key"
chmod 600 "$other_key"
if run_resolve "$STUB_URL" --key-file "$other_key"; then
  ok "--key-file is read instead of the workspace default"
else
  not_ok "--key-file is read instead of the workspace default: $(cat "$work_dir/err.log")"
fi

# =============================================================================
# Case: REFUSES when --key-file names a missing file, rather than falling back
#
# The workspace default is restored first, so falling back would succeed and
# resolve against the wrong workspace's credential without saying so.
# =============================================================================

mv "$work_dir/workspace.key.hidden" "$workspace_key"
rm -f "$inst_home/linear.key"
missing_key="$work_dir/no-such.key"
if run_resolve "$STUB_URL" --key-file "$missing_key"; then
  not_ok "REFUSES when --key-file names a missing file: exited 0, so it fell back to $workspace_key"
else
  if grep -q "$missing_key" "$work_dir/err.log"; then
    ok "REFUSES when --key-file names a missing file, rather than falling back"
  else
    not_ok "REFUSES when --key-file names a missing file: did not name $missing_key: $(cat "$work_dir/err.log")"
  fi
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

# =============================================================================
# Case: an ambient REPO left over from a DIFFERENT instance must not leak into
# this one's ids.env
#
# config.sh exports REPO (and reads instance.env with `-`, not `:-`, so an
# already-set value always wins -- deliberate, for an operator's explicit
# per-call override). A shell that has sourced config.sh once for instance
# "fixture" carries fixture's REPO in its environment from then on. Simulated
# here exactly that way: REPO is set in resolve-ids.py's own environment
# before it is asked to resolve a SECOND, unrelated instance ("leaky"), the
# same shape as `boardctl add leaky ...` typed right after debugging
# "fixture" in one terminal. Without the fix, resolve-ids.py's subprocess
# inherits that REPO and resolves leaky's ids.env against fixture's team and
# project instead of leaky's own.
# =============================================================================

leaky_target="$work_dir/leaky-target"
mkdir -p "$leaky_target"
cat >"$leaky_target/board.toml" <<'TOML'
[linear]
team = "OTHR"
project = "other-project"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
TOML
fixture_add_instance "$home" leaky "$leaky_target"
leaky_home="$home/.foreman/instances/leaky"
# No key of its own: both boards share the one workspace credential.

cat >"$work_dir/leak_check.json" <<'JSON'
{
  "teams": [
    {"id": "team-fixture", "name": "PRA"},
    {"id": "team-leaky",   "name": "OTHR"}
  ],
  "projects": [
    {"id": "proj-fixture", "name": "fixture",       "teamId": "team-fixture"},
    {"id": "proj-leaky",   "name": "other-project",  "teamId": "team-leaky"}
  ],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",        "type": "unstarted"},
    {"id": "state-inprogress", "name": "In Progress", "type": "started"},
    {"id": "state-inreview",   "name": "In Review",   "type": "started"},
    {"id": "state-done",       "name": "Done",        "type": "completed"}
  ],
  "labels": []
}
JSON
start_stub "$work_dir/leak_check.json"
# REPO is set in the ENVIRONMENT, ambient, the way an export from a previous
# `config.sh` load would be -- not passed by resolve-ids.py's own logic.
if HOME="$home" FOREMAN_HOME="$foreman_home" FOREMAN_INSTANCE=leaky REPO="$target" \
    "$resolve_ids" --instance leaky --api-url "$STUB_URL" \
    >"$work_dir/leak.out.log" 2>"$work_dir/leak.err.log"; then
  leaky_ids="$leaky_home/ids.env"
  team_id="$(read_id "$leaky_ids" LINEAR_TEAM_ID)"
  project_id="$(read_id "$leaky_ids" LINEAR_PROJECT_ID)"
  if [[ "$team_id" == "team-leaky" && "$project_id" == "proj-leaky" ]]; then
    ok "an ambient REPO from a different instance does not leak into this instance's ids.env"
  else
    not_ok "an ambient REPO from a different instance does not leak into this instance's ids.env" \
      "resolved team=[$team_id] project=[$project_id], expected leaky's own (team-leaky/proj-leaky) -- got fixture's instead"
  fi
else
  not_ok "an ambient REPO from a different instance does not leak into this instance's ids.env" \
    "resolve-ids failed outright: $(cat "$work_dir/leak.err.log")"
fi
stop_stub

# --- a newly declared board has no runtime directory yet -------------------
#
# `boardctl add` no longer builds one: a board is two lines in boards.toml. The
# first resolve therefore has to create it, and used to die with
# FileNotFoundError on ids.env.tmp instead.
start_stub "$work_dir/happy.json"
rm -rf "$foreman_home/instances/fixture"
if run_resolve "$STUB_URL" && [[ -f "$foreman_home/instances/fixture/ids.env" ]]; then
  ok "a board with no runtime directory yet resolves, creating it"
else
  not_ok "a board with no runtime directory yet failed to resolve: $(tail -2 "$work_dir/err.log")"
fi
stop_stub


# =============================================================================
# The Needs Answers column: created when the team lacks it (case A above),
# reused when it has one, and refused when what is there would hide a parked
# card from the operator it is waiting for.
# =============================================================================

reuse_log="$work_dir/reuse-requests.log"
cat >"$work_dir/has_needs_answers.json" <<JSON
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",      "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",         "type": "unstarted"},
    {"id": "state-inprogress", "name": "In Progress",  "type": "started"},
    {"id": "state-needs",      "name": "Needs Answers","type": "started"},
    {"id": "state-inreview",   "name": "In Review",    "type": "started"},
    {"id": "state-done",       "name": "Done",         "type": "completed"}
  ],
  "labels": [],
  "log": "$reuse_log"
}
JSON
start_stub "$work_dir/has_needs_answers.json"
if run_resolve "$STUB_URL"; then
  reused="$(read_id "$inst_home/ids.env" STATE_NEEDS_ANSWERS)"
  if [[ "$reused" == "state-needs" ]] && ! grep -q '^mutation CreateState ' "$reuse_log"; then
    ok "reuses a Needs Answers column the team already has, creating no second one"
  else
    not_ok "reuses a Needs Answers column the team already has: id=[$reused] log=$(cat "$reuse_log")"
  fi
else
  not_ok "reuses a Needs Answers column the team already has: the run refused: $(cat "$work_dir/err.log")"
fi
stop_stub

# A `completed` column named Needs Answers marks every parked card as finished
# in Linear. The operator sees a done ticket, never answers the question, and
# the card waits forever for a person who was never told.
cat >"$work_dir/needs_answers_completed.json" <<'JSON'
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",      "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",         "type": "unstarted"},
    {"id": "state-inprogress", "name": "In Progress",  "type": "started"},
    {"id": "state-needs",      "name": "Needs Answers","type": "completed"},
    {"id": "state-inreview",   "name": "In Review",    "type": "started"},
    {"id": "state-done",       "name": "Done",         "type": "completed"}
  ],
  "labels": []
}
JSON
start_stub "$work_dir/needs_answers_completed.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES a Needs Answers column that marks the card completed: exited 0"
else
  if grep -q "Needs Answers" "$work_dir/err.log" && grep -q "started" "$work_dir/err.log"; then
    ok "REFUSES a Needs Answers column that marks the card completed"
  else
    not_ok "REFUSES a Needs Answers column that marks the card completed: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

# The create round-trip is checked the same way a label's is: an id that was
# never seen beside the name it was asked for is an id the board would park
# every question in, in a column nobody is watching.
cat >"$work_dir/state_create_lies.json" <<'JSON'
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
  "labels": [],
  "state_create_lies": {"Needs Answers": "Somewhere Else"}
}
JSON
start_stub "$work_dir/state_create_lies.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when the created column comes back under another name: exited 0"
else
  if grep -q "Somewhere Else" "$work_dir/err.log"; then
    ok "REFUSES when the created column comes back under another name"
  else
    not_ok "REFUSES when the created column comes back under another name: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

exit "$fail"
