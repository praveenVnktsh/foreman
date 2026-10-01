#!/usr/bin/env bash
# Claim: a `foreman/[<installation>/]tick` registry row with no process behind it is not a live
# tick. supervise.sh does not wait for it to stop, and starts a replacement
# past it.
#
# Measured on 2026-09-14. A tick row from ten days earlier sat in the registry
# with `state: working`, no pid, and a transcript silent for 14112 minutes. A
# restart stopped the real tick, then found that row, asked it to stop eight
# times over 30 seconds, and refused to start a replacement beside "a tick that
# is still live". Every timer fire after that did the same. The board ran no
# tick for forty minutes, and would have run none until an operator archived
# the row by hand. A stop cannot land on a process that does not exist, so
# waiting for one to land is waiting forever.
#
# Measured again on 2026-09-30. The tick ran one pass and ended its
# turn, twice over: once after deferring to a stale opencode tick record, once
# because its board skill link dangled. `claude agents` kept listing it as
# `state: working` with no pid, and its transcript had been written minutes
# earlier, so a "fresh transcript means live" test called it healthy for forty
# minutes while nothing dispatched. A transcript proves the agent once ran, not
# that it still does.
#
# The rule: a row with no pid is alive only while it is younger than
# TICK_START_TIMEOUT_SECONDS (registered, not started yet). Past that it is a
# corpse, whatever its transcript says and whichever harness listed it. A row
# with a pid is live whatever its transcript says.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

target="$work/target"
mkdir -p "$target"
git -C "$target" init -q -b main
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" demo "$target"
fixture_link_board_skill "$home"

registry="$work/registry.json"
stopped="$work/stopped.log"
started="$work/started.log"
install="$home/install"
mkdir -p "$install"
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
transcripts="$home/.claude/projects/$(slug "$install")"
mkdir -p "$transcripts"

# row <id> <state> <pid or -> <sessionId> [age hours] [harness] -- one tick row, as the
# registry reports it. `-` means the row carries no pid at all, which is how
# the registry reports an agent with no process. The default age is the ten
# days the measured corpse had; a row meant to read as a healthy tick passes a
# small one, or run mode recycles it for age and the case tests nothing.
row() {
  python3 - "$registry" "$@" <<'PY'
import json, os, sys, time
path, tid, state, pid, sid = sys.argv[1:6]
age_hours = float(sys.argv[6]) if len(sys.argv) > 6 else 264
rows = json.load(open(path)) if os.path.exists(path) else []
r = {"id": tid, "name": "foreman/tick", "state": state,
     "startedAt": int((time.time() - age_hours * 3600) * 1000),
     "cwd": os.environ["INSTALL"], "sessionId": sid}
if len(sys.argv) > 7:
    r["harness"] = sys.argv[7]
if pid != "-":
    r["pid"] = int(pid)
rows.append(r)
json.dump(rows, open(path, "w"))
PY
}
export INSTALL="$install"
transcript() { # <sessionId> <old|fresh>
  : >"$transcripts/$1.jsonl"
  [[ "$2" == "old" ]] && touch -t 202609010000 "$transcripts/$1.jsonl"
}
reset() { rm -f "$registry"; : >"$stopped"; : >"$started"; }

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
  python3 - "\$registry" "\$name" <<'PY'
import json, sys, time
path, name = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
rows.append({"id": "tick-new", "name": name, "state": "working", "pid": 4242,
             "startedAt": int(time.time() * 1000), "cwd": "", "sessionId": "sid-new"})
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

run() { # <mode...>
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 \
      "$supervise" "$@" 2>&1
}

# --- a row with no pid and a transcript silent for days is a corpse ----------
reset; row corpse working - sid-corpse; transcript sid-corpse old
out="$(run)"
grep -q 'foreman/tick' "$started" \
  && ok "run mode starts a tick past a working row that has no process" \
  || bad "run mode started nothing past the corpse: $out"
[[ ! -s "$stopped" ]] \
  && ok "and asks nothing to stop, since a stop cannot land on a process that does not exist" \
  || bad "run mode asked the corpse to stop: $(cat "$stopped")"
