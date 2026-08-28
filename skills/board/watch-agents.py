#!/usr/bin/env python3
"""Emit one line whenever a dispatched board agent finishes. Never exits.

Intended as the command behind a persistent Monitor, so that an agent coming
back wakes the board immediately instead of the board discovering it on a poll
several minutes later.

    Monitor(command="~/.claude/skills/board/watch-agents.py",
            persistent=True, description="board agents finishing")

TWO RULES MAKE THIS SAFE.

**It never reports the tick agent.** `board/tick` runs `/board` itself, so its
turn ending is the board finishing work, not work arriving. Emitting that would
wake the loop with news of itself and spin forever. Any name that is not
`board/<TICKET>/<role>-<attempt>` is ignored for the same reason.

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

# board/<TICKET>/<role>-<attempt>. The tick agent is board/tick, which has no
# third segment and therefore never matches.
DISPATCHED = re.compile(r"^board/([A-Z]+-\d+)/(build|review)-(\w+)$")

# Phases that mean "this agent is no longer working". `done` is a completed turn;
# `stopped` covers both a deliberate stop and a death.
FINISHED = {"done", "stopped"}


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
        if not DISPATCHED.match(name):
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
                ticket = DISPATCHED.match(name).group(1)
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
