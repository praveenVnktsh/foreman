"""Read a Linear card's label names, in any shape Linear hands them over.

    import route
    names = route.label_names(card)

A PREDICATE MODULE, NOT A PROGRAM. It is imported, never run: there is no
`main`, no argument parser and no exit code here. `merge.py` is the one caller,
and it owns the argv, the stdin, the refusal and the exit codes.

WHAT REMAINS. This module used to answer which installation owned a card, by
its `foreman:*` label. There is one foreman now, so no card carries an ownership
label and nothing routes. What is left is the one piece `merge.py` still needs:
turning the card JSON Linear hands over into a list of label names, whatever
shape the labels arrive in.
"""

from __future__ import annotations

EXPECTED_LABELS = (
    "expected issue['labels'] to be absent, a list of names, a list of "
    "{'name': ...} objects, or {'nodes': [...]} of either"
)


class LabelShape(Exception):
    """The issue's labels are in a shape this module cannot read.

    Linear hands labels over in more than one shape, so a shape nobody has seen
    is a new shape and not a card with no labels. Reading it as "no labels"
    would silently drop a label the operator applied.
    """


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
        # Missing and null both mean a card nobody has labelled.
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
