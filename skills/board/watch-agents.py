#!/usr/bin/env python3
"""Emit one line whenever a dispatched board agent finishes. Never exits.

Intended as the command behind a persistent Monitor, so that an agent coming
back wakes the board immediately instead of the board discovering it on a poll
several minutes later.

    Monitor(command="~/.foreman/install/skills/board/watch-agents.py",
            persistent=True, description="board agents finishing")

TWO RULES MAKE THIS SAFE.

**It never reports the tick agent.** `foreman/<instance>/tick` runs the loop
itself, so its turn ending is the board finishing work, not work arriving.
Emitting that would wake the loop with news of itself and spin forever. Any
name that is not `foreman/<instance>/<TICKET>/<role>-<attempt>` for THIS
instance is ignored for the same reason -- including another instance's
agents, which would otherwise wake this one on work that is not its own.

**It emits transitions, not states.** A line is written when an agent moves from
working into a finished phase — once, on the edge. Re-reporting a finished agent
every poll would wake the board continuously for work it already handled.

The first poll seeds state silently. Without that, arming the monitor would
immediately emit one line per already-finished agent — a burst of wakeups about
work that is long done.

Failure is an event too: an agent that is killed or dies reaches `stopped`
without ever reaching `done`, and that is exactly when the board most needs to
look. Silence must never be the only thing a dead agent produces.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

POLL_SECONDS = int(os.environ.get("WATCH_POLL_SECONDS", "15"))

# INSTANCE, reused from reconcile.py's own `_load_config` rather than a second
# reader shelling out to config.sh on its own -- two readers of the same
# setting is exactly the drift `_load_config`'s docstring warns about, and this
# process already needs reconcile.py's other machinery for nothing here, so
# there is no cost to sharing its one subprocess call instead of paying for a
# second.
_SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
if _SKILL_DIR not in sys.path:
    sys.path.insert(0, _SKILL_DIR)
import reconcile  # noqa: E402

INSTANCE = reconcile.INSTANCE

# foreman/<instance>/<TICKET>/<role>-<attempt>. The tick is foreman/<instance>/tick,
# which has no fourth segment and therefore never matches.
#
# The team-key half of TICKET is `[A-Z0-9]+`, not `[A-Z]+`: nothing in this
# codebase constrains a Linear team key to letters only -- bin/contract.py
# takes `linear.team` as an arbitrary non-empty string, bin/resolve-ids.py
# resolves it by name with no charset check, and reconcile.py's own
# agents_for() matches agents by plain prefix, not a regex, so it was never
# the thing enforcing "letters only". A team key containing a digit (Linear
# allows them) still dispatches and still shows up in `claude agents`, but
# silently never matched DISPATCHED before this -- this Monitor then never
# reported that instance's agents finishing, and the board fell back to
# discovering the work on its next ordinary poll instead of waking
# immediately. No error, no crash: just a slower board on any instance whose
# team key happens to have a digit in it.
# The roles here are dispatch.sh's roles, and adding one there without adding
# it here costs no error at all: the agent runs, finishes, and this Monitor
# stays silent, so the board discovers the work on its next ordinary poll
# instead of waking immediately.
DISPATCHED = re.compile(r"^foreman/([^/]+)/([A-Z0-9]+-\d+)/(plan|build|review)-(\w+)$")

# Phases that mean "this agent is no longer working". `done` is a completed turn;
# `stopped` covers both a deliberate stop and a death.
FINISHED = {"done", "stopped"}


def _dispatched(name: str) -> tuple[str, str, str] | None:
    """(ticket, role, attempt) if `name` is a plan/build/review agent dispatched
    by THIS instance, else None.

    A capture group on the instance segment is not enough on its own -- it
    would still let one instance's Monitor wake on another instance's agents.
    This is what actually compares the captured instance against INSTANCE and
    skips everything that does not match.
    """
    m = DISPATCHED.match(name)
    if not m or m.group(1) != INSTANCE:
        return None
    return m.group(2), m.group(3), m.group(4)


def poll() -> dict[str, str]:
    try:
        out = subprocess.run(
            ["claude", "agents", "--json", "--all"],
            capture_output=True, text=True, timeout=30,
        )
        agents = json.loads(out.stdout or "[]")
    except Exception:
        # A transient failure must not kill the watch. The board's own heartbeat
        # is the backstop for anything missed while this is blind.
        return {}
    # `--bg --resume` forks: the new session inherits the name, so several rows
    # legitimately share one and only the newest is live. Taking the last row in
    # registry order read whichever the API happened to list last — dispatch.sh
    # and reconcile.py both sort by startedAt for exactly this reason, and this
    # was the one place that did not.
    newest: dict[str, dict] = {}
    for a in agents:
        if not isinstance(a, dict):
            continue
        name = a.get("name") or ""
        if _dispatched(name) is None:
            continue
        prev = newest.get(name)
        if prev is None or (a.get("startedAt") or 0) >= (prev.get("startedAt") or 0):
            newest[name] = a
    return {n: (a.get("state") or "unknown") for n, a in newest.items()}


def main() -> int:
    seen = poll()          # seed silently
    while True:
        time.sleep(POLL_SECONDS)
        now = poll()
        if not now:
            continue
        for name, state in sorted(now.items()):
            was = seen.get(name)
            if state in FINISHED and was not in FINISHED:
                ticket, _, _ = _dispatched(name)
                print(f"{name} finished ({state}) — {ticket} has work for the board",
                      flush=True)
        # Replace, do not merge. `seen = {**seen, **now}` remembered every name
        # forever, so an agent that left the registry and came back already
        # `done` compared against its own stale `done` and emitted nothing — a
        # swallowed wakeup for a re-dispatched agent, which is the one event this
        # exists to deliver.
        #
        # The tradeoff is deliberate. Replacing can emit a duplicate if a name
        # blinks out of one poll and returns finished; that costs one extra tick,
        # which is nothing. A swallowed wakeup costs the whole heartbeat interval
        # and looks like the board ignoring finished work. An empty poll is
        # skipped above, so a transient failure to read the registry does not
        # clear this.
        seen = now
    return 0


if __name__ == "__main__":
    sys.exit(main())
