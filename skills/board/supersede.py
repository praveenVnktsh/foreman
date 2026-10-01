#!/usr/bin/env python3
"""Which of one board's finished agents can be settled while their card is live?

    "$HARNESS_SH" list | supersede.py --prefix <BOARD_NAME_PREFIX>/ \\
        --in-flight [TICKET ...]

THE FAILURE. A background agent does not exit when its turn ends. It idles at
state `done` with its pid and about 300 MB of memory (see PHASE in
reconcile.py). `sweep.sh` settled a card's sessions only once the card was
terminal, so every earlier role on a live card kept its process for the card's
whole life. Measured 2026-09-30 on a 16 GB machine: 19 background agents held
3.2 GB. Six were finished turns on cards still in flight or long merged.
Stopping those six freed 1.3 GB.

This file decides; `sweep.sh --settle` acts. It reads the registry on stdin and
the in-flight tickets from argv, runs nothing and reads no environment.

    stdout  one line per settleable row, fields separated by \\x1f (sweep.sh's
            FIELD_SEP):
              <action> <id> <name>
            action is one of:
              stop    the row is idle: stop it. Once it has exited, a later
                      pass reads it as exited and says forget or keep.
              forget  the row has exited and nothing will resume it.
              keep    a later build round may resume the row, so it is
                      neither stopped nor forgotten.
                      Printed so the sweep can say why the row stays.
    stderr  one line per card left alone because a row of it is unreadable.
    exit 0  the registry was read. An empty stdout means nothing to settle.
    exit 2  the call was wrong: bad argv, or a prefix with no trailing slash.
    exit 3  stdin is not a JSON list. stdout is empty. The sweep must never read
            that as "no rows", or a broken registry reads as a clean board.

WHICH ROWS. Only a row whose name is `<prefix><ticket>/<role>-<attempt><slot>`,
with role `plan`, `build` or `review`, digits for the attempt, and an optional
lowercase slot letter. The tick, the scheduled cleanup, `cleanup` roles, other
boards and anything that does not parse are never printed.

A row is SETTLEABLE when it is idle or exited, and either:

- SUPERSEDED: its card is in flight, and a newer row of the same card has the
  same name (a newer fork) or a different role or attempt; or
- ITS CARD IS GONE: the ticket is not in flight (Done, Canceled, Needs Human,
  archived, ...).

A working row is never settleable, and neither is a pid in any other state.

A SIBLING REVIEW SLOT IS NOT A SUPERSESSION. `review-1a` and `review-1b` are
two reviewers of one round, started seconds apart. Neither replaces the other,
and the round is not over until both have answered. Reading the later slot as
newer work would stop the earlier reviewer before the board had read it.

THE RESUME RULE THIS PROTECTS. `harness/claude.sh resume` needs the registry
ROW, not the process. It resumes the newest row with the agent's name through
that row's sessionId. A stopped row keeps its sessionId, so a stopped agent is
still resumable. A forgotten row is gone, and resume dies "no agent named N to
resume". Build rounds (fix, ci-fix, retry, rebuild) resume the build agent
under the same name. So a build row is RESUMABLE when it is the newest row with
its name and no build row of its card has a higher attempt: it is never
forgotten, and never stopped either, whether or not its card is in flight. Its
unstopped row is what keeps `sweep.sh --orphans` off the worktree that round
resumes into, and a card out of flight is not necessarily finished: one in
Needs Human or Canceled waits for a person, who may send it back, and SKILL.md
never sweeps it. Ticket mode stops the build once its card is truly over.
Every other settleable row is forgettable:

- an older fork: `--bg --resume` forks a new row under the same name, and the
  older one is never resumed again;
- a superseded plan: plan rounds resume only while the card is in Plan, before
  any build, and a plan is superseded only by a later role, a later plan
  attempt or a newer fork of itself;
- a review: no round ever resumes one.

Transcripts are not this file's business. Every session in a worktree shares
one transcript directory, so the sweep's settle mode must never remove one.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass

# The rest of an agent name after the board prefix. The roles are the ones a
# card's rounds run; `cleanup` is its own flow and is left out on purpose.
AGENT_NAME = re.compile(
    r"^(?P<ticket>[^/]+)/(?P<role>plan|build|review)-(?P<attempt>[0-9]+)(?P<slot>[a-z]?)$")

# The only role a later round resumes on a card that has left Plan.
RESUMED_ROLE = "build"

# The classes sweep.sh's card_sessions prints, by the same rule.
EXITED, IDLE, OTHER = "exited", "idle", "other"
IDLE_STATES = ("done", "blocked")

STOP, FORGET, KEEP = "stop", "forget", "keep"

FIELD_SEP = "\x1f"

UNREADABLE_REGISTRY = 3


class UnreadableRow(Exception):
    """One row of the board is unreadable, so its card is left alone this pass."""

    def __init__(self, ticket: str, reason: str):
        super().__init__(reason)
        self.ticket = ticket


@dataclass(frozen=True)
class Row:
    id: str
    name: str
    ticket: str
    role: str
    attempt: int
    started: float
    kind: str

    @property
    def round(self) -> tuple[str, int]:
        """The role and attempt. Sibling slots of one review share it."""
        return self.role, self.attempt

    def line(self, action: str) -> str:
        return FIELD_SEP.join([action, self.id, self.name])


# --- parsing at the edge ---------------------------------------------------


def kind_of(pid: object, state: object) -> str:
    if pid is None and state != "working":
        return EXITED
    if pid is not None and state in IDLE_STATES:
        return IDLE
    return OTHER


def parse_row(agent: object, prefix: str) -> Row | None:
    """One registry row, or None when it is not a card agent of this board.

    Raises UnreadableRow for a row of this board whose fields cannot be trusted.
    A missing startedAt is not read as 0: that would make the row the oldest on
    its card, and so the first one stopped.
    """
    if not isinstance(agent, dict):
        return None
    name = agent.get("name")
    if not isinstance(name, str) or not name.startswith(prefix):
        return None
    match = AGENT_NAME.match(name[len(prefix):])
    if match is None:
        return None
    ticket = match["ticket"]
    started = agent.get("startedAt")
    if (isinstance(started, bool) or not isinstance(started, (int, float))
            or not math.isfinite(started)):
        raise UnreadableRow(ticket, f"{name}: startedAt is {started!r}, not epoch milliseconds")
    row_id = agent.get("id")
    if not isinstance(row_id, str) or not row_id:
        raise UnreadableRow(ticket, f"{name}: id is {row_id!r}, not an agent id")
    pid, state = agent.get("pid"), agent.get("state")
    if pid is not None and (isinstance(pid, bool) or not isinstance(pid, int)):
        raise UnreadableRow(ticket, f"{name}: pid is {pid!r}, not an integer or null")
    if state is not None and not isinstance(state, str):
        raise UnreadableRow(ticket, f"{name}: state is {state!r}, not a string or null")
    return Row(id=row_id, name=name, ticket=ticket, role=match["role"],
               attempt=int(match["attempt"]), started=started,
               kind=kind_of(pid, state))


def rows_by_card(agents: list, prefix: str) -> dict[str, list[Row]]:
    """This board's card agents, by ticket. A card with an unreadable row is dropped."""
    cards: dict[str, list[Row]] = {}
    unreadable: dict[str, str] = {}
    for agent in agents:
        try:
            row = parse_row(agent, prefix)
        except UnreadableRow as exc:
            unreadable.setdefault(exc.ticket, str(exc))
            continue
        if row is not None:
            cards.setdefault(row.ticket, []).append(row)
    for ticket, reason in sorted(unreadable.items()):
        # The whole card, not the row: a row this cannot read might be the
        # newer one that supersedes, or the fork that makes another resumable.
        sys.stderr.write(f"supersede: leaving {ticket} alone: {reason}\n")
        cards.pop(ticket, None)
    return cards


