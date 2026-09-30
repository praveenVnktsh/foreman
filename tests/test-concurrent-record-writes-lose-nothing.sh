#!/bin/bash
# Claim: two writers updating one detached agent record at the same moment
# both land.
#
# The failure it prevents: a record write reads the record, merges its keys
# and replaces the file, and the wrapper (exit), the adapter (sessionId) and
# detached_stop (exit, stoppedAt) all do it. With no lock the second replace
# drops the first writer's key. Measured 2026-09-30: an `exit` and a
# `sessionId` written together lost one of them in 27 of 40 rounds. A lost
# `exit` lists a finished agent as working behind a dead pid; a lost
# `stoppedAt` lists a stopped agent as done.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skills/board/harness/detached.sh
source "$root/skills/board/harness/detached.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ROUNDS=40
record="$work/agent.json"
lost=0
for _ in $(seq 1 "$ROUNDS"); do
  printf '{"pid": 1, "startedAt": 1}\n' >"$record"
  _detached_record_set "$record" exit 0 &
  _detached_record_set "$record" sessionId ses_x &
  _detached_record_default "$record" stoppedAt 7 &
  wait
  python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r.get("exit") == 0 and r.get("sessionId") == "ses_x" and r.get("stoppedAt") == 7 else 1)
' "$record" || lost=$(( lost + 1 ))
done

if [[ "$lost" -eq 0 ]]; then
  printf 'ok   three concurrent record writes all land, %s rounds of %s\n' "$ROUNDS" "$ROUNDS"
  exit 0
fi
printf 'FAIL concurrent record writes lost an update in %s of %s rounds\n' "$lost" "$ROUNDS" >&2
exit 1
