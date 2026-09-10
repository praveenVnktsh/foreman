#!/usr/bin/env python3
"""Refuse a plan that is not a graph, or whose labels have grown back into prose.

    check-plan-graph.py docs/plans/a.md docs/plans/b.md
    check-plan-graph.py --limits

`skills/graphplan/SKILL.md` states the budget in words. This file is where the
numbers live, and a test compares the two, so the sentence below is built from
the constants rather than typed a second time.
"""

from __future__ import annotations

import html
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# Why there is a budget at all. A plan label is read by a stranger inside a
# diagram, at whatever size fits the whole graph on one screen -- not in a
# paragraph, where a sentence that long reads fine. And a node holding prose is
# holding something the graph cannot draw as a dependency, which is the one
# thing the graph was drawn for. Both failures look like helpfulness while they
# are being written, so they need a gate rather than a reminder.
#
# Words catch prose. Characters catch width. A label must pass both, because
# either budget alone has a hole: on 2026-09-03 an unquoted seventeen-word label
# went unmeasured, and a single 200-character token is one word and clears any
# word budget while filling the screen.
#
# The character budget is set by what a plan has to be able to SAY, not by what
# plans have said so far. A node names the file it builds, in the form
# skills/graphplan/SKILL.md prescribes: `c1 · <path> · CHANGE`, which is the
# path plus fourteen characters. The longest path this repository tracks is 57
# characters, so that label is 71. A budget of 64, calibrated on the widest
# label already in docs/plans/, refused a correct plan for six tracked files
# and had no compliant wording to offer -- caught in review on 2026-09-09,
# before it ever cost a card a plan attempt. 80 is the column this repository
# wraps its prose at, and it leaves nine characters over the longest name a
# plan must be able to write.
#
# 80 is a legibility rule and not a fact about this tree, so a target with a
# deeper one does not raise it. A path that will not fit gets a label line of
# its own, and a path too wide even for that gets its identifying tail, with
# the whole path in the prompt -- the wording is in SKILL.md, beside the
# budget, because a gate that refuses correct work without naming the compliant
# form costs a card an attempt. tests/test-plan-graphs-are-terse.sh measures
# the longest path THIS repository tracks; that guards this repository's own
# plans, and the wording is what covers every other target.
MAX_NODE_LINES = 4
MAX_WORDS_PER_LINE = 6
MAX_LABEL_WORDS = 4
MAX_LABEL_CHARS = 80

