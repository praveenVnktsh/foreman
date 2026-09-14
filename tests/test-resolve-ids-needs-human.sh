#!/usr/bin/env bash
# STATE_NEEDS_HUMAN is the new workflow state resolve-ids.py resolves: the
# single destination every board-failed exit now moves a card to, instead of
# Backlog. Two things have to be true about it, and this test proves both:
#
#   - it resolves like any other state, once the team's board has the column
#   - a team missing it hits the same one-message-names-them-all refusal
#     every other missing column hits, naming "Needs Human" specifically
#
# This is deliberately a SEPARATE file from test-resolve-ids.sh, which already
# owns the general resolve/verify/refuse contract for this script and is not
# mine to edit here. Same stubbing pattern (tests/lib/linear-stub.py, a real
# http.server standing in for Linear), same fixture instance helper.
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

home="$work_dir/home"
target="$work_dir/target"
mkdir -p "$target"
fixture_board_toml "$target"   # [linear] team = "PRA", project = "fixture"
fixture_add_instance "$home" fixture "$target"
inst_home="$home/.foreman/instances/fixture"

foreman_home="$home/.foreman"
workspace_key="$foreman_home/linear.key"
printf 'test-linear-key\n' > "$workspace_key"
chmod 600 "$workspace_key"

run_resolve() {
  # run_resolve <api-url>  -- output lands in $work_dir/out.*
  local api_url="$1"
  # --installation is required and is this installation's own name. The fixture
  # home declares no installation.toml, so bin/installation.py reads it as the
  # lone Claude installation and the name is `claude`.
  HOME="$home" FOREMAN_HOME="$foreman_home" FOREMAN_INSTANCE=fixture \
    "$resolve_ids" --instance fixture --installation claude --api-url "$api_url" \
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

# =============================================================================
# Case: a board carrying the new "Needs Human" column resolves it, alongside
# the other six, into ids.env as STATE_NEEDS_HUMAN.
# =============================================================================

cat >"$work_dir/with_needs_human.json" <<'JSON'
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",     "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",        "name": "Todo",        "type": "unstarted"},
    {"id": "state-plan",        "name": "Plan",        "type": "started"},
    {"id": "state-inprogress",  "name": "In Progress", "type": "started"},
    {"id": "state-inreview",    "name": "In Review",   "type": "started"},
    {"id": "state-done",        "name": "Done",        "type": "completed"},
    {"id": "state-needshuman",  "name": "Needs Human",  "type": "backlog"}
  ],
  "labels": [
    {"id": "label-followup",         "name": "follow-up"},
    {"id": "label-followupswritten", "name": "follow-ups-written"},
    {"id": "label-needsmerge",       "name": "needs-merge"},
    {"id": "label-boardfailed",      "name": "board-failed"},
    {"id": "label-needsplan",        "name": "needs-plan"}
  ]
}
JSON

start_stub "$work_dir/with_needs_human.json"
if run_resolve "$STUB_URL"; then
  ids_env="$inst_home/ids.env"
  [[ -f "$ids_env" ]] || fail_hard "resolve-ids succeeded but wrote no ids.env"
  if [[ "$(read_id "$ids_env" STATE_NEEDS_HUMAN)" == "state-needshuman" ]]; then
    ok "resolves the Needs Human column into ids.env as STATE_NEEDS_HUMAN"
  else
    not_ok "resolves the Needs Human column into ids.env as STATE_NEEDS_HUMAN: $(cat "$ids_env")"
  fi
else
  fail_hard "the happy-path run itself failed: $(cat "$work_dir/err.log")"
fi
stop_stub

# =============================================================================
# Case: REFUSES when the team has no `Needs Human` column, and names it -- the
# same one-message-names-them-all path the missing-Plan case already covers,
# now proven for the new role too. Every board that existed before this change
# lacks the column, so every one of them hits this on its next resolve.
# =============================================================================

cat >"$work_dir/no_needs_human.json" <<'JSON'
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",        "type": "unstarted"},
    {"id": "state-plan",       "name": "Plan",        "type": "started"},
    {"id": "state-inprogress", "name": "In Progress", "type": "started"},
    {"id": "state-inreview",   "name": "In Review",   "type": "started"},
    {"id": "state-done",       "name": "Done",        "type": "completed"}
  ],
  "labels": []
}
JSON

start_stub "$work_dir/no_needs_human.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES when the team has no \`Needs Human\` column: exited 0"
else
  if grep -q "'Needs Human'" "$work_dir/err.log" && grep -q 'Linear' "$work_dir/err.log"; then
    ok "REFUSES when the team has no \`Needs Human\` column, naming it, and says to create it in Linear"
  else
    not_ok "REFUSES when the team has no \`Needs Human\` column: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

# =============================================================================
# Case: missing BOTH Plan and Needs Human names both in the one message,
# proving the new role shares the same "name everything missing at once" path
# rather than stopping at the first absence found.
# =============================================================================

cat >"$work_dir/missing_two.json" <<'JSON'
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
  "labels": []
}
JSON

start_stub "$work_dir/missing_two.json"
if run_resolve "$STUB_URL"; then
  not_ok "REFUSES naming both Plan and Needs Human in one message: exited 0"
else
  if grep -q "'Plan'" "$work_dir/err.log" && grep -q "'Needs Human'" "$work_dir/err.log"; then
    ok "REFUSES naming both Plan and Needs Human in one message, before resolving either"
  else
    not_ok "REFUSES naming both Plan and Needs Human in one message: wrong message: $(cat "$work_dir/err.log")"
  fi
fi
stop_stub

exit "$fail"
