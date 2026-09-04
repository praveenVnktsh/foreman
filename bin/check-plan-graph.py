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

# A node id: a word, with a dot or a dash only between two of them, so `a-->b`
# reads as one id, a link and one id rather than as the id `a--`.
IDENT = re.compile(r"[A-Za-z0-9_]+(?:[.-][A-Za-z0-9_]+)*")
# A link: the run of arrow characters between two nodes. `-->`, `---`, `-.->`,
# `==>`, `~~~`, `<-->`, and the `--o`/`--x` heads when a space follows.
LINK = re.compile(r"[-=.<>~]{2,}(?:[ox](?=\s))?")
# The brackets around a node label. Any mermaid shape: [], (), ([]), [()],
# {{}}, [//], [\\], and the asymmetric >].
OPEN_RUN = re.compile(r"(?:[(\[{]+|>)[/\\]?")
CLOSE_RUN = re.compile(r"[/\\]?[)\]}]+")
# A link written to carry its label inline: `a -- text --> b`. Mermaid opens
# that form with exactly two characters and closes it with the arrow.
INLINE_TEXT_LINKS = frozenset(["--", "==", "-."])

# Lines that carry no label of their own: graph syntax, styling, cluster ends.
KEYWORDS = frozenset(
    ["flowchart", "graph", "direction", "classDef", "class", "linkStyle", "style", "end"]
)

USAGE = "usage: check-plan-graph.py <plan.md>... | --limits"


class LabelSyntax(Exception):
    """A line the checker cannot read as nodes and links."""


def words(text: str) -> list[str]:
    """The words of a label: markup removed, bare separators dropped."""
    return [word for word in TAG.sub(" ", text).split() if word != "·"]


def skip_space(line: str, at: int) -> int:
    while at < len(line) and line[at].isspace():
        at += 1
    return at


def read_node_label(line: str, at: int, ident: str) -> tuple[int, str]:
    """The quoted label inside a node's brackets, and where it ends.

    A node label must be quoted. Brackets nest and mermaid has a dozen shapes,
    so without the quotes the checker has to guess where the label ends -- and
    on 2026-09-03 a guess is what let `c1[seventeen words like this]` through a
    six-word budget with no output at all. The quote is the one delimiter that
    needs no guess, so a label without one is refused rather than measured.
    """
    at = skip_space(line, at)
    if at >= len(line) or line[at] != '"':
        raise LabelSyntax(f'node {ident}: label is not quoted; write {ident}["..."]')
    close = line.find('"', at + 1)
    if close < 0:
        raise LabelSyntax(f"node {ident}: label opens with a quote that never closes")
    closing = CLOSE_RUN.match(line, skip_space(line, close + 1))
    if not closing:
        raise LabelSyntax(f"node {ident}: label is never closed by its bracket")
    return closing.end(), line[at + 1 : close]


def scan(line: str) -> list[tuple[str, str, str]]:
    """Every label on one line, as (kind, node id, label text).

    The line is read as mermaid writes it: a node, then a link, then a node,
    for as long as it runs. Anything that does not fit raises LabelSyntax and
    is reported. Nothing is skipped -- a label the checker cannot read is a
    label nothing has checked, and it reaches the diagram unmeasured.
    """
    found: list[tuple[str, str, str]] = []
    at = skip_space(line, 0)
    expect_node = True
    while at < len(line) and line[at] != ";":
        if expect_node:
            ident = IDENT.match(line, at)
            if not ident:
                raise LabelSyntax(f'expected a node id at "{line[at:]}"')
            at = ident.end()
            brackets = OPEN_RUN.match(line, at)
            if brackets:
                at, label = read_node_label(line, brackets.end(), ident.group(0))
                found.append(("node", ident.group(0), label))
            expect_node = False
        elif line[at] == "&":
            at += 1
            expect_node = True
        else:
            link = LINK.match(line, at)
            if not link:
                raise LabelSyntax(f'expected a link or a label at "{line[at:]}"')
            at = link.end()
            if at < len(line) and line[at] == "|":
                close = line.find("|", at + 1)
                if close < 0:
                    raise LabelSyntax("edge label opened by | never closes on this line")
                found.append(("edge", "", line[at + 1 : close].strip().strip('"')))
                at = close + 1
            elif link.group(0) in INLINE_TEXT_LINKS:
                raise LabelSyntax(
                    f'edge label after "{link.group(0)}" belongs in pipes: -->|"..."|'
                )
            expect_node = True
        at = skip_space(line, at)
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
