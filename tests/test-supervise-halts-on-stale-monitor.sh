#!/usr/bin/env bash
# Claim: supervise.sh stops the tick and starts NOTHING when a declared board's
# agent Monitor is not alive, and leaves the tick alone when it is.
#
# The failure it prevents: the board loop is edge-triggered by an agent Monitor.
# When the harness stops accepting the Monitor call, every board falls back to
# heartbeat speed and says nothing, so the machine looks healthy while cards sit.
# Restarting the tick arms nothing again and the next fire does it again, which
# turns a slow machine into a thrashing one -- so this branch halts instead.
#
# It drives the real supervise.sh, and the real reconcile.py under it. Only the
# harness (a stub `claude` on PATH) and GitHub (a stub `gh` on PATH) are
# stubbed; the target's origin is a local bare repository.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"
stub="$repo_root/tests/lib/linear-stub.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" >/dev/null 2>&1
  [[ -n "$STUB_PID" ]] && wait "$STUB_PID" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# config.sh lets the environment win over boards.toml, board.toml and ids.env.
# A test run from inside a board slice inherits that slice's REPO, KEY_FILE and
# ids, and they would answer for the fixture board. Remove every name the
# fixture means to supply. MONITOR_STALE_SECONDS and MONITOR_GRACE_SECONDS are
# in the list because this test sets them per run and the environment wins.
unset REPO KEY_FILE BOARD_HOME INSTANCE INSTANCE_HOME BOARD_NAME_PREFIX \
  BOARD_WORKTREE_PREFIX FOREMAN_ROOT MAX_CONCURRENT HOST_MAX_CONCURRENT \
  HOST_SLOT_STALE_MINUTES TICK_STARVED_MINUTES TICK_INTERVAL_MINUTES \
  TICK_MAX_AGE_HOURS STARVED_API_URL MONITOR_STALE_SECONDS MONITOR_GRACE_SECONDS
for name in $(compgen -e); do
  case "$name" in STATE_*|LABEL_*|LINEAR_*) unset "$name" ;; esac
done

target="$work/target"
mkdir -p "$target"
git init -q --bare "$work/origin"
git -C "$target" init -q -b main
fixture_board_toml "$target"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$target" remote add origin "$work/origin"
git -C "$target" push -q origin main
home="$work/home"
fh="$home/.foreman"
fixture_add_board "$home" demo "$target"
printf 'LINEAR_PROJECT_ID=project-1\nSTATE_TO_PICK_UP=state-todo\n' >"$fh/instances/demo/ids.env"

registry="$work/registry.json"
stopped="$work/stopped.log"
started="$work/started.log"
install="$home/install"
mkdir -p "$install"
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
transcripts="$home/.claude/projects/$(slug "$install")"
mkdir -p "$transcripts"
export INSTALL="$install"

# tick <age hours> -- one live tick with a pid and a transcript written just
# now, so no liveness check fires and only the monitor check can.
tick() {
  python3 - "$registry" "$1" <<'PY'
import json, os, sys, time
path, age_hours = sys.argv[1], float(sys.argv[2])
json.dump([{"id": "tick-old", "name": "foreman/tick", "state": "idle", "pid": 4321,
            "startedAt": int((time.time() - age_hours * 3600) * 1000),
            "cwd": os.environ["INSTALL"], "sessionId": "sid-old"}], open(path, "w"))
PY
  : >"$transcripts/sid-old.jsonl"
}
reset() { rm -f "$registry"; : >"$stopped"; : >"$started"; tick "${1:-3}"; }

mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
registry="$registry"; stopped="$stopped"; started="$started"
if [[ "\$1" == "agents" ]]; then cat "\$registry"; exit 0; fi
if [[ "\$1" == "stop" ]]; then
  printf '%s\n' "\$2" >>"\$stopped"
  python3 - "\$registry" "\$2" <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
