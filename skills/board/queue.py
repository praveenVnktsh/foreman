#!/usr/bin/env python3
"""Order one board's Todo candidates for dispatch, most urgent first.

    queue.py < todo.json

Reads a JSON list of Linear issues on stdin -- whole issues, as the tick already
has them from Linear MCP. Each item needs an "identifier" ("ABC-7") and a
"priority"; every other key is ignored, because Linear keeps adding fields and
the tick pipes issues through untouched.

    stdout  one identifier per line, most urgent first, and nothing else.
    stderr  one line per card that could not be ranked, and one line for the
            whole batch when it is refused or ranks nothing.
    exit 0  stdin was read and an order was computed from every card that could
            be ranked. An empty list is a board with no work: it prints nothing
            on stdout and exits 0.
    exit 1  the batch is refused and there is no order at all. stdout is empty.
    exit 2  cards came in and not one of them could be ranked. stdout is empty,
            and every skipped card is named on stderr.

This exists so the tick stops judging urgency by eye. Linear already carries a
priority on every card, and until this file the board never read it.

One card's unreadable priority costs that card and nothing else. A board that
never dispatches looks exactly like a board with no work, so a single untriaged
card used to stall every Urgent card behind it, in silence. The refusal moved
from the batch to the card; it was not softened. A skipped card is still
refused, out loud on stderr, and the tick reports it to the operator who sets
the priority in Linear. It is never ranked at a default: a confident order built
on a priority nobody set is worse than a short one, because nothing downstream
would say so.

A batch that ranks nothing exits 2, not 0. The refusal still stops at the card,
one card at a time. But an empty stdout with exit 0 is byte-for-byte what an idle
board prints, so a tick that cannot tell a stalled board from an idle one does
not report the stall, and nobody sets the priority. That is the same silence, one
level up. An empty input list is the one case that stays exit 0: no cards came
in, so there is nothing to stall.

A card can only be skipped if it can be named, and the identifier is how a
report names it. So a missing or malformed identifier still refuses the whole
batch, as do stdin that is not a JSON list, an item that is not a JSON object,
one identifier listed twice, and the wrong argv.

The `priority` here is Linear's per-CARD scale. It is NOT the `priority` key in
~/.foreman/boards.toml, which weighs how much of the machine a whole board may
hold and where a HIGHER number means more. The two numbers point opposite ways,
so never read one as the other.

bin/boards.py emits NUL-separated fields because a path can hold anything,
including a newline. This tool validates every identifier against a pattern that
admits no whitespace, so one per line is unambiguous and the caller needs no
`tr`.

The concurrency ceilings live in dispatch.sh because prose is not a gate, and
this file exists for the same reason. It cannot live in dispatch.sh: that script
is handed one ticket and never sees the cards it beat, so an order can only be
computed where the candidates are.
"""

from __future__ import annotations

import json
import re
import sys
from typing import NoReturn

# Linear's scale: 0 = No priority, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low.
NAME_PRIORITIES = {
    "no priority": 0,
    "urgent": 1,
    "high": 2,
    "medium": 3,
    "low": 4,
}

# Priority to sort band. Lower is more urgent EXCEPT for 0, which does not mean
# "most urgent" but "nobody has triaged this card yet" -- so 0 sorts LAST, at
# band 5.
#
# Do not delete this table as redundant with a plain ascending sort on the raw
# priority. That naive sort is the failure this file exists to prevent: it puts
# every untriaged card ahead of every Urgent one, and a board whose backlog is
# mostly untriaged then dispatches its least understood work first.
PRIORITY_BANDS = {0: 5, 1: 1, 2: 2, 3: 3, 4: 4}

# Exit status for a batch that came in with cards and ranked none of them. It is
# not 1: stdin was read and every card was reported, so this is a stalled board
# and not a refused input.
NOTHING_RANKED = 2

# A Linear identifier: a team key, a hyphen, a number. The team key admits no
# hyphen, so the number is everything after the one hyphen.
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")

EXPECTED_PRIORITY = (
    "expected an integer 0..4, or one of "
    + ", ".join(repr(name) for name in NAME_PRIORITIES)
)


class Unrankable(Exception):
    """One card's priority cannot be read, so that card cannot be ordered.

    The message says what was wrong and what was expected. It costs the card its
    place in the order and costs the batch nothing.
    """


def die(message: str) -> NoReturn:
    sys.stderr.write(f"queue: {message}\n")
    raise SystemExit(1)


