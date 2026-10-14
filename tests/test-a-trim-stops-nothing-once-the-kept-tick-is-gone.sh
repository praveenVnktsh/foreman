#!/usr/bin/env bash
# Claim: with the board skill link broken, a timer fire that finds two live
# ticks, the newest of which exits before the trim, stops nothing and starts
# nothing. Trimming every tick but one that is already gone leaves none, and
# the broken link starts no replacement. supervise.sh's stop_ticks() says why.
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
read_once="$work/read-once"

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
  : >"$stopped"; : >"$started"; rm -f "$read_once"
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
registry="$registry"; stopped="$stopped"; started="$started"; read_once="$read_once"
mark_stopped() {
  python3 - "\$registry" "\$1" <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
for a in rows:
    if a["id"] == victim:
        a["state"] = "stopped"
json.dump(rows, open(path, "w"))
PY
}
if [[ "\$1" == "agents" ]]; then
  # inspect() reads first and sees both live. Every later read sees the newest
  # stopped, as if it exited between inspect() and the trim.
  [[ -e "\$read_once" ]] && mark_stopped tick-new
  : >"\$read_once"
  cat "\$registry"; exit 0
fi
if [[ "\$1" == "stop" ]]; then
  printf '%s\n' "\$2" >>"\$stopped"
  mark_stopped "\$2"
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

# --- two live ticks over a dangling link, the newest gone by the trim ------
reset
out="$(run)"; rc=$?
grep -q '2 foreman/tick agents are live' <<<"$out" \
  && ok "the duplicate-tick branch was reached" \
  || bad "the duplicate-tick branch was never reached: $out"
[[ $rc -eq 0 ]] && ok "exits zero" || bad "exited $rc: $out"
[[ ! -s "$stopped" ]] && ok "the older tick was not stopped" \
  || bad "stopped $(tr '\n' ' ' <"$stopped"): $out"
[[ ! -s "$started" ]] && ok "nothing was started" \
  || bad "a tick was started: $(tr '\n' ' ' <"$started"): $out"
grep 'ERROR:' <<<"$out" | grep -Eq 'tick-new.*(gone|no longer live)' \
  && ok "an ERROR line names the kept tick as gone" \
  || bad "no ERROR line names tick-new as gone: $out"
[[ "$(live_ids)" == "tick-old" ]] && ok "the older tick is still live" \
  || bad "live ticks are '$(live_ids)', not tick-old: $out"

exit "$fail"
