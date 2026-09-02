#!/usr/bin/env bash
# Claim: `supervise.sh --restart` replaces the tick and disturbs nothing else.
#
# The whole reason a foreman restart is safe is that a dispatched card agent is
# parented to the shared `claude daemon`, not to the tick, and the tick holds no
# state. That makes the restart's contract narrow and checkable: it stops ONE
# agent, by id, the one named $TICK_AGENT_NAME. Every other `foreman/...` agent
# in the host-global registry belongs to a card that is mid-build, and stopping
# one throws away a build that may have been running for half an hour.
#
# A prefix match is how that goes wrong. The tick is `foreman/tick` and a card
# agent is `foreman/<board>/build/<ticket>-<n>`; a matcher that reaches for
# `foreman/` -- or one that stops every agent it inspected -- kills every build
# on the machine and reports a clean restart.
#
# The registry, `claude stop` and `claude --bg` are stubbed. Everything inside
# supervise.sh runs for real, including its flock.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"
withlock="$repo_root/skills/board/withlock.py"

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
: >"$stopped"
: >"$started"

# The two card agents are the point of this file. Their names carry a board
# segment, exactly as config.sh's agent_name() builds them, so a matcher that
# reaches for the `foreman/` prefix instead of the tick's exact name catches
# them.
write_registry() { # <tick-state>
  python3 - "$registry" "$1" <<'PY'
import json, sys
path, tick_state = sys.argv[1], sys.argv[2]
json.dump([
    {"id": "tick-1", "name": "foreman/tick", "state": tick_state,
     "startedAt": 1000, "cwd": "", "sessionId": ""},
    {"id": "card-a", "name": "foreman/demo/build/ABC-1-1", "state": "working",
     "startedAt": 1100, "cwd": "", "sessionId": ""},
    {"id": "card-b", "name": "foreman/demo/review/ABC-2-1", "state": "working",
     "startedAt": 1200, "cwd": "", "sessionId": ""},
], open(path, "w"))
PY
}

# `claude stop` marks an agent stopped rather than deleting it, which is what
# the real registry does -- and it is the harder case: the restart then has to
# tell the replacement tick from the corpse of the one it just stopped, by id.
mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
registry="$registry"
stopped="$stopped"
started="$started"
no_start="$work/no-start"
stop_fails="$work/stop-fails"
bad_registry="$work/bad-registry"
if [[ "\$1" == "agents" ]]; then
  # A registry the CLI cannot render: a daemon restarting, a CLI mid-upgrade.
  if [[ -e "\$bad_registry" ]]; then printf 'not json at all\n'; exit 0; fi
  cat "\$registry"; exit 0
fi
if [[ "\$1" == "stop" ]]; then
  printf '%s\n' "\$2" >>"\$stopped"
  # A stop that fails and leaves the agent running is the case that used to
  # produce two live ticks. No backticks in this here-doc: it is unquoted, so
  # the test's own shell would run whatever they contain.
  [[ -e "\$stop_fails" ]] && exit 1
  python3 - "\$registry" "\$2" <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
agents = json.load(open(path))
for a in agents:
    if a["id"] == victim:
        a["state"] = "stopped"
json.dump(agents, open(path, "w"))
PY
  exit 0
fi
if [[ "\$1" == "--bg" ]]; then
  name=""
  while [[ \$# -gt 0 ]]; do
    [[ "\$1" == "--name" ]] && name="\$2"
    shift
  done
  printf '%s\n' "\$name" >>"\$started"
  [[ -e "\$no_start" ]] && exit 0
  python3 - "\$registry" "\$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
agents = json.load(open(path))
newest = max([a["startedAt"] for a in agents] + [0])
agents.append({"id": "tick-2", "name": name, "state": "idle",
               "startedAt": newest + 1, "cwd": "", "sessionId": ""})
json.dump(agents, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

run() { # <mode...> -- runs supervise.sh with this machine's fixture
  env HOME="$home" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=1 \
      "$supervise" "$@" 2>&1
}

tick_state() { # prints the state of the agent with the given id
  python3 - "$registry" "$1" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])):
    if a["id"] == sys.argv[2]:
        print(a["state"]); break
else:
    print("absent")
PY
}

# --- a restart with a healthy tick and two cards in flight
write_registry idle
out="$(run --restart)"; rc=$?
[[ $rc -eq 0 ]] || bad "--restart exited $rc: $out"

if [[ "$(cat "$stopped")" == "tick-1" ]]; then
  ok "the restart stops the tick and nothing else"
else
  bad "the restart stopped: $(tr '\n' ' ' <"$stopped") -- it must stop only tick-1"
fi
if grep -q "foreman/demo/build/ABC-1-1" <<<"$out" \
   && grep -q "foreman/demo/review/ABC-2-1" <<<"$out"; then
  ok "it names the in-flight card agents it is leaving alone"
else
  bad "it never named the card agents in flight: $out"
fi
if [[ "$(tick_state card-a)" == "working" && "$(tick_state card-b)" == "working" ]]; then
  ok "both card agents are still running afterwards"
else
  bad "a card agent was stopped by the restart"
fi
if [[ "$(tick_state tick-2)" == "idle" ]]; then
  ok "a replacement tick is running under the same name"
else
  bad "no replacement tick came up: $out"
fi

