#!/usr/bin/env python3
"""Route one board's Todo candidates to this installation, then rank them.

    queue.py --installation NAME [--default] --siblings a,b,c < todo.json

Reads a JSON list of Linear issues on stdin -- whole issues, as the tick already
has them from Linear MCP. Each item needs an "identifier" ("ABC-7") and a
"priority"; every other key is ignored, because Linear keeps adding fields and
the tick pipes issues through untouched.

`--installation`, `--default` and `--siblings` are the three arguments
route.py's `verdict()` takes, and they mean what its docstring says they mean:
`--siblings` is every installation on this machine, from `installation.py
--siblings`; `--default` says this installation also owns every unlabelled
card. All three are REQUIRED. A bare `queue.py < todo.json` refuses: on a
machine with more than one installation, ranking every card on the board --
including a sibling's -- is the double-dispatch this change exists to prevent,
and there is no backward-compatible default that does not risk it. A lone
installation still passes its own name and `--default --siblings <itself>`;
`installation.py` prints exactly that for an un-migrated home.

    stdout  one identifier per line, most urgent first, and nothing else.
    stderr  one line per card dropped before ranking (not this installation's,
            or unroutable) and one line per card skipped during ranking (its
            priority could not be read), plus one line for the whole batch
            when it is refused or ranks nothing.
    exit 0  stdin was read and an order was computed from every card this
            installation owns and could rank. An empty list, and a batch where
            every card belongs to a sibling, both print nothing on stdout and
            exit 0: an idle board and a board that is entirely someone else's
            both look like no work here, and are.
    exit 1  the batch is refused and there is no order at all. stdout is empty.
    exit 2  the tool was called wrong: a missing flag, an --installation that
            is not among --siblings, or extra arguments. stdout is empty.
    exit 3  NOTHING was ranked, and at least one card in the batch was this
            installation's problem: an owned card whose priority could not be
            read, or a card whose label names no sibling. stdout is empty, and
            every dropped or skipped card is named on stderr. A card dropped
            only because a sibling owns it does not, by itself, trigger this:
            that card was never this installation's to rank.

Exit 3 means "nothing ranked", and nothing else. A batch holding one rankable
card and one card whose label names no sibling exits 0, prints the order on
stdout and names the unroutable card on stderr. Exit 3 promises an empty
stdout, so reporting the unroutable card through the exit code would have to
throw away an order the tick can act on -- and a tick handed an order with a
non-zero exit cannot tell whether it may dispatch from it. The unroutable card
is not lost by that: it is named on stderr on EVERY run, and SKILL.md tells the
tick to name every dropped and skipped card in its report, which is where an
operator reads it and fixes the label in Linear.

This exists so the tick stops judging urgency by eye, and stops ranking cards
that belong to another installation on the same machine. Linear already
carries a priority on every card, and until this file the board never read it.
`route.py` exists so ownership is answered once; this file imports its
predicate and does not re-derive it.

Routing runs before ranking. A card this installation does not own is dropped
first, on route.py's verdict, and named on stderr in this file's own
one-line-per-card style -- the same shape as the unrankable-card report below,
so both read as one stream instead of two dialects. Three kinds of drop exist:

- foreign: a sibling owns it. Nothing is wrong, and it costs this batch
  nothing towards exit 3 -- a board that is mostly a sibling's work is not a
  stalled board here.
- unroutable: the label names no sibling. The operator has to fix this in
  Linear, so it is named on stderr on every run, and it counts toward exit 3
  exactly like an unrankable card when nothing else ranks: silence here is a
  card that sits in Todo forever with no tick that claims it.
- ambiguous: two `foreman:*` labels. Same treatment as unroutable, for the
  same reason -- guessing between them is how a card gets dispatched twice.

One card's unreadable priority, among the ones this installation does own,
still costs that card and nothing else. A board that never dispatches looks
exactly like a board with no work, so a single untriaged card used to stall
every Urgent card behind it, in silence. The refusal moved from the batch to
the card; it was not softened. A skipped card is still refused, out loud on
stderr, and the tick reports it to the operator who sets the priority in
Linear. It is never ranked at a default: a confident order built on a
priority nobody set is worse than a short one, because nothing downstream
would say so.

A batch where this installation owns cards and ranks none of them exits 3, not
0. The refusal still stops at the card, one card at a time. But an empty
stdout with exit 0 is byte-for-byte what an idle board -- or a board that is
entirely a sibling's -- prints, so a tick that cannot tell a stalled board from
an idle one does not report the stall, and nobody fixes it. That is the same
silence, one level up.

A card can only be dropped or skipped if it can be named, and the identifier is
how a report names it. So a missing or malformed identifier still refuses the
whole batch, as do stdin that is not a JSON list, an item that is not a JSON
object, and one identifier listed twice. This file validates the identifier
before routing, because route.py's own drop report needs it too. A wrong argv
is not a refused batch and exits 2: no batch was read at all.

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

import argparse
import json
import os
import re
import sys
from typing import NoReturn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route  # noqa: E402  (see sys.path.insert above -- sibling module)

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

# Exit status for a batch that ranked NOTHING while at least one card was this
# installation's problem -- an owned card nobody can rank, or a card whose
# label names no sibling. It is not 1: stdin was read and every card was
# reported, so this is a stalled board and not a refused input. A batch that
# ranks even one card exits 0 whatever else it reported, because stdout must
# carry an order or be empty, never both.
#
# It is 3 and not 2 because 2 already means "you called this tool wrong" across
# this board -- see the "WHY 3 AND NOT 2" paragraph at the top of waitfor.py,
# which draws the same line for the same reason. This file used to exit 2 for a
# stalled board while waitfor.py exited 2 for a usage error, so SKILL.md taught
# the tick both readings of one number, and a reader of an exit 2 from a board
# tool had to know which tool produced it before knowing what it meant. 3 is
# waitfor.py's code for settled and unsatisfied, which is what a stalled board
# is.
NOTHING_RANKED = 3

# `project` routing: this board is the installation's only board, so every card
# the tick hands over is this installation's and the label filter is skipped.
# config.sh exports ROUTING; anything other than "project" (including unset) is
# the label routing route.py implements.
ROUTING = os.environ.get("ROUTING", "label")
PROJECT_ROUTING = "project"

# Exit status for a wrong argv, which is argparse's own default and the code
# every other tool on this board uses for the same failure: a required flag
# missing, or --installation not among --siblings.
CALLED_WRONG = 2

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
    """Refuse the whole batch. The tick's read of the board is wrong."""
    sys.stderr.write(f"queue: {message}\n")
    raise SystemExit(1)


