#!/usr/bin/env bash
# Claim: `supervise.sh --restart` does not wait out TICK_DRAIN_SECONDS for a
# tick that is sleeping between passes, and does wait for one mid-pass.
#
# A detached loop tick (Codex, OpenCode) lists `working` for its whole life,
# asleep or not; only its status, "between passes", says it is asleep. The
# drain read state alone, so every restart of such a tick waited the full bound
# for a turn that was not running.
#
# The registry is the external boundary, stubbed as the `claude` CLI that
# harness/claude.sh reads; it passes each row's status through as listed.
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"
# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work/target"
git init -q -b main "$target"
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" demo "$target"
fixture_link_board_skill "$home"
registry="$work/registry.json"

write_registry() { # <status, or empty for none>
  python3 - "$registry" "$1" <<'PY'
import json, sys, time
path, status = sys.argv[1], sys.argv[2] or None
now = int(time.time() * 1000)
json.dump([{"id": "tick-1", "name": "foreman/tick", "state": "working", "pid": 4242,
            "status": status, "startedAt": now - 60_000, "cwd": "", "sessionId": "s-1"}],
          open(path, "w"))
PY
}

mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then cat "$registry"; exit 0; fi
if [[ "\$1" == "stop" ]]; then
  python3 - "$registry" "\$2" <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
agents = json.load(open(path))
for a in agents:
    if a["id"] == victim:
        a["state"], a["pid"] = "stopped", None
json.dump(agents, open(path, "w"))
PY
  exit 0
fi
if [[ "\$1" == "--bg" ]]; then
  python3 - "$registry" <<'PY'
import json, sys, time
path = sys.argv[1]
agents = json.load(open(path))
agents.append({"id": "tick-2", "name": "foreman/tick", "state": "idle", "pid": 4343,
               "startedAt": int(time.time() * 1000), "cwd": "", "sessionId": "s-2"})
json.dump(agents, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

restart() { # prints the seconds the restart took, then its output
  local started out
  started="$(date +%s)"
  out="$(env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    SUPERVISE_LOCK="$work/supervise.lock" TICK_DRAIN_SECONDS=12 \
    TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=5 TICK_LOCK_WAIT_SECONDS=2 \
    "$supervise" --restart 2>&1)"
  printf '%s\n%s\n' "$(( $(date +%s) - started ))" "$out"
}

write_registry "between passes"
result="$(restart)"
elapsed="$(head -1 <<<"$result")"
grep -q 'not mid-turn' <<<"$result" && [[ "$elapsed" -lt 12 ]] \
  && ok "a tick between passes is stopped without a drain (${elapsed}s)" \
  || bad "a tick between passes was drained (${elapsed}s): $result"

write_registry ""
result="$(restart)"
elapsed="$(head -1 <<<"$result")"
grep -q 'still working after 12s' <<<"$result" \
  && ok "a tick mid-pass is still drained (${elapsed}s)" \
  || bad "a tick mid-pass was not drained: $result"

[[ "$fail" -eq 0 ]] && printf 'PASS: a restart does not drain a tick between passes\n'
exit "$fail"