LIMITS = (
    f"A node label: at most {MAX_NODE_LINES} lines, "
    f"at most {MAX_WORDS_PER_LINE} words a line.",
    f"An edge or cluster label: at most {MAX_LABEL_WORDS} words.",
    f"Any label line: at most {MAX_LABEL_CHARS} characters, counted as it renders.",
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

# The words a mermaid graph opens with. A block that opens with anything else
# is not a graph, whatever the fence says.
GRAPH_HEADERS = frozenset(["flowchart", "graph"])
HEADER_LIST = " or ".join(sorted(GRAPH_HEADERS))

# Lines that carry no label of their own: graph syntax, styling, cluster ends.
KEYWORDS = GRAPH_HEADERS | frozenset(
    ["direction", "classDef", "class", "linkStyle", "style", "end"]
)

USAGE = "usage: check-plan-graph.py <plan.md>... | --limits"


class LabelSyntax(Exception):
    """A statement the checker cannot read as nodes and links."""


@dataclass(frozen=True)
class Read:
    """What reading a part of the graph found: problems, links, and doubt.

    One shape for a statement and for a line, so a caller merges what its parts
    read instead of carrying two counters beside a list of problems.

    `unread` is what keeps the no-link check honest. A statement nothing could
    parse might draw a link or might not, and counting it as zero tells the
    author to add a dependency the graph already states.
    """

    problems: tuple[str, ...] = ()
    links: int = 0
    unread: bool = False

    @classmethod
    def merge(cls, readings: list[Read]) -> Read:
        """One Read for many: problems in order, links summed, doubt kept."""
        return cls(
            tuple(problem for reading in readings for problem in reading.problems),
            sum(reading.links for reading in readings),
            any(reading.unread for reading in readings),
        )


def words(text: str) -> list[str]:
    """The words of a label: markup removed, bare separators dropped."""
    return [word for word in TAG.sub(" ", text).split() if word != "·"]


def width(text: str) -> int:
    """The characters a label takes on screen once mermaid has rendered it.

    Markup goes first, entities second. `&lt;b&gt;` renders as four characters
    a reader sees; unescaping it first would turn it into a tag that TAG then
    deletes, and the label would measure as narrower than it draws.
    """
    return len(" ".join(html.unescape(TAG.sub(" ", text)).split()))


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


def statements(line: str) -> list[str]:
    """The statements on one line. A `;` separates them, unless it is a label.

    Mermaid reads statements, not lines, and every keyword this file knows is
    the first word of a statement rather than of a line. Splitting here is what
    lets `class a hot; c1["..."] --> c2["ok"]` have its keyword skipped and its
    graph measured, instead of the whole line being skipped for its first word.
    The split is quote-aware because a `;` inside a label is text.
    """
    parts: list[str] = []
    start = 0
    quoted = False
    for at, character in enumerate(line):
        if character == '"':
            quoted = not quoted
        elif character == ";" and not quoted:
            parts.append(line[start:at])
            start = at + 1
    parts.append(line[start:])
    return [part.strip() for part in parts if part.strip()]


def scan(statement: str) -> tuple[list[tuple[str, str, str]], int]:
    """Every label in one statement, as (kind, node id, text), and its links.

    The statement is read as mermaid writes it: a node, then a link, then a
    node, for as long as it runs. Anything that does not fit raises LabelSyntax
    and is reported. Nothing is skipped -- a label the checker cannot read is a
    label nothing has checked, and it reaches the diagram unmeasured.

    The links are counted here because here is where they are already parsed. A
    second reader of the same syntax drifts from this one, and a regex over the
    raw text finds the `-->` inside a quoted label.
    """
    found: list[tuple[str, str, str]] = []
    links = 0
    at = skip_space(statement, 0)
    expect_node = True
    while at < len(statement):
        if expect_node:
            ident = IDENT.match(statement, at)
            if not ident:
                raise LabelSyntax(f'expected a node id at "{statement[at:]}"')
            at = ident.end()
            brackets = OPEN_RUN.match(statement, at)
            if brackets:
                at, label = read_node_label(statement, brackets.end(), ident.group(0))
                found.append(("node", ident.group(0), label))
            expect_node = False
        elif statement[at] == "&":
            at += 1
            expect_node = True
        else:
            link = LINK.match(statement, at)
            if not link:
                raise LabelSyntax(f'expected a link or a label at "{statement[at:]}"')
            at = link.end()
            if states_a_relationship(link.group(0)):
                links += 1
            if at < len(statement) and statement[at] == "|":
                close = statement.find("|", at + 1)
                if close < 0:
                    raise LabelSyntax("edge label opened by | never closes on this line")
                found.append(("edge", "", statement[at + 1 : close].strip().strip('"')))
                at = close + 1
            elif link.group(0) in INLINE_TEXT_LINKS:
                raise LabelSyntax(
                    f'edge label after "{link.group(0)}" belongs in pipes: -->|"..."|'
                )
            expect_node = True
        at = skip_space(statement, at)
    return found, links


def states_a_relationship(link: str) -> bool:
    """Whether a link says anything about the two nodes it joins.

    `~~~` is mermaid's invisible link. It places one node below another and
    draws nothing between them, so a graph whose only links are invisible has
    stated no relationship at all -- which is what the no-link check refuses.
    """
    return set(link) != {"~"}


def subgraph_title(statement: str) -> str:
    """The title of one subgraph statement, from its brackets or from the rest.

    A statement, never a line: `subgraph s["a"]; x --> y` read as a line gave a
    title running to the last `]` on it, which was node syntax and not a title.
    """
    opened, closed = statement.find("["), statement.rfind("]")
    if 0 <= opened < closed:
        return statement[opened + 1 : closed].strip().strip('"').strip()
    return statement[len("subgraph") :].strip().strip('"').strip()


def check_label(where: str, subject: str, label: str, max_words: int) -> list[str]:
    """One label against both budgets: its words, then its rendered width."""
    problems: list[str] = []
    count = len(words(label))
    if count > max_words:
        problems.append(
            f"{where}: {subject} has {count} words, at most {max_words} allowed"
        )
    size = width(label)
    if size > MAX_LABEL_CHARS:
        problems.append(
            f"{where}: {subject} is {size} characters, "
            f"at most {MAX_LABEL_CHARS} allowed"
        )
    return problems


def check_line(path: str, number: int, line: str) -> Read:
    """What one line of the graph draws, and what is wrong with it.

    A line is not the unit mermaid reads; a statement is. Skipping a whole line
    for its first word therefore skipped everything written after the `;` too:
    `class a hot; c1["<200 characters>"] --> c2["ok"]` had its label measured by
    nothing and its link counted by nothing, and the file exited 0. Found in
    review on 2026-09-09, twice -- first for `flowchart` and `graph`, then for
    the six other keywords that were still skipped a line at a time.
    """
    where = f"{path}:{number}"
    return Read.merge(
        [check_statement(where, statement) for statement in statements(line)]
    )


def check_statement(where: str, statement: str) -> Read:
    """What one statement draws, and what is wrong with it."""
    first = statement.split()[0]
    if first in KEYWORDS:
        # A header, a direction, a style rule, a class, the end of a cluster.
        # None of them carries a label of its own.
        return Read()
    if first == "subgraph":
        # The title is read from the statement, never from the line. Reading it
        # from the line made `subgraph s["a"]; x --> y` measure everything up to
        # the last `]` as a title, and report a five-word title that nobody
        # wrote (review, 2026-09-09).
        title = subgraph_title(statement)
        return Read(
            tuple(
                check_label(
                    where, f'subgraph title "{title}"', title, MAX_LABEL_WORDS
                )
            )
        )
    return check_drawing(where, statement)


def check_drawing(where: str, statement: str) -> Read:
    """One statement of nodes and links, against the budget."""
    try:
        labels, links = scan(statement)
    except LabelSyntax as unreadable:
        return Read((f"{where}: {unreadable}",), unread=True)

    problems: list[str] = []
    for kind, ident, label in labels:
        if kind == "edge":
            problems += check_label(
                where, f'edge label "{label}"', label, MAX_LABEL_WORDS
            )
            continue
        parts = BREAK.split(label)
        if len(parts) > MAX_NODE_LINES:
            problems.append(
                f"{where}: node {ident}, label has {len(parts)} lines, "
                f"at most {MAX_NODE_LINES} allowed"
            )
        for index, part in enumerate(parts, 1):
            problems += check_label(
                where, f"node {ident}, label line {index}", part, MAX_WORDS_PER_LINE
            )
    return Read(tuple(problems), links)


def read_block(path: str, text: str) -> tuple[list[tuple[int, str]] | None, list[str]]:
    """The lines inside the one mermaid fence, plus what was found outside it.

    The lines are None when the file has no fence: there is no block to read,
    which is a different answer from a block that holds no lines.
    """
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
        return None, [
            f"{path}: no {FENCE_OPEN} block; a plan is one mermaid block and nothing else"
        ]
    if state == "inside":
        problems.append(f"{path}:{opened_at}: mermaid block opened here and never closed")
    return block, problems


def graph_lines(
    path: str, block: list[tuple[int, str]]
) -> tuple[list[tuple[int, str]], list[str]]:
    """The lines of the block that draw the graph: comments and blanks dropped."""
    lines: list[tuple[int, str]] = []
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
        lines.append((number, line))
    if directive_at:
        problems.append(
            f"{path}:{directive_at}: %%{{init directive opened here and never closed by }}%%"
        )
    return lines, problems


def check_block(path: str, block: list[tuple[int, str]]) -> list[str]:
    lines, problems = graph_lines(path, block)
    if problems:
        # An unclosed %%{init directive swallows every line after it, so what
        # is left says nothing about whether the block holds a graph. Reporting
        # it as empty as well would be false: the lines are there, unread.
        return problems
    if not lines:
        # One message, for the same reason the missing fence gets one: the
        # reader needs the file name and the one fact, not a line number
        # inside a block that says nothing.
        return problems + [
            f"{path}: empty {FENCE_OPEN} block; a plan is one mermaid graph and nothing else"
        ]
    opened_at, opener = lines[0][0], lines[0][1].split()[0]
    if opener not in GRAPH_HEADERS:
        # Prose inside the fence. A paragraph was already refused, but by
        # LabelSyntax rather than by anything asking whether the block held a
        # graph: `we then update the checker` is not a node followed by a link.
        # What reached this line unrefused was text that parses as bare node
        # ids -- one word to a line -- and any diagram type that is not a
        # flowchart. This gate is why a fence has to open as a graph; it is not
        # the whole of what refuses prose.
        return problems + [
            f'{path}:{opened_at}: block opens with "{opener}", not {HEADER_LIST}; '
            "a plan is one mermaid graph and nothing else"
        ]

    read = Read.merge([check_line(path, number, line) for number, line in lines])
    problems += list(read.problems)
    if not read.links and not read.unread:
        # A fence with no link in it is a list with boxes drawn round it. A
        # dotted link counts here: it is a real relationship, and the fact that
        # it orders no build is a separate claim from whether the plan states a
        # dependency at all. An invisible `~~~` does not count -- see
        # states_a_relationship().
        #
        # Nothing is claimed when a statement went unread, for the reason the
        # unclosed directive above gets no empty-block message: a line the
        # checker could not parse may well draw the edge, and telling the author
        # to add one they already drew is the advice SKILL.md forbids.
        problems.append(
            f"{path}: no link between any two nodes; "
            "a plan graph states what depends on what"
        )
    return problems


def check_file(path: str) -> list[str]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, ValueError) as unreadable:
        return [f"{path}: cannot read: {unreadable}"]
    block, problems = read_block(path, text)
    if block is None:
        return problems
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
