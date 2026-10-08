#!/usr/bin/env bash
# Claim: with the board skill link broken, a timer fire that finds two live
# ticks stops the older one, starts nothing, and leaves the newer one live. The
# link check protects a replacement, and trimming to one starts none.
# supervise.sh's repair_tick() says why. A control with the link fixed
# proves the same fire still stops both and starts one.
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

# Two live ticks with pids: tick-old started before tick-new.
reset() {
  python3 - "$registry" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
json.dump([
    {"id": "tick-old", "name": "foreman/tick", "state": "working", "pid": 41001,
     "startedAt": now - 120_000, "cwd": "", "sessionId": "session-tick-old"},
    {"id": "tick-new", "name": "foreman/tick", "state": "working", "pid": 41002,
     "startedAt": now - 60_000, "cwd": "", "sessionId": "session-tick-new"},
], open(sys.argv[1], "w"))
PY
  : >"$stopped"; : >"$started"
}

live_ids() { # the ids the registry does not call stopped, space-separated
  python3 - "$registry" <<'PY'
import json, sys
print(" ".join(a["id"] for a in json.load(open(sys.argv[1])) if a["state"] != "stopped"))
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
rows.append({"id": "tick-fresh", "name": name, "state": "idle", "pid": 41099,
             "startedAt": int(time.time() * 1000) + 1, "cwd": "",
             "sessionId": "session-tick-fresh"})
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

run() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 \
      "$supervise" "$@" 2>&1
}

skills="$home/.claude/skills"
rm -rf "$skills/board"; mkdir -p "$skills"
ln -s "$work/elsewhere/install/skills/board" "$skills/board"

# --- 1: two live ticks over a dangling link ---------------------------------
reset
out="$(run)"; rc=$?
grep -q '2 foreman/tick agents are live' <<<"$out" \
  && ok "broken link: the duplicate-tick branch was reached" \
  || bad "broken link: the duplicate-tick branch was never reached: $out"
[[ $rc -eq 0 ]] && ok "broken link: exits zero" || bad "broken link: exited $rc: $out"
grep 'ERROR:' <<<"$out" | grep -q 'does not resolve to this install' \
  && ok "broken link: an ERROR line names the link" \
  || bad "broken link: no ERROR line naming the link: $out"
grep 'ERROR:' <<<"$out" | grep -q 'install-skills.sh' \
  && ok "broken link: the ERROR line names install-skills.sh" \
  || bad "broken link: no ERROR line naming install-skills.sh: $out"
[[ "$(sort -u "$stopped" | tr '\n' ' ')" == "tick-old " ]] \
  && ok "broken link: only the older tick was stopped" \
  || bad "broken link: stopped $(tr '\n' ' ' <"$stopped"), not just tick-old: $out"
[[ ! -s "$started" ]] && ok "broken link: nothing was started" \
  || bad "broken link: a tick was started: $(tr '\n' ' ' <"$started")"
[[ "$(live_ids)" == "tick-new" ]] && ok "broken link: the newer tick is still live" \
  || bad "broken link: live ticks are '$(live_ids)', not tick-new: $out"

# --- 2: control, the link fixed ---------------------------------------------
fixture_link_board_skill "$home"
reset
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && ok "control: exits zero" || bad "control: exited $rc: $out"
[[ "$(sort -u "$stopped" | tr '\n' ' ')" == "tick-new tick-old " ]] \
  && ok "control: with the link fixed the same fire stops both ticks" \
  || bad "control: stopped $(tr '\n' ' ' <"$stopped"), not both: $out"
[[ "$(cat "$started")" == "foreman/tick" ]] && ok "control: one tick was started" \
  || bad "control: started '$(tr '\n' ' ' <"$started")', not one tick: $out"

exit "$fail"
