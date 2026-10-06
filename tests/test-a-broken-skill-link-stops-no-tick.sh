#!/usr/bin/env bash
# Claim: with the board skill link broken, `supervise.sh --restart` and a
# watchdog repair stop NO tick: the check runs before any stop, so the board
# keeps the tick it has. supervise.sh's board_skill_resolves() says why.
# A control with the link fixed proves the repair branch does stop the tick,
# so the test cannot pass merely because that branch never ran.
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

registry="$work/registry.json"
stopped="$work/stopped.log"
started="$work/started.log"

# One live tick with a pid and a recent start, so no liveness rule fires.
reset() {
  python3 - "$registry" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
json.dump([{"id": "tick-1", "name": "foreman/tick", "state": "working",
            "pid": 41001, "startedAt": now - 60_000, "cwd": "",
            "sessionId": "session-tick-1"}], open(sys.argv[1], "w"))
PY
  : >"$stopped"; : >"$started"
}

tick_live() { # prints "live" when tick-1 is neither stopped nor absent
  python3 - "$registry" <<'PY'
import json, sys
print("live" if any(a["id"] == "tick-1" and a["state"] != "stopped"
                    for a in json.load(open(sys.argv[1]))) else "gone")
PY
}

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
for a in rows:
    if a["id"] == victim:
        a["state"] = "stopped"
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
rows.append({"id": "tick-2", "name": name, "state": "idle", "pid": 41099,
             "startedAt": int(time.time() * 1000) + 1, "cwd": "",
             "sessionId": "session-tick-2"})
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

# TICK_MAX_AGE_HOURS=0 sends a timer fire down the age-recycle branch, which
# calls repair_tick on an otherwise healthy tick.
run() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" TICK_MAX_AGE_HOURS=0 \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 \
      "$supervise" "$@" 2>&1
}

skills="$home/.claude/skills"
rm -rf "$skills/board"; mkdir -p "$skills"
ln -s "$work/elsewhere/install/skills/board" "$skills/board"

untouched() { # <label>: nothing stopped, nothing started, tick still live
  [[ ! -s "$stopped" ]] && ok "$1: no stop was issued" \
    || bad "$1: a stop was issued: $(tr '\n' ' ' <"$stopped")"
  [[ ! -s "$started" ]] && ok "$1: nothing was started" \
    || bad "$1: a tick was started: $(tr '\n' ' ' <"$started")"
  [[ "$(tick_live)" == "live" ]] && ok "$1: the tick is still live" \
    || bad "$1: the tick was stopped"
}

# --- 1: --restart over a dangling link --------------------------------------
reset
out="$(run --restart)"; rc=$?
[[ $rc -ne 0 ]] && ok "--restart: exits non-zero" || bad "--restart exited zero: $out"
grep -q 'does not resolve to this install' <<<"$out" && grep -q 'install-skills.sh' <<<"$out" \
  && ok "--restart: the message names the link and install-skills.sh" \
  || bad "--restart: the message does not name the link: $out"
untouched "--restart"

# --- 2: a timer fire that reaches repair_tick -------------------------------
reset
out="$(run)"; rc=$?
grep -q 'recycling foreman/tick' <<<"$out" \
  && ok "timer fire: the recycle branch (repair_tick) was reached" \
  || bad "timer fire: repair_tick was never reached: $out"
[[ $rc -eq 0 ]] && ok "timer fire: exits zero" || bad "timer fire exited $rc: $out"
grep 'ERROR:' <<<"$out" | grep -q 'does not resolve to this install' \
  && ok "timer fire: an ERROR line names the link" \
  || bad "timer fire: no ERROR line naming the link: $out"
untouched "timer fire"

# --- 3: control, the link fixed ---------------------------------------------
fixture_link_board_skill "$home"
reset
out="$(run)"; rc=$?
[[ "$(cat "$stopped")" == "tick-1" ]] \
  && ok "control: with the link fixed the same fire stops the tick" \
  || bad "control: the fire did not stop tick-1 (stopped=$(tr '\n' ' ' <"$stopped")): $out"

exit "$fail"