def report_skip(identifier: str, reason: str) -> None:
    """Tell the operator on stderr that one card was left out of the order.

    stdout carries the order alone, so a tick that reads stdout can never
    mistake a skipped card for a dispatchable one.
    """
    sys.stderr.write(f"queue: skipped {identifier}: {reason}\n")


def band(value: object) -> int:
    """The sort band for one card's priority, in any representation Linear uses.

    The tick may hand over the integer, the float or the name, depending on
    which Linear MCP call produced the issue, so all three are accepted here
    rather than normalised by every caller.

    Raises Unrankable when the priority cannot be read. Naming the card and
    reporting the skip belong to the caller, which is the only place that knows
    the identifier.
    """
    if value is None:
        # Missing and null are the same failure. Reading either as 0 would rank
        # an untriaged card as though someone had triaged it.
        raise Unrankable(f"priority is missing or null; {EXPECTED_PRIORITY}")
    if isinstance(value, bool):
        # `True` is an int in Python, so a priority of true would otherwise
        # read as 1 -- Urgent. bin/boards.py refuses a boolean priority for
        # this same reason.
        raise Unrankable(f"priority must not be a boolean; {EXPECTED_PRIORITY}")
    if isinstance(value, float):
        # Linear's GraphQL schema types priority as a Float, so a JSON decoder
        # hands over 1.0 for a priority the operator did set. Refusing that
        # skipped Urgent cards whose priority was never in doubt.
        if not value.is_integer():
            # 2.5, NaN and Infinity all land here: is_integer() is False for
            # each, and none of them names a band.
            raise Unrankable(f"priority {value!r} is not a whole number; {EXPECTED_PRIORITY}")
        value = int(value)
    if isinstance(value, int):
        if value not in PRIORITY_BANDS:
            raise Unrankable(f"priority {value} is outside Linear's scale; {EXPECTED_PRIORITY}")
        return PRIORITY_BANDS[value]
    if isinstance(value, str):
        name = value.strip().lower()
        if name not in NAME_PRIORITIES:
            raise Unrankable(f"priority {value!r} is not a priority name; {EXPECTED_PRIORITY}")
        return PRIORITY_BANDS[NAME_PRIORITIES[name]]
    raise Unrankable(
        f"priority must be a number or a name, not {type(value).__name__}; {EXPECTED_PRIORITY}"
    )


def identifier_of(item: object) -> str:
    """The validated identifier of one issue."""
    if not isinstance(item, dict):
        die(f"every item must be a JSON object with an identifier and a priority, not {item!r}")

    identifier = item.get("identifier")
    if not isinstance(identifier, str) or not IDENTIFIER.match(identifier):
        die(f"invalid identifier {identifier!r}; expected a team key, a hyphen and a number "
            "(for example ABC-7)")
    return identifier


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        die("usage: queue.py < todo.json")

    try:
        issues = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        die(f"stdin is not valid JSON: {exc}")

    if not isinstance(issues, list):
        die(f"expected a JSON list of issues, got {type(issues).__name__}")

    seen: set[str] = set()
    keys = []
    for item in issues:
        identifier = identifier_of(item)
        if identifier in seen:
            # Two cards under one identifier make the order depend on which
            # copy the sort kept, and the board would dispatch one of them
            # twice while never reaching the other.
            die(f"{identifier}: appears twice; every card must be listed once")
        seen.add(identifier)
        try:
            rank = band(item.get("priority"))
        except Unrankable as exc:
            report_skip(identifier, str(exc))
            continue
        # Linear numbers increase with age, so the LOWER number is the older
        # card and wins its band. Without this, a stream of equal-priority
        # newcomers starves a card that has already waited.
        number = int(identifier.rsplit("-", 1)[1])
        keys.append((rank, number, identifier))

    if issues and not keys:
        # An empty stdout with exit 0 is exactly what an idle board prints, so a
        # tick that cannot tell the two apart never reports the stall and nobody
        # sets the priority. That is the silence PRA-197 removed per card,
        # reappearing for the whole batch.
        sys.stderr.write(
            "queue: nothing was ranked: every card's priority was unreadable. "
            "Each one is named above. Set their priority in Linear.\n"
        )
        return NOTHING_RANKED

    # The identifier is the final tiebreak, so the order is total: the same
    # input always prints the same lines, whatever order Linear returned.
    for _, _, identifier in sorted(keys):
        sys.stdout.write(f"{identifier}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
