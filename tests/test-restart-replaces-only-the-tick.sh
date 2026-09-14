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
# A prefix match is how that goes wrong. The tick is `foreman/[<installation>/]tick`
# and a card agent is `foreman/[<installation>/]<board>/build/<ticket>-<n>`; a
# matcher that reaches for `foreman/[<installation>/]` -- or one that stops every
# agent it inspected -- kills every build on the machine and reports a clean
# restart. The fixture home declares no installation.toml, so
# bin/installation.py reads it as the lone Claude installation with legacy
# names: the tick is `foreman/tick` and every card agent starts `foreman/`,
# the shape where a prefix match reaches furthest.
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
write_registry() { # <tick-state> [extra tick rows, each "<id>:<state>:<age seconds>"]
  python3 - "$registry" "$@" <<'PY'
import json, sys, time
path, tick_state, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
# Recent timestamps, so no run-mode staleness threshold fires and each case
# below tests the thing it names. An epoch-millisecond 1000 makes every agent
# read as 56 years old, which sends every timer fire down the recycle branch.
now = int(time.time() * 1000)
agents = [
    {"id": "tick-1", "name": "foreman/tick", "state": tick_state,
     "startedAt": now - 60_000, "cwd": "", "sessionId": "session-tick-1"},
    {"id": "card-a", "name": "foreman/demo/build/ABC-1-1", "state": "working",
     "startedAt": now - 50_000, "cwd": "", "sessionId": "session-card-a"},
    {"id": "card-b", "name": "foreman/demo/review/ABC-2-1", "state": "working",
     "startedAt": now - 40_000, "cwd": "", "sessionId": "session-card-b"},
]
# An extra tick row is written OLDER than tick-1, so it is the one the registry
# read hides behind the newest.
for n, spec in enumerate(extra, start=1):
    tid, state, age_seconds = spec.split(":")
    agents.append({"id": tid, "name": "foreman/tick", "state": state,
                   "startedAt": now - int(age_seconds) * 1000,
                   "cwd": "", "sessionId": "session-" + tid})
json.dump(agents, open(path, "w"))
PY
}

