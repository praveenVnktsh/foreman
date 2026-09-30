#!/bin/bash
# Claim: a detached agent that finished but left processes running in its
# group has them ended by stop, forget and reap, and a stranger that now holds
# the recorded pid is never signalled.
#
# The failure it prevents: once the wrapper had exited, stop only marked the
# record stopped, and forget and reap only deleted files. Measured 2026-09-30:
# a harness that ran `sleep 44 &` and exited left the sleep running after stop
# and forget, with no record left to find it by. On a real board that is a
# process still working in a worktree the sweep then deletes.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skills/board/harness/detached.sh
source "$root/skills/board/harness/detached.sh"

# Sleep lengths no other process on the machine uses, so pgrep finds ours.
tag="5$$"
work="$(mktemp -d)"
trap 'pkill -KILL -f "sleep ${tag}" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
cwd="$work/cwd"
mkdir -p "$home/agents" "$cwd"
_DETACHED_STOP_GRACE_POLLS=4

state_of() { # <id>
  detached_list "$home" | python3 -c '
import json, sys
print(next((r["state"] for r in json.load(sys.stdin) if r["id"] == sys.argv[1]), ""))
' "$1"
}

running() { pgrep -f "sleep $1" >/dev/null; }

gone_soon() { # <sleep length>
  local tries=0
  while running "$1" && [[ "$tries" -lt 30 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
  ! running "$1"
}

# An agent whose harness backgrounds <length> and exits 0. Prints its id once
# it reads done and the leftover is running.
finished_with_leftover() { # <length>
  local id tries=0
  id="$(detached_spawn "foreman/t/T-3/build-$1" "$cwd" "$home" "" -- \
    /bin/bash -c "/bin/sleep $1 >/dev/null 2>&1 & exit 0")" || return 1
  until [[ "$(state_of "$id")" == done ]] && running "$1"; do
    [[ "$tries" -lt 50 ]] || return 1
    sleep 0.1
    tries=$(( tries + 1 ))
  done
  printf '%s\n' "$id"
}

n=0
for verb in stop forget reap; do
  n=$(( n + 1 ))
  length="${tag}${n}"
  if ! id="$(finished_with_leftover "$length")"; then
    bad "$verb: the agent never finished with its leftover running"
    continue
  fi
  case "$verb" in
    stop) detached_stop "$home" "$id" ;;
    forget) detached_forget "$home" "$id" 2>/dev/null ;;
    reap) detached_reap "$home" 0 >/dev/null 2>&1 ;;
  esac
  gone_soon "$length" \
    && ok "$verb on a finished agent ends what its group left running" \
    || bad "$verb on a finished agent left 'sleep $length' running"
done

# A stranger: its own session and group, holding a pid a finished record
# names, with a start time that is not the recorded one.
python3 -c 'import os, sys; os.setsid(); os.execv("/bin/sleep", ["sleep", sys.argv[1]])' "${tag}9" &
stranger=$!
disown "$stranger"
tries=0
until running "${tag}9" || [[ "$tries" -ge 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
printf '{"name":"stale","cwd":"%s","pid":%s,"startedBy":"Thu Jan  1 00:00:00 1970","sessionId":"","startedAt":1,"exit":0,"log":"%s"}\n' \
  "$cwd" "$stranger" "$home/agents/stale.log" >"$home/agents/stale.json"
detached_forget "$home" stale 2>/dev/null || bad "forget of a finished record exited non-zero"
sleep 0.5
running "${tag}9" \
  && ok "forget leaves alone a stranger's group that now holds the recorded pid" \
  || bad "forget killed a stranger's process group"

# A daemon: it forked, set up its own session, forked again and let the
# leader exit, so its group id is a pid no process holds. That is the shape
# of a tmux server or a gpg-agent. A finished record naming that number, from
# an agent that ended long before the daemon started, is not its owner.
daemon_group="$(python3 -c '
import os, sys
read_end, write_end = os.pipe()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        # Off this substitution'"'"'s pipe, or the test waits for the daemon.
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        os.execv("/bin/sleep", ["sleep", sys.argv[1]])
    os.write(write_end, str(os.getpid()).encode())
    os._exit(0)
os.close(write_end)
print(os.read(read_end, 64).decode())
os.wait()
' "${tag}8")"
tries=0
until running "${tag}8" || [[ "$tries" -ge 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
printf '{"name":"old","cwd":"%s","pid":%s,"startedBy":"Thu Jan  1 00:00:00 1970","sessionId":"","startedAt":1000,"exit":0,"endedAt":2000,"log":"%s"}\n' \
  "$cwd" "$daemon_group" "$home/agents/old.log" >"$home/agents/old.json"
detached_forget "$home" old 2>/dev/null || bad "forget of a finished record exited non-zero"
sleep 0.5
running "${tag}8" \
  && ok "forget leaves alone a leaderless group that formed after the agent ended" \
  || bad "forget killed a daemon whose group id matched an old record's pid"

exit "$fail"