def report_skip(identifier: str, reason: str) -> None:
    """Tell the operator on stderr that one owned card was left out of ranking.

    stdout carries the order alone, so a tick that reads stdout can never
    mistake a skipped card for a dispatchable one.
    """
    sys.stderr.write(f"queue: skipped {identifier}: {reason}\n")


def report_drop(identifier: str, detail: str) -> None:
    """Tell the operator on stderr that one card was dropped before ranking.

    Same one-line-per-card shape as report_skip, so a reader of stderr sees one
    stream of "this card did not make the order" instead of two dialects for
    routing and ranking.
    """
    sys.stderr.write(f"queue: dropped {identifier}: {detail}\n")


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


def parse_args(argv: list[str]) -> argparse.Namespace:
    # Required, not defaulted: a queue.py that ranks every card when nobody
    # passes --installation is the double-dispatch this change exists to
    # prevent, on the first machine that runs more than one installation.
    p = argparse.ArgumentParser(
        prog="queue.py",
        description="Route this board's Todo candidates to one installation, then rank them.",
    )
    p.add_argument("--installation", required=True, help="this installation's name")
    p.add_argument(
        "--default",
        action="store_true",
        help="this installation also owns every unlabelled card",
    )
    p.add_argument(
        "--siblings",
        required=True,
        help="comma-separated installation names, from installation.py --siblings",
    )
    args = p.parse_args(argv)

    args.siblings = [name for name in args.siblings.split(",") if name]
    if args.installation not in args.siblings:
        # Same check route.py makes, for the same reason: a hand-composed
        # --siblings that omits --installation would call every one of this
        # installation's own cards unroutable.
        p.error(
            f"--installation {args.installation} is not among --siblings "
            f"({', '.join(args.siblings) or 'empty'})"
        )
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv[1:])

    try:
        issues = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        die(f"stdin is not valid JSON: {exc}")

    if not isinstance(issues, list):
        die(f"expected a JSON list of issues, got {type(issues).__name__}")

    seen: set[str] = set()
    keys = []
    # True once a card that IS this installation's to handle fails to make the
    # order: an owned card with an unrankable priority, or a card whose label
    # names no sibling at all. A card dropped only because a sibling owns it
    # never sets this -- that card was never this installation's problem.
    #
    # Read ONLY when nothing ranked. A batch that produced an order exits 0
    # however many cards it also reported on stderr; see NOTHING_RANKED.
    unresolved = False
    for item in issues:
        identifier = identifier_of(item)
        if identifier in seen:
            # Two cards under one identifier make the order depend on which
            # copy the sort kept, and the board would dispatch one of them
            # twice while never reaching the other.
            die(f"{identifier}: appears twice; every card must be listed once")
        seen.add(identifier)

        if ROUTING != PROJECT_ROUTING:
            try:
                verdict = route.verdict(item, args.installation, args.default, args.siblings)
            except route.LabelShape as exc:
                # Not caught by route.verdict on purpose -- see its docstring. A
                # card with unreadable labels is a shape nobody has taught this
                # module, and ranking it anyway could rank a sibling's card.
                die(f"{identifier}: {exc}")

            if not verdict.owned:
                report_drop(identifier, verdict.detail)
                if verdict.reason is not route.Reason.FOREIGN:
                    unresolved = True
                continue

        try:
            rank = band(item.get("priority"))
        except Unrankable as exc:
            report_skip(identifier, str(exc))
            unresolved = True
            continue
        # Linear numbers increase with age, so the LOWER number is the older
        # card and wins its band. Without this, a stream of equal-priority
        # newcomers starves a card that has already waited.
        number = int(identifier.rsplit("-", 1)[1])
        keys.append((rank, number, identifier))

    if not keys:
        if unresolved:
            # An empty stdout with exit 0 is exactly what an idle board -- or a
            # board that is entirely a sibling's -- prints, so a tick that
            # cannot tell those apart from a stall never reports it, and
            # nobody fixes the label or the priority in Linear.
            sys.stderr.write(
                "queue: nothing was ranked: every card this installation owns was "
                "unrankable, and/or a card's label named no sibling. Each one is "
                "named above. Fix it in Linear.\n"
            )
            return NOTHING_RANKED
        # Either no cards came in, or every one of them belongs to a sibling.
        # Both are "no work for this installation right now", not a stall.
        return 0

    # The identifier is the final tiebreak, so the order is total: the same
    # input always prints the same lines, whatever order Linear returned.
    for _, _, identifier in sorted(keys):
        sys.stdout.write(f"{identifier}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