# --- the pure core ---------------------------------------------------------


def superseded(row: Row, card: list[Row]) -> bool:
    return any(other.started > row.started
               and (other.name == row.name or other.round != row.round)
               for other in card)


def resumable(row: Row, card: list[Row]) -> bool:
    if row.role != RESUMED_ROLE:
        return False
    newest_of_name = not any(other.name == row.name and other.started > row.started
                             for other in card)
    latest_attempt = not any(other.role == RESUMED_ROLE and other.attempt > row.attempt
                             for other in card)
    return newest_of_name and latest_attempt


def action_for(row: Row, card: list[Row]) -> str:
    # A resumable build is never stopped, in flight or not. A stopped row no
    # longer protects its cwd from `sweep.sh --orphans` (live_worktrees spares
    # anything not `stopped`), so the card's worktree and branch would go on
    # the next orphan pass -- including a Needs Human card's, which SKILL.md
    # leaves for a person -- and the round that resumes into it would find none.
    if resumable(row, card):
        return KEEP
    return STOP if row.kind == IDLE else FORGET


def settle(cards: dict[str, list[Row]], in_flight: set[str]) -> list[str]:
    lines = []
    for ticket in sorted(cards):
        card = cards[ticket]
        live = ticket in in_flight
        for row in sorted(card, key=lambda r: (r.started, r.name, r.id)):
            if row.kind == OTHER:
                continue
            if live and not superseded(row, card):
                continue
            lines.append(row.line(action_for(row, card)))
    return lines


# --- the command -----------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="supersede.py",
        description="Name the finished agents of one board that can be settled.")
    parser.add_argument("--prefix", required=True,
                        help="the board's agent name prefix, with its trailing slash")
    # Required, and allowed to be empty. Leaving the flag out cannot mean
    # "nothing is in flight": that reads every live card as gone, and a caller
    # that failed to read Linear would settle the whole board.
    parser.add_argument("--in-flight", nargs="*", action="extend", required=True,
                        metavar="TICKET", help="the tickets in Plan, In Progress or In Review")
    args = parser.parse_args(argv)
    # The trailing slash is load-bearing, as in reconcile.py's agents_for: a
    # bare "foreman/alpha" also matches every agent of a board "alpha2".
    if not args.prefix.endswith("/"):
        parser.error(f"--prefix {args.prefix!r} must end with '/'")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        agents = json.load(sys.stdin)
    except ValueError as exc:
        sys.stderr.write(f"supersede: the registry is not valid JSON: {exc}\n")
        return UNREADABLE_REGISTRY
    if not isinstance(agents, list):
        sys.stderr.write(f"supersede: expected the registry as a JSON list, "
                         f"got {type(agents).__name__}\n")
        return UNREADABLE_REGISTRY
    for line in settle(rows_by_card(agents, args.prefix), set(args.in_flight)):
        sys.stdout.write(f"{line}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