for r in rows:
    if r["id"] == victim:
        r["state"] = "stopped"; r.pop("pid", None)
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
if [[ "\$1" == "--bg" ]]; then
  name=""
  while [[ \$# -gt 0 ]]; do [[ "\$1" == "--name" ]] && name="\$2"; shift; done
  printf '%s\n' "\$name" >>"\$started"
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

cat >"$home/.local/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then echo '{"total_count": 0, "runners": []}'; fi
exit 0
GH
chmod +x "$home/.local/bin/gh"

stamp="$fh/instances/demo/monitor.stamp"
mkdir -p "$(dirname "$stamp")"

# BSD `touch -t` reads its argument as LOCAL time and GNU touch does not, so a
# UTC-computed stamp lands hours off. os.utime takes an epoch and is portable.
age_stamp() { # <seconds old>
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$stamp" "$1"
}

# Linear, stubbed AT THE BOUNDARY. starved.py queries through
# `resolve_ids.query(args.api_url, ...)` and STARVED_API_URL is that seam; left
# unset it defaults to the real endpoint and this fixture's credentials go at
# the live API. An empty world is enough, because no board here is starving.
printf '{"issues": []}\n' >"$work/scenario.json"
exec 3< <(python3 "$stub" "$work/scenario.json")
STUB_PID=$!
read -r port <&3
api_url="http://127.0.0.1:$port/graphql"

# TICK_STARVED_MINUTES is pushed out of reach so the starved branch never runs.
# Starvation is test-supervise-restarts-a-tick-starving-todo.sh's subject. It
# is a scoping pin and NOT the network defence: STARVED_API_URL above is, so
# lowering this pin reaches the stub rather than Linear.
run_supervise() { # [VAR=value...] -- run mode, with extra environment
  env HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      STARVED_API_URL="$api_url" \
      TICK_STARVED_MINUTES=100000 \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=1 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 "$@" \
      "$supervise" 2>&1
}

# --- 1: a live tick past the grace, with a stale stamp ------------------------
reset 3
age_stamp 600
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && printf '%s' "$out" | grep -q 'demo' \
  && ok "a stale stamp halts foreman and names the board" \
  || bad "a stale stamp did not halt foreman: $out"
grep -qx 'tick-old' "$stopped" \
  && ok "and the tick is asked to stop" \
  || bad "the tick was not asked to stop: $out"

# --- 2: THE POINT OF THIS TEST: it must not come back -------------------------
# A restart against a harness that rejects the Monitor call arms nothing again
# and loops forever.
printf '%s' "$out" | grep -qi 'started .*tick' \
  && bad "halt started a replacement tick; it must not" \
  || ok "halt does not start a replacement"
[[ ! -s "$started" ]] \
  && ok "and the harness was never asked to spawn one" \
  || bad "the harness was asked to spawn a replacement: $(cat "$started")"

# --- 3: a fresh stamp leaves the tick alone -----------------------------------
reset 3
age_stamp 0
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && bad "a fresh stamp halted foreman: $out" \
  || ok "a fresh stamp does not halt"
[[ ! -s "$stopped" ]] \
  && ok "and the tick is left running" \
  || bad "a fresh stamp stopped the tick: $out"

# --- 4: a tick inside the grace is left alone, stamp or no stamp --------------
# Nothing is armed in the first seconds of a tick, by definition, and halting
# there would stop every replacement before its first pass.
reset 3
rm -f "$stamp"
out="$(MONITOR_GRACE_SECONDS=86400 run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && bad "halted inside the grace period: $out" \
  || ok "a tick inside MONITOR_GRACE_SECONDS is left alone"

# --- 5: a missing stamp past the grace halts too ------------------------------
# A Monitor that was never armed leaves no stamp at all, which is the shape of
# the incident this branch exists for.
reset 3
rm -f "$stamp"
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && ok "a board that never stamped halts foreman" \
  || bad "a missing stamp did not halt foreman: $out"

# --- 6: the halt sits AFTER the "loop stopped rescheduling" branch -------------
# A tick that is not running cannot have armed anything, and halting for that
# would hide the real fault: a dead loop is repaired, not halted for.
reset 3
rm -f "$stamp"
: >"$transcripts/sid-old.jsonl"
python3 -c 'import os,sys,time; t=time.time()-86400; os.utime(sys.argv[1], (t, t))' \
  "$transcripts/sid-old.jsonl"
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && bad "a dead loop was halted for instead of repaired: $out" \
  || ok "a dead loop takes the repair branch, not the halt"
grep -q 'foreman/tick' "$started" \
  && ok "and a replacement is started for it" \
  || bad "the dead loop got no replacement: $out"

exit "$fail"
