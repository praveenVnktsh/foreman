"""Say which installation owns a Linear card, by its `foreman:*` label.

    import route
    verdict = route.verdict(issue, installation, is_default, siblings)

A PREDICATE MODULE, NOT A PROGRAM. It is imported, never run: there is no
`main`, no argument parser and no exit code here. `queue.py` is the one caller,
and it owns the argv, the stdin, the stderr report and the exit codes. A CLI
here would be a second way to ask the same question, with its own flags to keep
in step with queue.py's -- and the copy that drifted would answer for cards the
other one had already routed.

WHY ONE PLACE. Ownership is enforced by exactly one program: `queue.py`, and
only for `Todo`. That is the column where a card is picked up, so it is the
column where taking a sibling's card dispatches the same ticket into two
worktrees and pushes both. The other three columns -- `Plan`, `In Progress`,
`In Review` -- hold cards that were already routed when they left `Todo`, and
the filter there is the tick's own, stated once in `SKILL.md` under
"1. Adopt" ("Only this installation's cards, in every one of those four
columns"). `reconcile.py` never sees a Linear listing at all: it is handed
ticket names one at a time, so there is nothing there for this module to
filter. This file exists so that the rule `queue.py` enforces is written down
once, with its reasoning, rather than inline in the ranking loop.

WHAT A LABEL MEANS. `foreman:<name>` names the installation that owns the card,
in every column. A card with no `foreman:*` label belongs to the default
installation, which is how an operator who never learned about labels keeps a
one-installation machine working. The tick makes ownership durable: it applies
its own label before it moves a card out of Todo, so changing which installation
is default never re-routes a card mid-build.

WHY A CARD IS DROPPED, AND WHY THE REASONS ARE NAMED. Three of the four verdicts
are not this installation's card, and they are not the same event:

- foreign: a sibling owns it. Nothing is wrong; the sibling's tick takes it.
- unroutable: the label names no sibling. Something IS wrong -- a typo in
  Linear, or an installation that was removed from this machine -- and the card
  will sit in Todo forever with no tick that claims it. Nobody would notice that
  from a shorter queue, so it is named on stderr every pass.
- ambiguous: two `foreman:*` labels. Guessing between them dispatches the card
  twice or not at all. It is refused for the card and costs the batch nothing,
  the way queue.py refuses one unreadable priority.

The label names are NOT validated against the installation name rule here. What
makes a name real is that `installation.py --siblings` lists it, and that list
is what the `siblings` argument carries; a second copy of the pattern would call
a name valid that no installation on this machine answers to.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

# Every routing label starts here. The name after it is the installation's, as
# `installation.py --siblings` prints it.
LABEL_PREFIX = "foreman:"

EXPECTED_LABELS = (
    "expected issue['labels'] to be absent, a list of names, a list of "
    "{'name': ...} objects, or {'nodes': [...]} of either"
)


class LabelShape(Exception):
    """The issue's labels are in a shape this module cannot read.

    Linear hands labels over in more than one shape, so a shape nobody has seen
    is a new shape and not a card with no labels. Reading it as "no labels"
    would hand every card on the board to the default installation at once.
    """


class AmbiguousOwner(Exception):
    """The card carries two different `foreman:*` labels, so it has no owner."""


class UnknownOwner(Exception):
    """The card's `foreman:*` label names no installation on this machine."""


class Reason(enum.Enum):
    """Why one card is, or is not, this installation's to work."""

    OWNED = "owned"
    FOREIGN = "foreign"
    UNROUTABLE = "unroutable"
    AMBIGUOUS = "ambiguous"


@dataclass(frozen=True)
class Verdict:
    """One card's routing outcome, with the sentence a caller prints for it.

    Two fields and no owner name. The caller acts on `reason` -- rank it, drop
    it quietly, or drop it and call the board stalled -- and prints `detail`.
    An `owner` field was carried here for a while and nothing ever read it: a
    value nobody reads is a value nobody notices going wrong.
    """

    reason: Reason
    detail: str

    @property
    def owned(self) -> bool:
        return self.reason is Reason.OWNED


