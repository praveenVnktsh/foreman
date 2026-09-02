#!/usr/bin/env python3
"""Order one board's Todo candidates for dispatch, most urgent first.

    queue.py < todo.json

Reads a JSON list of Linear issues on stdin -- whole issues, as the tick already
has them from Linear MCP. Each item needs an "identifier" ("ABC-7") and a
"priority"; every other key is ignored, because Linear keeps adding fields and
the tick pipes issues through untouched. Prints one identifier per line on
stdout and nothing else. An empty list prints nothing and exits 0.

This exists so the tick stops judging urgency by eye. Linear already carries a
priority on every card, and until this file the board never read it.

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

Anything this tool cannot make sense of is refused rather than degraded, in
bin/boards.py's voice. A confident order built on a field the tick forgot to ask
for is worse than no order at all, because nothing downstream would say so.
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

# A Linear identifier: a team key, a hyphen, a number. The team key admits no
# hyphen, so the number is everything after the one hyphen.
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")

EXPECTED_PRIORITY = (
    "expected an integer 0..4, or one of "
    + ", ".join(repr(name) for name in NAME_PRIORITIES)
)


def die(message: str) -> NoReturn:
    sys.stderr.write(f"queue: {message}\n")
    raise SystemExit(1)


def band(value: object, identifier: str) -> int:
    """The sort band for one card's priority, in either representation.

    The tick may hand over the integer or the name Linear shows, depending on
    which Linear MCP call produced the issue, so both are accepted here rather
    than normalised by every caller.
    """
    if value is None:
        # Missing and null are the same failure and refuse together. Reading
        # either as 0 would hand back a confident order that ignores every
        # priority on the board, and exit 0 while doing it.
        die(f"{identifier}: priority is missing or null; {EXPECTED_PRIORITY}")
    if isinstance(value, bool):
        # `True` is an int in Python, so a priority of true would otherwise
        # read as 1 -- Urgent. bin/boards.py refuses a boolean priority for
        # this same reason.
        die(f"{identifier}: priority must not be a boolean; {EXPECTED_PRIORITY}")
    if isinstance(value, int):
        if value not in PRIORITY_BANDS:
            die(f"{identifier}: priority {value} is outside Linear's scale; {EXPECTED_PRIORITY}")
        return PRIORITY_BANDS[value]
    if isinstance(value, str):
        name = value.strip().lower()
        if name not in NAME_PRIORITIES:
            die(f"{identifier}: priority {value!r} is not a priority name; {EXPECTED_PRIORITY}")
        return PRIORITY_BANDS[NAME_PRIORITIES[name]]
    die(f"{identifier}: priority must be a number or a name; {EXPECTED_PRIORITY}")


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
        # Linear numbers increase with age, so the LOWER number is the older
        # card and wins its band. Without this, a stream of equal-priority
        # newcomers starves a card that has already waited.
        number = int(identifier.rsplit("-", 1)[1])
        keys.append((band(item.get("priority"), identifier), number, identifier))

    # The identifier is the final tiebreak, so the order is total: the same
    # input always prints the same lines, whatever order Linear returned.
    for _, _, identifier in sorted(keys):
        sys.stdout.write(f"{identifier}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