# Every foreman/tick in the registry that is not stopped, space-separated. One
# is the only correct number, so most assertions below are about this string.
live_ticks() {
  python3 - "$registry" <<'PY'
import json, sys
print(" ".join(sorted(a["id"] for a in json.load(open(sys.argv[1]))
                      if a["name"] == "foreman/tick" and a["state"] != "stopped")))
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
stop_card_a="$work/stop-card-a"
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
  # Something else stops a card agent while the restart is in flight. The
  # restart never does this; the point is what it REPORTS when it happens.
  if [[ -e "\$stop_card_a" ]]; then
    python3 - "\$registry" card-a <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
agents = json.load(open(path))
for a in agents:
    if a["id"] == victim:
        a["state"] = "stopped"
json.dump(agents, open(path, "w"))
PY
  fi
  [[ -e "\$no_start" ]] && exit 0
  python3 - "\$registry" "\$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
agents = json.load(open(path))
newest = max([a["startedAt"] for a in agents] + [0])
agents.append({"id": "tick-2", "name": name, "state": "idle",
               "startedAt": newest + 1, "cwd": "", "sessionId": "session-tick-2"})
json.dump(agents, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

# FOREMAN_HOME is pinned to the fixture's, not merely left alone. config.sh
# exports it and bin/install-service.sh writes it into the unit, so it reaches
# the tick and every agent the board dispatches -- which is where this suite
# actually runs, because foreman builds itself. Inherited, config.sh reads the
# real machine's boards.toml, supervise.sh dies with "no board named demo", and
# the assertions that only check a non-zero exit go on printing `ok` over code
# that never ran. tests/test-one-tick-for-all-boards.sh pins it for this reason.
run() { # <mode...> -- runs supervise.sh with this machine's fixture
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=1 \
      TICK_LOCK_WAIT_SECONDS=2 \
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
out="$(env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
        SUPERVISE_LOCK="$work/supervise.lock" \
        TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=1 TICK_STOP_TIMEOUT_SECONDS=1 \
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
#
# An operator's gesture WAITS for it rather than standing down. Exiting 0 on a
# held lock reported success without restarting anything, and an operator
# running `git pull && supervise.sh --restart` was told the whole chain worked
# while the tick kept running the pre-pull skill.
write_registry idle
: >"$stopped"
"$withlock" "$work/supervise.lock" 30 -- sleep 2 &
holder=$!
sleep 0.3
out="$(run --restart)"; rc=$?
wait "$holder" 2>/dev/null
if [[ $rc -eq 0 && "$(cat "$stopped")" == "tick-1" ]]; then
  ok "a restart waits for a supervisor that is about to finish, then runs"
else
  bad "the restart did not wait for the lock (rc=$rc, stopped=$(tr '\n' ' ' <"$stopped")): $out"
fi

# Held for longer than the operator is willing to wait: refuse, do not exit 0.
write_registry idle
: >"$stopped"
: >"$started"
"$withlock" "$work/supervise.lock" 30 -- sleep 6 &
holder=$!
sleep 0.3
out="$(run --restart)"; rc=$?
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
if [[ $rc -ne 0 && ! -s "$stopped" && ! -s "$started" ]]; then
  ok "a restart that never gets the lock refuses instead of exiting 0"
else
  bad "the restart exited $rc against a lock it never took: $out"
fi

# Run mode is the one that still stands down on a held lock: the next timer
# fire is TICK_INTERVAL_MINUTES away and re-reads everything.
: >"$started"
"$withlock" "$work/supervise.lock" 30 -- sleep 3 &
holder=$!
sleep 0.3
out="$(run)"; rc=$?
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
if [[ $rc -eq 0 && ! -s "$started" ]]; then
  ok "a timer fire stands down while another supervisor holds the lock"
else
  bad "run mode did not stand down on a held lock (rc=$rc): $out"
fi

# --- a second live tick behind the newest one
# The registry reports only the NEWEST agent of a name, so a live tick sitting
# behind a newer one is invisible to --status and to every health check. A
# restart that stopped only the newest left it running and then started a
# replacement beside it: two ticks running /loop /board against one
# machine-wide HOST_MAX_CONCURRENT.
write_registry idle tick-0:idle:120
: >"$stopped"
out="$(run --restart)"; rc=$?
if [[ $rc -eq 0 && "$(live_ticks)" == "tick-2" ]]; then
  ok "a restart stops every live tick, not only the newest"
else
  bad "the restart left these ticks live: $(live_ticks) (rc=$rc): $out"
fi
if [[ "$(tick_state card-a)" == "working" && "$(tick_state card-b)" == "working" ]]; then
  ok "it still leaves both card agents running"
else
  bad "a card agent was stopped while clearing two ticks"
fi

# The same registry, with a --bg that spawns nothing. The survivor must not be
# mistaken for the replacement: it satisfied "a live id that is not the one we
# stopped" while no replacement had come up at all, and the operator who had
# just pulled new install code was told the restart worked.
write_registry idle tick-0:idle:120
: >"$stopped"
: >"$work/no-start"
out="$(run --restart)"; rc=$?
rm -f "$work/no-start"
if [[ $rc -ne 0 ]]; then
  ok "a survivor is not accepted as proof the replacement came up"
else
  bad "the restart confirmed a replacement that never spawned: $out"
fi

# --stop has the identical contract: it means every tick, not the newest one.
write_registry idle tick-0:idle:120
: >"$stopped"
out="$(run --stop)"; rc=$?
if [[ $rc -eq 0 && -z "$(live_ticks)" ]]; then
  ok "a stop stops every live tick, not only the newest"
else
  bad "--stop left these ticks live: $(live_ticks) (rc=$rc): $out"
fi

# --- run mode reconciles the count itself
# Two live ticks is a fault the watchdog repairs, not a state it judges the
# health of. Run mode used to manufacture this state: with a live tick behind a
# newer STOPPED one it read "the tick is stopped" and started a second live one.
write_registry stopped tick-0:idle:120
: >"$started"
out="$(run)"; rc=$?
if [[ $rc -eq 0 && "$(live_ticks)" == "tick-0" && ! -s "$started" ]]; then
  ok "a timer fire leaves a healthy tick alone when a newer corpse sits above it"
else
  bad "run mode started a second tick (live=$(live_ticks), started=$(tr '\n' ' ' <"$started")): $out"
fi

write_registry idle tick-0:idle:120
: >"$started"
out="$(run)"; rc=$?
if [[ $rc -eq 0 && "$(live_ticks)" == "tick-2" ]]; then
  ok "a timer fire that finds two live ticks reconciles them to one"
else
  bad "run mode left these ticks live: $(live_ticks) (rc=$rc): $out"
fi

# --- run mode never dies on a stop that will not land
# The tick whose stop is slowest to land is the wedged one this branch exists
# for, and dying here marked foreman.service failed every ten minutes while
# fixing nothing. It must start no replacement either.
write_registry idle tick-0:idle:120
: >"$started"
: >"$work/stop-fails"
out="$(run)"; rc=$?
rm -f "$work/stop-fails"
if [[ $rc -eq 0 && ! -s "$started" ]] && grep -q "ERROR" <<<"$out"; then
  ok "a timer fire whose stop does not land says so and starts nothing"
else
  bad "run mode died or started a tick over a failed stop (rc=$rc): $out"
fi

# The same on the single-tick repair path, which is the one run mode exists
# for. TICK_MAX_AGE_HOURS=0 forces the recycle branch on a healthy tick.
write_registry idle
: >"$started"
: >"$work/stop-fails"
out="$(env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
        SUPERVISE_LOCK="$work/supervise.lock" TICK_MAX_AGE_HOURS=0 \
        TICK_DRAIN_SECONDS=1 TICK_STOP_TIMEOUT_SECONDS=1 \
        "$supervise" 2>&1)"; rc=$?
rm -f "$work/stop-fails"
if [[ $rc -eq 0 && ! -s "$started" && "$(live_ticks)" == "tick-1" ]]; then
  ok "a repair whose stop does not land leaves one tick and does not fail the unit"
else
  bad "the recycle path died or doubled the tick (rc=$rc, live=$(live_ticks)): $out"
fi

# --- the after-restart card report states what it saw, not why
# card_agents() used to drop stopped rows, so an agent the restart had stopped
# and one that finished looked identical, and the line printed over both said
# "a build completing is not a disturbance".
write_registry idle
: >"$stopped"
: >"$work/stop-card-a"
out="$(run --restart)"; rc=$?
rm -f "$work/stop-card-a"
if grep -q "went from working to stopped" <<<"$out" \
   && ! grep -q "not a disturbance" <<<"$out"; then
  ok "a card agent that stops during the restart is reported as stopped, not as finished"
else
  bad "the after-restart report explained away a card agent that stopped: $out"
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
if [[ $rc -eq 0 && ! -s "$stopped" && ! -s "$started" ]]; then
  ok "a dry-run restart changes nothing"
else
  bad "BOARD_DRY_RUN=1 --restart still stopped or started an agent (rc=$rc): $out"
fi

# Every mode that stops a tick now goes through one function, so a dry run must
# answer for all of them rather than spinning out the stop bound and reporting
# a tick that would not stop.
write_registry idle tick-0:idle:120
: >"$stopped"
: >"$started"
out="$(BOARD_DRY_RUN=1 run)"; rc=$?
if [[ $rc -eq 0 && ! -s "$stopped" && ! -s "$started" ]] && grep -q "DRY RUN" <<<"$out"; then
  ok "a dry-run timer fire says what it would do and changes nothing"
else
  bad "BOARD_DRY_RUN=1 run mode acted or failed (rc=$rc): $out"
fi

write_registry idle tick-0:idle:120
: >"$stopped"
out="$(BOARD_DRY_RUN=1 run --stop)"; rc=$?
if [[ $rc -eq 0 && ! -s "$stopped" ]]; then
  ok "a dry-run stop changes nothing"
else
  bad "BOARD_DRY_RUN=1 --stop still stopped an agent (rc=$rc): $out"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: --restart replaces the tick and leaves every card agent running\n'
exit "$fail"
