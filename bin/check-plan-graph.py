#!/usr/bin/env python3
"""Refuse a plan graph whose labels have grown back into prose.

    check-plan-graph.py docs/plans/a.md docs/plans/b.md
    check-plan-graph.py --limits

`skills/graphplan/SKILL.md` states the budget in words. This file is where the
numbers live, and a test compares the two, so the sentence below is built from
the constants rather than typed a second time.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Why there is a budget at all. A plan label is read by a stranger inside a
# diagram, at whatever size fits the whole graph on one screen -- not in a
# paragraph, where a sentence that long reads fine. And a node holding prose is
# holding something the graph cannot draw as a dependency, which is the one
# thing the graph was drawn for. Both failures look like helpfulness while they
# are being written, so they need a gate rather than a reminder.
MAX_NODE_LINES = 4
MAX_WORDS_PER_LINE = 6
MAX_LABEL_WORDS = 4

LIMITS = (
    f"A node label: at most {MAX_NODE_LINES} lines, "
    f"at most {MAX_WORDS_PER_LINE} words a line.",
    f"An edge or cluster label: at most {MAX_LABEL_WORDS} words.",
)

FENCE = "```"
FENCE_OPEN = "```mermaid"

BREAK = re.compile(r"<br\s*/?>", re.IGNORECASE)
TAG = re.compile(r"<[^>]*>")
TRAILING_ID = re.compile(r"[A-Za-z0-9_.-]+$")

# Lines that carry no label of their own: graph syntax, styling, cluster ends.
KEYWORDS = frozenset(
    ["flowchart", "graph", "direction", "classDef", "class", "linkStyle", "style", "end"]
)

# Bracket pairs that hold a quoted node label, in mermaid's node shapes.
OPENERS = (('[("', ')]'), ('["', "]"), ('("', ")"), ('{"', "}"))

USAGE = "usage: check-plan-graph.py <plan.md>... | --limits"


class LabelSyntax(Exception):
    """A label opens on a line and does not close on it."""


def words(text: str) -> list[str]:
    """The words of a label: markup removed, bare separators dropped."""
    return [word for word in TAG.sub(" ", text).split() if word != "·"]


def node_id(line: str, bracket: int) -> str:
    """The identifier immediately before the bracket at `bracket`.

    Shapes nest their brackets -- `u1(["stadium"])` opens two before its label
    -- so the outer ones are stepped over to reach the id.
    """
    found = TRAILING_ID.search(line[:bracket].rstrip("([{"))
    return found.group(0) if found else ""


def scan(line: str) -> list[tuple[str, str, str]]:
    """Every label on one line, as (kind, node id, label text).

    Raises LabelSyntax rather than skipping a line it cannot parse: a label the
    checker cannot read is a label nothing has checked.
    """
    found: list[tuple[str, str, str]] = []
    at = 0
    while at < len(line):
        opener = next((pair for pair in OPENERS if line.startswith(pair[0], at)), None)
        if opener:
            marks, closer = opener
            start = at + len(marks)
            quote = line.find('"', start)
            if quote < 0:
                raise LabelSyntax(f"node label opened by {marks} never closes on this line")
            if not line[quote + 1 :].lstrip().startswith(closer):
                raise LabelSyntax(
                    f'node label "{line[start:quote]}" is never closed by {closer}'
                )
            found.append(("node", node_id(line, at), line[start:quote]))
            at = line.index(closer, quote) + len(closer)
            continue
        if line[at] == "|":
            end = line.find("|", at + 1)
            if end < 0:
                raise LabelSyntax("edge label opened by | never closes on this line")
            found.append(("edge", "", line[at + 1 : end].strip().strip('"')))
            at = end + 1
            continue
        at += 1
    return found


def subgraph_title(line: str) -> str:
    """The title of a subgraph line, from its brackets or from the rest of it."""
    opened, closed = line.find("["), line.rfind("]")
    if 0 <= opened < closed:
        return line[opened + 1 : closed].strip().strip('"').strip()
    return line[len("subgraph") :].strip().strip('"').strip()


def check_line(path: str, number: int, line: str) -> list[str]:
    where = f"{path}:{number}"
    first = line.split()[0]
    if first in KEYWORDS:
        return []
    if first == "subgraph":
        title = subgraph_title(line)
        count = len(words(title))
        if count > MAX_LABEL_WORDS:
            return [
                f'{where}: subgraph title "{title}" has {count} words, '
                f"at most {MAX_LABEL_WORDS} allowed"
            ]
        return []
    try:
        labels = scan(line)
    except LabelSyntax as unclosed:
        return [f"{where}: {unclosed}"]

    problems: list[str] = []
    for kind, ident, label in labels:
        if kind == "edge":
            count = len(words(label))
            if count > MAX_LABEL_WORDS:
                problems.append(
                    f'{where}: edge label "{label}" has {count} words, '
                    f"at most {MAX_LABEL_WORDS} allowed"
                )
            continue
        if not ident:
            problems.append(f'{where}: node label "{label}" has no id before its bracket')
            continue
        parts = BREAK.split(label)
        if len(parts) > MAX_NODE_LINES:
            problems.append(
                f"{where}: node {ident}, label has {len(parts)} lines, "
                f"at most {MAX_NODE_LINES} allowed"
            )
        for index, part in enumerate(parts, 1):
            count = len(words(part))
            if count > MAX_WORDS_PER_LINE:
                problems.append(
                    f"{where}: node {ident}, label line {index} has {count} words, "
                    f"at most {MAX_WORDS_PER_LINE} allowed"
                )
    return problems


def read_block(path: str, text: str) -> tuple[list[tuple[int, str]], list[str]]:
    """The lines inside the one mermaid fence, plus what was found outside it."""
    block: list[tuple[int, str]] = []
    problems: list[str] = []
    state = "before"
    opened_at = 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if state == "inside":
            if line == FENCE:
                state = "after"
            else:
                block.append((number, line))
            continue
        if state == "before" and line == FENCE_OPEN:
            state, opened_at = "inside", number
            continue
        if not line:
            continue
        if line.startswith(FENCE):
            problems.append(
                f"{path}:{number}: a fenced block other than the plan's mermaid block"
            )
        else:
            problems.append(f"{path}:{number}: prose outside the mermaid block")
    if state == "before":
        # One message, not one per line. A file with no fence at all is prose
        # from its first line to its last, and reporting every one of them
        # buries the single fact the reader needs under a thousand copies of it.
        return [], [
            f"{path}: no {FENCE_OPEN} block; a plan is one mermaid block and nothing else"
        ]
    if state == "inside":
        problems.append(f"{path}:{opened_at}: mermaid block opened here and never closed")
    return block, problems


def check_block(path: str, block: list[tuple[int, str]]) -> list[str]:
    problems: list[str] = []
    # The %%{init: ...}%% directive spans many lines and holds no label.
    directive_at = 0
    for number, line in block:
        if directive_at:
            if "}%%" in line:
                directive_at = 0
            continue
        if line.startswith("%%{"):
            if "}%%" not in line:
                directive_at = number
            continue
        if line.startswith("%%") or not line:
            continue
        problems += check_line(path, number, line)
    if directive_at:
        problems.append(
            f"{path}:{directive_at}: %%{{init directive opened here and never closed by }}%%"
        )
    return problems


def check_file(path: str) -> list[str]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, ValueError) as unreadable:
        return [f"{path}: cannot read: {unreadable}"]
    block, problems = read_block(path, text)
    return problems + check_block(path, block)


def main(argv: list[str]) -> int:
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    if "--limits" in argv:
        if argv != ["--limits"]:
            print(f"{USAGE}\n--limits takes no other arguments", file=sys.stderr)
            return 2
        print("\n".join(LIMITS))
        return 0
    unknown = [arg for arg in argv if arg.startswith("-")]
    if unknown:
        print(f"{USAGE}\nunknown option: {unknown[0]}", file=sys.stderr)
        return 2

    problems: list[str] = []
    for path in argv:
        problems += check_file(path)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