# --- a tick that is mid-turn
# Draining is not a correctness requirement: the tick holds no state, so
# stopping it mid-turn costs nothing but a confusing transcript. The bound is
# what keeps a restart from becoming a wait with no end, so the interesting
# case is the one where the tick never goes quiet.
write_registry working
: >"$stopped"
out="$(run --restart)"; rc=$?
if [[ $rc -eq 0 && "$(cat "$stopped")" == "tick-1" ]]; then
  ok "a tick that never finishes its turn is stopped once the drain bound passes"
else
  bad "a working tick was not replaced (rc=$rc): $out"
fi

# --- the replacement never appears
# `claude --bg` returns as soon as an agent is SPAWNED, so "started" is not
# evidence that a tick exists. A restart that reports success over a tick that
# never came up leaves the board stopped until the next timer fire, which is up
# to ten minutes of a machine that looks restarted and is idle.
write_registry idle
: >"$stopped"
: >"$work/no-start"
out="$(env HOME="$home" FOREMAN_INSTANCE=demo SUPERVISE_LOCK="$work/supervise.lock" \
        TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=1 \
        "$supervise" --restart 2>&1)"; rc=$?
rm -f "$work/no-start"
if [[ $rc -ne 0 ]]; then
  ok "a restart whose replacement never appears fails loudly"
else
  bad "the restart reported success with no tick running: $out"
fi

# --- `claude stop` fails and the old tick keeps running
# The restart must not start a replacement it cannot place beside a stopped
# tick. Two live `foreman/tick` agents both run `/loop /board` against one
# machine-wide HOST_MAX_CONCURRENT, which is the double-dispatch supervise.sh
# exists to prevent -- and the survivor is invisible afterwards, because the
# registry read reports only the newest agent of that name.
write_registry idle
: >"$stopped"
: >"$started"
: >"$work/stop-fails"
out="$(run --restart)"; rc=$?
rm -f "$work/stop-fails"
if [[ $rc -ne 0 ]]; then
  ok "a restart whose stop did not stop the tick fails loudly"
else
  bad "the restart reported success over a tick that never stopped: $out"
fi
if [[ ! -s "$started" && "$(tick_state tick-1)" == "idle" && "$(tick_state tick-2)" == "absent" ]]; then
  ok "it starts no second tick beside the one that would not stop"
else
  bad "a second tick was started beside a live one (started=$(tr '\n' ' ' <"$started")): $out"
fi

# --- the registry cannot be read
# A transient unreadable registry -- a daemon restarting, a CLI mid-upgrade --
# used to make --restart exit 0 having done nothing. The operator had just
# pulled new install code and was told nothing failed, while the old tick kept
# running the old skill; nothing retries a restart, and run mode stands down on
# this same condition, so it never happened at all.
write_registry idle
: >"$stopped"
: >"$started"
: >"$work/bad-registry"
out="$(run --restart)"; rc=$?
if [[ $rc -ne 0 && ! -s "$started" ]]; then
  ok "a restart against an unreadable registry refuses instead of exiting 0"
else
  bad "--restart exited $rc against an unreadable registry: $out"
fi

# --stop is the same gesture from the same operator, and "stop ticking" that did
# not stop ticking, reported as success, is what they act on next.
: >"$stopped"
out="$(run --stop)"; rc=$?
if [[ $rc -ne 0 ]]; then
  ok "a stop against an unreadable registry refuses instead of exiting 0"
else
  bad "--stop exited 0 against an unreadable registry: $out"
fi

# Run mode is the one that still stands down: it is a timer fire, doing nothing
# is safe, and the next fire re-reads. Starting a tick on a registry it cannot
# read is how a second one appears beside a healthy one.
: >"$started"
out="$(run)"; rc=$?
rm -f "$work/bad-registry"
if [[ $rc -eq 0 && ! -s "$started" ]]; then
  ok "a timer fire against an unreadable registry stands down and starts nothing"
else
  bad "run mode did not stand down (rc=$rc, started=$(tr '\n' ' ' <"$started")): $out"
fi

# --- another supervisor holds the machine lock
# The lock is what stops a timer fire from interleaving with a hand-run
# restart. Without it the fire can start a tick that the restart then does not
# know about, and the machine ends up with two ticks dispatching into one
# HOST_MAX_CONCURRENT.
write_registry idle
: >"$stopped"
"$withlock" "$work/supervise.lock" 30 -- sleep 3 &
holder=$!
sleep 1
out="$(run --restart)"; rc=$?
wait "$holder" 2>/dev/null
if [[ $rc -eq 0 && ! -s "$stopped" ]]; then
  ok "a restart stands down while another supervisor holds the lock"
else
  bad "the restart ran against a held lock (rc=$rc, stopped=$(tr '\n' ' ' <"$stopped")): $out"
fi

# --- an unrecognised mode
# `MODE="${1:-run}"` used to send every typo into run mode, so `--restrat`
# started or restarted a tick the operator never asked about.
write_registry idle
: >"$stopped"
: >"$started"
out="$(run --restrat)"; rc=$?
if [[ $rc -eq 2 && ! -s "$stopped" && ! -s "$started" ]]; then
  ok "an unrecognised mode refuses instead of falling into run mode"
else
  bad "--restrat was accepted (rc=$rc): $out"
fi

# --- a dry run
write_registry idle
: >"$stopped"
: >"$started"
out="$(BOARD_DRY_RUN=1 run --restart)"; rc=$?
if [[ ! -s "$stopped" && ! -s "$started" ]]; then
  ok "a dry-run restart changes nothing"
else
  bad "BOARD_DRY_RUN=1 --restart still stopped or started an agent: $out"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: --restart replaces the tick and leaves every card agent running\n'
exit "$fail"