grep -q 'ignoring foreman/tick (corpse)' <<<"$out" \
  && ok "and says which row it is ignoring, and why" \
  || bad "the corpse was not named in the log: $out"
grep -q 'ERROR' <<<"$out" \
  && bad "run mode still reported the corpse as a live tick that will not stop: $out" \
  || ok "no 'still live after being asked to stop' error"

# --- the same row WITH a pid is a live tick, wedged, and is stopped ------------
reset; row wedged working 4321 sid-wedged; transcript sid-wedged old
out="$(run)"
grep -qx 'wedged' "$stopped" \
  && ok "a working row with a pid and a silent transcript is a wedged tick and is asked to stop" \
  || bad "the wedged tick with a pid was not asked to stop: $out"
grep -q 'foreman/tick' "$started" \
  && ok "and is replaced once the stop lands" \
  || bad "no replacement after stopping the wedged tick: $out"

# --- the 2026-09-30 incident: no pid, a fresh transcript, and 14 minutes old --
reset; row ended working - sid-ended 0.2333; transcript sid-ended fresh
out="$(run)"
grep -q 'foreman/tick' "$started" \
  && ok "a pid-less working row past the start window is replaced despite a fresh transcript" \
  || bad "run mode trusted the fresh transcript of a row with no process: $out"
[[ ! -s "$stopped" ]] \
  && ok "and nothing is asked to stop" \
  || bad "run mode asked the pid-less row to stop: $(cat "$stopped")"
grep -q 'ignoring foreman/tick (' <<<"$out" \
  && ok "and the row is named in the log" \
  || bad "the pid-less row was not named in the log: $out"

# --- the same, listed by another harness (left behind after a switch) ---------
reset; row stale working - sid-stale 0.2333 opencode; transcript sid-stale fresh
out="$(run)"
grep -q 'foreman/tick' "$started" && [[ ! -s "$stopped" ]] \
  && ok "a pid-less row from another harness is replaced the same way" \
  || bad "the opencode row was treated as live: $out"
reset; row stale working - sid-stale 0.2333 opencode; transcript sid-stale fresh
out="$(run --status)"
printf '%s\n' "$out" | tail -n1 | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("live_ticks")==0 else 1)' \
  && ok "--status does not count it live" \
  || bad "--status counted the opencode row as live: $out"

# --- a row registered just now has not started yet, and is left alone ---------
reset; row new working - sid-new 0; transcript sid-new fresh
out="$(run)"
[[ ! -s "$started" && ! -s "$stopped" ]] \
  && ok "a pid-less row registered just now is still live: nothing started or stopped" \
  || bad "a row inside the start window was stopped or replaced: $out"

# --- --restart beside a corpse replaces the live tick and does not wait -------
reset
row corpse working - sid-corpse; transcript sid-corpse old
row live idle 5555 sid-live; transcript sid-live fresh
out="$(run --restart)"; status=$?
[[ "$status" -eq 0 ]] \
  && ok "--restart exits zero with a corpse in the registry" \
  || bad "--restart failed beside a corpse (exit $status): $out"
[[ "$(sort -u "$stopped" | tr '\n' ' ')" == "live " ]] \
  && ok "it stops the live tick and only the live tick" \
  || bad "--restart stopped the wrong set: $(sort -u "$stopped" | tr '\n' ' ')"
grep -q 'confirmed: foreman/tick is up (tick-new)' <<<"$out" \
  && ok "and confirms the replacement, uncounted against the corpse" \
  || bad "--restart did not confirm the replacement: $out"

# --- --status counts no corpse as live --------------------------------------
reset; row corpse working - sid-corpse; transcript sid-corpse old
out="$(run --status)"
printf '%s\n' "$out" | tail -n1 | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("live_ticks")==0 else 1)' \
  && ok "--status reports zero live ticks when only a corpse remains" \
  || bad "--status counted the corpse as live: $out"

exit "$fail"