def label_names(issue: object) -> list[str]:
    """Every label name on one issue, in any shape Linear hands it over in.

    GraphQL nests them as issue['labels']['nodes'][i]['name']. Linear MCP has
    returned a flat list of names and a flat list of objects instead, depending
    on the call. All three are read here so no caller normalises them.

    Raises LabelShape for anything else.
    """
    if not isinstance(issue, dict):
        raise LabelShape(f"expected a JSON object for the issue, not {type(issue).__name__}")

    labels = issue.get("labels")
    if labels is None:
        # Missing and null both mean a card nobody has labelled. That is the
        # normal state of a card on a one-installation machine.
        return []

    if isinstance(labels, dict):
        nodes = labels.get("nodes")
        if not isinstance(nodes, list):
            raise LabelShape(f"issue['labels']['nodes'] is {nodes!r}; {EXPECTED_LABELS}")
        labels = nodes

    if not isinstance(labels, list):
        raise LabelShape(f"issue['labels'] is {labels!r}; {EXPECTED_LABELS}")

    names = []
    for label in labels:
        if isinstance(label, str):
            names.append(label)
            continue
        if isinstance(label, dict):
            name = label.get("name")
            if not isinstance(name, str):
                raise LabelShape(f"a label's name is {name!r}; {EXPECTED_LABELS}")
            names.append(name)
            continue
        raise LabelShape(f"a label is {label!r}; {EXPECTED_LABELS}")
    return names


def installation_labels(issue: object) -> list[str]:
    """The installation names that this issue's `foreman:*` labels carry.

    The prefix is stripped, so the result is comparable with a sibling name
    straight from `installation.py --siblings`. A name repeated on two labels is
    one name: the repeat says nothing new, and calling it ambiguous would strand
    a card over a duplicate nobody can see in Linear's own label list.

    Raises LabelShape when the labels are in a shape this cannot read.
    """
    names = []
    for name in label_names(issue):
        if not name.startswith(LABEL_PREFIX):
            continue
        owner = name[len(LABEL_PREFIX):]
        if owner not in names:
            names.append(owner)
    return names


def card_name(issue: object) -> str:
    """How a refusal names this card. A card that cannot be named is still named.

    A refusal the operator cannot trace to a card in Linear is a refusal nobody
    acts on, so the fallback says plainly that the card had no identifier rather
    than printing an empty string.
    """
    if isinstance(issue, dict):
        identifier = issue.get("identifier")
        if isinstance(identifier, str) and identifier:
            return identifier
    return "<card with no identifier>"


def owner(issue: object, siblings: list[str]) -> str | None:
    """The one installation that owns this card, or None when it is unlabelled.

    `siblings` is every installation on this machine, from
    `installation.py --siblings`. It is what makes a label real.

    Raises AmbiguousOwner when the card carries two `foreman:*` labels, and
    UnknownOwner when its label names no sibling. Both messages name the card
    and the label, because the operator fixes this in Linear and needs both.
    """
    names = installation_labels(issue)
    if not names:
        return None
    if len(names) > 1:
        listed = ", ".join(f"{LABEL_PREFIX}{name}" for name in names)
        raise AmbiguousOwner(
            f"{card_name(issue)}: carries {len(names)} installation labels ({listed}); "
            "a card belongs to exactly one installation"
        )
    name = names[0]
    if name not in siblings:
        known = ", ".join(siblings) or "none"
        raise UnknownOwner(
            f"{card_name(issue)}: label {LABEL_PREFIX}{name} names no installation on this "
            f"machine; known installations: {known}"
        )
    return name


def verdict(
    issue: object, installation: str, is_default: bool, siblings: list[str]
) -> Verdict:
    """Whether this installation works this card, as a value rather than a raise.

    The default installation also owns every card carrying no `foreman:*` label.
    The caller gets a reason it can act on and a sentence it can print, so one
    loop handles all four outcomes without catching two exceptions of its own.

    LabelShape is deliberately NOT caught here. A card with unreadable labels is
    a shape nobody has taught this module, and calling it "not ours" would drop
    work silently; the caller refuses its batch instead.
    """
    try:
        name = owner(issue, siblings)
    except AmbiguousOwner as exc:
        return Verdict(Reason.AMBIGUOUS, str(exc))
    except UnknownOwner as exc:
        return Verdict(Reason.UNROUTABLE, str(exc))

    if name is None:
        if is_default:
            return Verdict(Reason.OWNED, f"{card_name(issue)}: unlabelled")
        return Verdict(
            Reason.FOREIGN,
            f"{card_name(issue)}: unlabelled, and this installation is not the default",
        )
    if name == installation:
        return Verdict(Reason.OWNED, f"{card_name(issue)}: labelled {LABEL_PREFIX}{name}")
    return Verdict(Reason.FOREIGN, f"{card_name(issue)}: owned by {name}")
