#!/usr/bin/env bash
# Claim: bin/resolve-ids.py reads every page of the team's labels, so a label
# that sits past the first page is found and reused, never created again.
#
# The failure it prevents: Linear pages labels, and a team with more labels
# than one page looked like it lacked `needs-plan`. resolve-ids.py then created
# a second one, and every later run refused the two as ambiguous.
#
# tests/lib/linear-stub.py stands in for Linear. `labels_page_size` makes it
# page at two, so page two is reached without declaring 251 labels.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
resolve_ids="$repo_root/bin/resolve-ids.py"
stub="$repo_root/tests/lib/linear-stub.py"
# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" >/dev/null 2>&1 || true
  [[ -n "$STUB_PID" ]] && wait "$STUB_PID" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
target="$work/target"
mkdir -p "$target"
fixture_board_toml "$target"
fixture_add_instance "$home" fixture "$target"
foreman_home="$home/.foreman"
printf 'test-linear-key\n' >"$foreman_home/linear.key"
chmod 600 "$foreman_home/linear.key"
ids_env="$foreman_home/instances/fixture/ids.env"

# Every label the board wants already exists, and all of them sit past the
# first page of two. A reader that stops at page one creates all six again.
log="$work/requests.log"
cat >"$work/scenario.json" <<JSON
{
  "teams": [{"id": "team-1", "name": "PRA"}],
  "projects": [{"id": "proj-1", "name": "fixture", "teamId": "team-1"}],
  "states": [
    {"id": "state-backlog",    "name": "Backlog",     "type": "backlog"},
    {"id": "state-todo",       "name": "Todo",        "type": "unstarted"},
    {"id": "state-plan",       "name": "Plan",        "type": "started"},
    {"id": "state-inprogress", "name": "In Progress", "type": "started"},
    {"id": "state-inreview",   "name": "In Review",   "type": "started"},
    {"id": "state-done",       "name": "Done",        "type": "completed"},
    {"id": "state-needshuman", "name": "Needs Human", "type": "started"}
  ],
  "labels": [
    {"id": "label-bug",              "name": "bug"},
    {"id": "label-feature",          "name": "feature"},
    {"id": "label-needsplan",        "name": "needs-plan"},
    {"id": "label-followup",         "name": "follow-up"},
    {"id": "label-followupswritten", "name": "follow-ups-written"},
    {"id": "label-needsmerge",       "name": "needs-merge"},
    {"id": "label-boardfailed",      "name": "board-failed"},
    {"id": "label-cleanup",          "name": "cleanup"}
  ],
  "labels_page_size": 2,
  "log": "$log"
}
JSON

port_file="$work/stub.port"
python3 "$stub" "$work/scenario.json" >"$port_file" 2>"$work/stub.err" &
STUB_PID=$!
tries=0
until [[ -s "$port_file" ]]; do
  tries=$((tries + 1))
  [[ $tries -le 100 ]] || { echo "FAIL stub never printed a port: $(cat "$work/stub.err")" >&2; exit 1; }
  kill -0 "$STUB_PID" 2>/dev/null || { echo "FAIL stub exited: $(cat "$work/stub.err")" >&2; exit 1; }
  sleep 0.05
done
url="http://127.0.0.1:$(cat "$port_file")/graphql"

if ! HOME="$home" FOREMAN_HOME="$foreman_home" FOREMAN_INSTANCE=fixture \
     "$resolve_ids" --instance fixture --installation claude --api-url "$url" \
     >"$work/out.log" 2>"$work/err.log"; then
  echo "FAIL resolve-ids refused: $(cat "$work/err.log")" >&2
  exit 1
fi

read_id() { local line; line="$(grep "^$1=" "$ids_env" || true)"; printf '%s' "${line#*=}"; }

pages="$(grep -c '^query Labels ' "$log" || true)"
[[ "$pages" -eq 4 ]] \
  && ok "reads all four pages of labels, following the cursor" \
  || bad "read $pages page(s) of labels, expected 4: $(grep '^query Labels ' "$log")"

grep -q '^mutation CreateLabel ' "$log" \
  && bad "created a label that exists on a later page: $(grep '^mutation CreateLabel ' "$log")" \
  || ok "creates no label that exists on a later page"

[[ "$(read_id LABEL_NEEDS_PLAN)" == "label-needsplan" \
   && "$(read_id LABEL_CLEANUP)" == "label-cleanup" \
   && "$(read_id LABEL_BOARD_FAILED)" == "label-boardfailed" ]] \
  && ok "records the existing ids of labels found past page one" \
  || bad "wrong label ids: $(cat "$ids_env")"

exit "$fail"
