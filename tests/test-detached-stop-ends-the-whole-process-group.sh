#!/bin/bash
# Claim: detached_stop ends every process in the agent's group, including one
# that ignores TERM, even after the wrapper itself has exited.
#
# The failure it prevents: stop waited for the WRAPPER pid only. The wrapper's
# TERM trap exits as soon as the harness does, so the grace loop ended at once
# and KILL was never sent. Measured 2026-09-30: `( trap "" TERM; sleep 41 ) &`
# under a harness survived the stop, running in a worktree the sweep was about
# to delete.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skills/board/harness/detached.sh
source "$root/skills/board/harness/detached.sh"

# A sleep length no other process on the machine uses, so pgrep finds ours.
stubborn="4$$1"
work="$(mktemp -d)"
trap 'pkill -KILL -f "sleep $stubborn" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
cwd="$work/cwd"
mkdir -p "$home" "$cwd"
# One second of grace instead of five: the claim is about who gets KILL, not
# how long the wait is.
_DETACHED_STOP_GRACE_POLLS=4

id="$(detached_spawn foreman/t/T-2/build-1 "$cwd" "$home" "" -- \
  /bin/bash -c "( trap '' TERM; exec /bin/sleep $stubborn ) & exec /bin/sleep 4$$2")"

tries=0
until pgrep -f "sleep $stubborn" >/dev/null || [[ "$tries" -ge 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
pgrep -f "sleep $stubborn" >/dev/null || bad "the TERM-ignoring child never started"

detached_stop "$home" "$id" || bad "detached_stop exited non-zero"

tries=0
while pgrep -f "sleep $stubborn" >/dev/null && [[ "$tries" -lt 30 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
pgrep -f "sleep $stubborn" >/dev/null \
  && bad "a child that ignores TERM survived the stop" \
  || ok "stop KILLs a child that ignores TERM once the grace period is over"

state="$(detached_list "$home" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["state"])')"
[[ "$state" == stopped ]] && ok "the stopped agent lists as stopped" || bad "the stopped agent lists as '$state'"

exit "$fail"
