#!/bin/bash
# Claim: a detached agent spawned in one time zone is still `working`, still
# running and still stoppable when it is read from another.
#
# The failure it prevents: detached.sh identifies its process by pid plus the
# `ps -o lstart=` text recorded at spawn, and that text is printed in the
# caller's time zone. The tick, the sweep and an operator's shell do not share
# one. Measured 2026-09-30: an agent spawned under TZ=UTC read `stopped` from a
# shell with TZ unset while it ran, so the card could be dispatched a second
# time beside it, and `stop` left it running.
#
# A record an older foreman wrote holds lstart in its own zone. It must still
# read `working` from that zone, so the fix cannot strand live agents on the
# day it is installed.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skills/board/harness/detached.sh
source "$root/skills/board/harness/detached.sh"

work="$(mktemp -d)"
legacy_pid=""
trap '[[ -n "$legacy_pid" ]] && kill "$legacy_pid" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
cwd="$work/cwd"
mkdir -p "$home" "$cwd"

# POSIX zone strings, so no zoneinfo file has to exist on the machine.
SPAWN_TZ=UTC0
READ_TZ=JST-9

state_of() { # <id>
  detached_list "$home" | python3 -c '
import json, sys
print(next((r["state"] for r in json.load(sys.stdin) if r["id"] == sys.argv[1]), ""))
' "$1"
}

id="$(export TZ="$SPAWN_TZ"; detached_spawn foreman/t/T-1/build-1 "$cwd" "$home" "" -- /bin/sleep 30)"
pid="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$home/agents/$id.json")"

state="$(export TZ="$READ_TZ"; state_of "$id")"
[[ "$state" == working ]] \
  && ok "list from another time zone reads a running agent as working" \
  || bad "list from another time zone read a running agent as '$state'"

if (export TZ="$READ_TZ"; detached_is_running "$home" "$id"); then
  ok "is_running from another time zone says the agent is running"
else
  bad "is_running from another time zone said the agent is not running"
fi

(export TZ="$READ_TZ"; _DETACHED_STOP_GRACE_POLLS=8; detached_stop "$home" "$id")
tries=0
while kill -0 "$pid" 2>/dev/null && [[ "$tries" -lt 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
kill -0 "$pid" 2>/dev/null \
  && bad "stop from another time zone left pid $pid running" \
  || ok "stop from another time zone ends the agent"

# A record in the old form: lstart as this shell prints it, zone and all.
/bin/sleep 30 &
legacy_pid=$!
disown "$legacy_pid"
printf '{"name":"legacy","cwd":"%s","pid":%s,"startedBy":"%s","sessionId":"","startedAt":1,"log":"%s"}\n' \
  "$cwd" "$legacy_pid" "$(ps -o lstart= -p "$legacy_pid")" "$home/agents/legacy.log" >"$home/agents/legacy.json"
state="$(state_of legacy)"
[[ "$state" == working ]] \
  && ok "a record written in the old zone-dependent form still reads working" \
  || bad "a record written in the old form read '$state'"

exit "$fail"
