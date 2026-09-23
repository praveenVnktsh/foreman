#!/usr/bin/env python3
"""Emit one line whenever a dispatched board agent finishes. Never exits.

Intended as the command behind a persistent Monitor, so that an agent coming
back wakes the board immediately instead of the board discovering it on a poll
several minutes later.

    Monitor(command="~/.foreman/install/skills/board/watch-agents.py",
            persistent=True, timeout_ms=1800000,
            description="board agents finishing")

`timeout_ms` is required even when `persistent` is true, and `persistent`
itself exists only up to Claude Code 2.1.228 -- 2.1.275 removed it. SKILL.md
carries the version note; this is the copy a reader of this file sees.

TWO RULES MAKE THIS SAFE.

**It never reports the tick agent.** `foreman/<installation>/tick` (or
`foreman/tick` on the legacy installation) runs the loop itself, so its turn
ending is the board finishing work, not work arriving. Emitting that would wake
the loop with news of itself and spin forever. Any name that is not
`<BOARD_NAME_PREFIX>/<TICKET>/<role>-<attempt>` for THIS board is ignored for
the same reason -- including another board's agents, which would otherwise
wake this one on work that is not its own.

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

# INSTANCE, INSTALLATION and HARNESS_SH, reused from reconcile.py's own
# `_load_config` rather than a second reader shelling out to config.sh on its
# own -- two readers of the same setting is exactly the drift `_load_config`'s
# docstring warns about, and this process already imports reconcile.py, so
# there is no cost to sharing its one subprocess call instead of paying for a
# second.
#
# This file used to source config.sh a second time, in another `bash -c`, for
# the two values reconcile.py had already exported at module scope. That cost
# every arm of this Monitor a second shell and left two places that could
# disagree about which installation this process watches.
_SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
if _SKILL_DIR not in sys.path:
    sys.path.insert(0, _SKILL_DIR)
import reconcile  # noqa: E402

HARNESS_SH = reconcile.HARNESS_SH
# `foreman/<installation>/<instance>` or, on the legacy installation,
# `foreman/<instance>` -- config.sh decides which, and this process only reads
# it. See _dispatched() for how a captured name is held against it.
BOARD_NAME_PREFIX = reconcile.BOARD_NAME_PREFIX

# PROOF THAT A MONITOR IS ARMED. This process runs only while one is alive, so
# its own execution is the fact worth recording. The tick cannot report this:
# asked whether it armed a Monitor it reports intent, and a call rejected by a
# newer harness reports armed just as readily. The harness cannot report it
# either -- a Monitor lives inside the session and nothing persists it.
#
# Read by reconcile.py --monitor-stamps, and through it by dispatch.sh,
# supervise.sh and bin/dashboard.py. The mtime is what those read; the first
# line is for a human who opens the file, and the `poll=` line is the one fact
# a reader cannot get any other way -- see stamp().
STAMP_PATH = os.path.join(reconcile.BOARD_HOME, "monitor.stamp")


def stamp() -> None:
    """Refresh STAMP_PATH. Called on every poll, including the seeding one.

    WRITTEN VIA A TEMPORARY AND RENAMED, so a reader never sees a half-written
    file and mistakes a truncated stamp for a corrupt one. os.replace is atomic
    within a directory.

    A FAILURE HERE IS SWALLOWED, and that is not the same as ignored. The watch
    must keep emitting: its wakeups are useful even when the stamp is not
    writable. The gates then halt foreman on the stale stamp, which is the
    correct outcome -- a board whose runtime directory cannot be written is not
    a board that should be dispatching.
    """
    try:
        tmp = f"{STAMP_PATH}.tmp"
        with open(tmp, "w") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
            # THE POLL TRAVELS WITH THE STAMP, because nothing else carries it
            # between these two processes. This one reads WATCH_POLL_SECONDS
            # from the tick session's environment; config.sh derives the
            # staleness window from whatever environment ITS reader has, and
            # supervise.sh's is cron's -- no profile, no exports. An operator
            # who set WATCH_POLL_SECONDS=60 in a shell profile therefore got a
            # watcher stamping every 60s and a supervisor demanding one every
            # 60s: a permanent halt of a healthy machine. Written here, the
            # window is derived from the value actually in use.
            fh.write(f"poll={POLL_SECONDS}\n")
        os.replace(tmp, STAMP_PATH)
    except OSError:
        pass


# foreman/[<installation>/]<instance>/<TICKET>/<role>-<attempt>. The
# installation segment is optional because the legacy installation's names
# have none. The tick is foreman/[<installation>/]tick, which has no ticket
# segment and therefore never matches.
#
# The optional group cannot misread one shape as the other: a TICKET needs an
# uppercase key, a hyphen and digits, and a board or installation name may hold
# no hyphen at all, so the segment count alone decides which group is empty.
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
#
# The literal `cleanup` ticket segment is the same kind of agreement. A
# scheduled cleanup run has no card to name until it files one, so its agent
# is foreman/[<installation>/]<instance>/cleanup/cleanup-<attempt> -- the
# ticket alternative and the role both have to spell that literal, and
# dispatch.sh has to keep spelling it the same way, or a live cleanup agent
# finishes silently and this Monitor never wakes the board for it.
DISPATCHED = re.compile(
    r"^foreman/(?:([^/]+)/)?([^/]+)/([A-Z0-9]+-\d+|cleanup)/(plan|build|review|cleanup)-(\w+)$"
)

# Phases that mean "this agent is no longer working". `done` is a completed turn;
# `stopped` covers both a deliberate stop and a death.
FINISHED = {"done", "stopped"}


def _dispatched(name: str) -> tuple[str, str, str] | None:
    """(ticket, role, attempt) if `name` is a plan/build/review agent dispatched
    by THIS board, else None.

    A capture group on the board segment is not enough on its own -- two
    boards can share one repository, so a name with the right ticket but the
    wrong board still names somebody else's agent. This compares the captured
    prefix against this process's own BOARD_NAME_PREFIX and skips everything
    that does not match it.
    """
    m = DISPATCHED.match(name)
    if not m:
        return None
    installation, instance = m.group(1), m.group(2)
    owner = f"foreman/{instance}" if installation is None else f"foreman/{installation}/{instance}"
    if owner != BOARD_NAME_PREFIX:
        return None
    return m.group(3), m.group(4), m.group(5)


def poll() -> dict[str, str]:
    try:
        out = subprocess.run(
            [HARNESS_SH, "list"],
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
    stamp()
    seen = poll()          # seed silently
    while True:
        time.sleep(POLL_SECONDS)
        # BEFORE the poll and BEFORE the empty-poll skip below, for two
        # reasons. A board with no dispatched agents polls empty and `continue`s
        # -- stamping after that would read an idle board as an unarmed one and
        # stop the machine. And a registry read that hangs takes up to its own
        # 30s timeout, so stamping first bounds the gap between stamps at
        # WATCH_POLL_SECONDS + 30 = 45s, inside MONITOR_STALE_SECONDS of 60.
        stamp()
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
