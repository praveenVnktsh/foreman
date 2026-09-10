#!/usr/bin/env python3
"""Refuse a plan graph whose labels have grown back into prose.

    check-plan-graph.py docs/plans/a.md docs/plans/b.md
    check-plan-graph.py --limits

Every label on a line is measured, not only the first. A line may hold several
statements separated by ";", and an edge label may be written in pipes
(`a -->|"text"| b`) or inline on the link (`a -- text --> b`). Review of PR #18
on 2026-09-09 found each of those forms reaching the diagram unmeasured.

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
# A link: an optional tail, a run of arrow characters, an optional head.
# `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `---o`, `--x`, `o--o`. The head is
# one character, so `a-->ok` reads as the node `ok` while `a---ob` reads as the
# link `---o` and the node `b`. Until 2026-09-09 an `o` or `x` head was only
# accepted with a space after it, and reviewing PR #18 found `a---ob["x"]`
# reported against a node `ob` that no graph contains.
LINK = re.compile(r"(?:[<ox])?[-=.~]{2,}(?:[>ox])?")
# The brackets around a node label. Any mermaid shape: [], (), ([]), [()],
# {{}}, [//], [\\], and the asymmetric >].
OPEN_RUN = re.compile(r"(?:[(\[{]+|>)[/\\]?")
CLOSE_RUN = re.compile(r"[/\\]?[)\]}]+")
# A link written to carry its label inline: `a -- text --> b`, `a -. text .-> b`
# and `a == text ==> b`. Mermaid opens that form with a run that carries no
# arrow head, and closes it with the run that does.
INLINE_TEXT_LINKS = frozenset(["--", "==", "-."])
# The run of link characters that closes an inline label. Two characters at
# least, so a full stop inside the label text does not end the label early.
INLINE_CLOSE = re.compile(r"[-=.~]{2,}(?:[>ox])?")
# A class applied to a node: `c1:::changed` and `c1["label"]:::changed`. It
# carries no label. Until 2026-09-09 the checker refused it as "expected a link
# or a label", which named the wrong problem: the line is valid mermaid.
CLASS_SUFFIX = re.compile(r":::[A-Za-z0-9_-]+")

# Lines that carry no label of their own: graph syntax, styling, cluster ends.
KEYWORDS = frozenset(
    ["flowchart", "graph", "direction", "classDef", "class", "linkStyle", "style", "end"]
)

USAGE = "usage: check-plan-graph.py <plan.md>... | --limits"


class LabelSyntax(Exception):
    """A line the checker cannot read as nodes and links."""


# One label found on a line: its kind ("node" or "edge"), the node id it belongs
# to, and its text. An edge label belongs to no node, so its id is empty.
Label = tuple[str, str, str]


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


def read_node(line: str, at: int) -> tuple[int, list[Label]]:
    """One node -- its id, its bracketed label if it has one -- and where it ends.

    A node carries at most one label, so the list holds one entry or none.
    """
    ident = IDENT.match(line, at)
    if not ident:
        raise LabelSyntax(f'expected a node id at "{line[at:]}"')
    at = ident.end()
    found: list[Label] = []
    brackets = OPEN_RUN.match(line, at)
    if brackets:
        at, label = read_node_label(line, brackets.end(), ident.group(0))
        found.append(("node", ident.group(0), label))
    styled = CLASS_SUFFIX.match(line, at)
    if styled:
        at = styled.end()
    return at, found


def read_pipe_label(line: str, at: int) -> tuple[int, list[Label]]:
    """An edge label in pipes, `|"text"|`, and where it ends.

    `at` is the opening pipe. Mermaid also allows a space between the link and
    the pipe, as in `a --> |text| b`, so the caller skips whitespace first.
    """
    close = line.find("|", at + 1)
    if close < 0:
        raise LabelSyntax("edge label opened by | never closes on this line")
    return close + 1, [("edge", "", line[at + 1 : close].strip().strip('"'))]


def read_inline_label(line: str, at: int, opener: str) -> tuple[int, list[Label]]:
    """An edge label inline on the link, `a -- text --> b`, and where it ends.

    `at` is the first character of the text. The label runs to the next run of
    link characters, which is the arrow that closes it.
    """
    closing = INLINE_CLOSE.search(line, at)
    if not closing:
        raise LabelSyntax(
            f'edge label after "{opener}" is never closed by a link on this line'
        )
    return closing.end(), [("edge", "", line[at : closing.start()].strip().strip('"'))]


def read_link(line: str, at: int) -> tuple[int, list[Label]]:
    """One link, the edge label it carries, and where it ends.

    Mermaid writes an edge label three ways and all three are measured against
    the same budget: `a -->|"text"| b`, `a -- text --> b`, `a -. text .-> b`.
    Until 2026-09-09 the last two were refused with a message telling the author
    to use pipes, so a plan that used mermaid's own inline form was never
    measured and was reported against the wrong thing.
    """
    link = LINK.match(line, at)
    if not link:
        raise LabelSyntax(f'expected a link or a label at "{line[at:]}"')
    at = skip_space(line, link.end())
    if at < len(line) and line[at] == "|":
        return read_pipe_label(line, at)
    if link.group(0) in INLINE_TEXT_LINKS:
        return read_inline_label(line, at, link.group(0))
    return at, []


def scan(line: str) -> list[Label]:
    """Every label on one line, as (kind, node id, label text).

    The line is read as mermaid writes it: a node, then a link, then a node,
    for as long as it runs. `;` ends a statement and starts the next one on the
    same line. Anything that does not fit raises LabelSyntax and is reported.
    Nothing is skipped -- a label the checker cannot read is a label nothing has
    checked, and it reaches the diagram unmeasured.

    Until 2026-09-09 the scan stopped at the first `;`, so review of PR #18
    found `a["p"]; b["q"]; c["r"]` measured only the label of `a`.
    """
    found: list[Label] = []
    at = skip_space(line, 0)
    expect_node = True
    while at < len(line):
        if line[at] == ";":
            at, expect_node = at + 1, True
        elif line[at] == "&" and not expect_node:
            at, expect_node = at + 1, True
        elif expect_node:
            at, labels = read_node(line, at)
            found += labels
            expect_node = False
        else:
            at, labels = read_link(line, at)
            found += labels
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
