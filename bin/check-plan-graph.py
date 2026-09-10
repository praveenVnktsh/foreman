#!/usr/bin/env python3
"""Refuse a plan that is not a graph, or whose labels have grown back into prose.

    check-plan-graph.py docs/plans/a.md docs/plans/b.md
    check-plan-graph.py --limits

Every label on a line is measured, not only the first. Review of PR #18 on
2026-09-09 found two ways a label got past this file. A line packing several
statements behind ";" was read only as far as the first one and passed with
exit 0. An edge label written inline on the link, `a -- text --> b`, was
refused rather than measured, which is loud but turns a valid line into a
rewrite. Both forms are now read the way mermaid reads them.

The block itself is judged before its labels are. Reading the labels inside a
fence says nothing about whether the fence holds a graph, and until 2026-09-09
nothing asked: an empty ```mermaid fence and a prose plan wrapped in one both
passed as plan graphs.

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
from typing import NamedTuple

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
# The tail of a link: the character mermaid draws the edge with where it
# starts, as in `o--`, `x==` and `<-.`. LINK is built from it so the two agree,
# because inline_opener() has to be able to take a tail back off again.
LINK_TAIL = re.compile(r"[<ox]")
# A link: an optional tail, a run of arrow characters, an optional head.
# `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `---o`, `--x`, `o--o`. The head is
# one character, so `a-->ok` reads as the node `ok` while `a---ob` reads as the
# link `---o` and the node `b`. Until 2026-09-09 an `o` or `x` head was only
# accepted with a space after it, and reviewing PR #18 found `a---ob["x"]`
# reported against a node `ob` that no graph contains.
LINK = re.compile(rf"{LINK_TAIL.pattern}?[-=.~]{{2,}}(?:[>ox])?")
# The brackets around a node label. Any mermaid shape: [], (), ([]), [()],
# {{}}, [//], [\\], and the asymmetric >].
OPEN_RUN = re.compile(r"(?:[(\[{]+|>)[/\\]?")
CLOSE_RUN = re.compile(r"[/\\]?[)\]}]+")


class InlineLink(NamedTuple):
    """How mermaid closes an edge label written inline on the link."""

    closer: re.Pattern[str]
    example: str


# A link written to carry its label inline: `a -- text --> b`, `a == text ==> b`
# and `a -. text .-> b`. Each opener is closed by its own characters and by
# nothing else, which is mermaid's own rule: its lexer leaves the label state on
# `--+[-xo>]`, `==+[=xo>]` and `-?\.+-[xo>]?` respectively, and treats every
# other character as label text.
#
# A closer that matched any run of link characters is what review of PR #18
# found on 2026-09-09: `a -- reads the plan, then... builds --> b` ended at the
# `...`, so three of its five words were measured and the label passed.
INLINE_LINKS = {
    "--": InlineLink(re.compile(r"-{2,}[-xo>]"), "-->"),
    "==": InlineLink(re.compile(r"={2,}[=xo>]"), "==>"),
    "-.": InlineLink(re.compile(r"-?\.+-[xo>]?"), ".->"),
}
# A class applied to a node: `c1:::changed` and `c1["label"]:::changed`. It
# carries no label. Until 2026-09-09 the checker refused it as "expected a link
# or a label", which named the wrong problem: the line is valid mermaid.
CLASS_SUFFIX = re.compile(r":::[A-Za-z0-9_-]+")

# The words a mermaid graph opens with. A block that opens with anything else
# is not a graph, whatever the fence says.
GRAPH_HEADERS = frozenset(["flowchart", "graph"])
HEADER_LIST = " or ".join(sorted(GRAPH_HEADERS))

# Statements that open with a keyword rather than with a node id. Only
# `subgraph` carries a label; the rest are graph syntax, styling and cluster
# ends, and carry none.
SUBGRAPH = "subgraph"
KEYWORDS = GRAPH_HEADERS | frozenset(
    [
        SUBGRAPH,
        "direction",
        "classDef",
        "class",
        "linkStyle",
        "style",
        "end",
    ]
)

# What a message calls a label that is budgeted in words rather than in lines.
SHORT_LABELS = {"edge": "edge label", "cluster": "subgraph title"}

USAGE = "usage: check-plan-graph.py <plan.md>... | --limits"


class LabelSyntax(Exception):
    """A line the checker cannot read as nodes and links."""


# One label found on a line: its kind ("node" or "edge"), the node id it belongs
# to, and its text. An edge label belongs to no node, so its id is empty.
Label = tuple[str, str, str]


class Scanned(NamedTuple):
    """What one line of a graph draws, as the scanner read it.

    `links` counts only the links that state a relationship, so it answers the
    one question the block-level check asks of a line. `unreadable` is None
    when the whole line was read, and the labels found before an unreadable
    statement come back beside it rather than being thrown away with it.
    """

    labels: list[Label]
    links: int
    unreadable: str | None


@dataclass(frozen=True)
class Read:
    """What checking a part of the graph found: problems, links, and doubt.

    One shape for a line and for the whole block, so a caller merges what its
    parts read instead of carrying two counters beside a list of problems.

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

    `at` is the first character of the text. The label runs to the arrow that
    closes this opener, and every other character belongs to the label. A `...`
    or a `~~` inside the text is text, not the end of the label.
    """
    inline = INLINE_LINKS[opener]
    closing = inline.closer.search(line, at)
    if not closing:
        raise LabelSyntax(
            f'edge label after "{opener}" never closes; '
            f'expected "{inline.example}" to end it'
        )
    return closing.end(), [("edge", "", line[at : closing.start()].strip().strip('"'))]


def inline_opener(link: str) -> str:
    """The link with its tail removed, which is what an inline label closes.

    A tail says how mermaid draws the edge where it starts and says nothing
    about which characters end a label written on the link, so `o--`, `x--` and
    `<--` all carry the label that `--` carries. Review of PR #25 on 2026-09-09
    found the whole link looked up in INLINE_LINKS, where a tailed one matches
    no key: the label on `a o-- one two three four five --> b` was never
    measured, and `two` was reported as a node the graph does not contain.
    """
    tail = LINK_TAIL.match(link)
    return link[tail.end() :] if tail else link


def states_a_relationship(link: str) -> bool:
    """Whether a link says anything about the two nodes it joins.

    `~~~` is mermaid's invisible link. It places one node below another and
    draws nothing between them, so a graph whose only links are invisible has
    stated no relationship at all -- which is what the no-link check refuses.
    """
    return set(link) != {"~"}


def read_link(line: str, at: int) -> tuple[int, list[Label], bool]:
    """One link, the edge label it carries, where it ends, and what it states.

    Mermaid writes an edge label three ways and all three are measured against
    the same budget: `a -->|"text"| b`, `a -- text --> b`, `a -. text .-> b`.
    Until 2026-09-09 the last two were refused with a message telling the author
    to move the label into pipes. That refusal was loud, not silent, but it made
    a valid mermaid line something the author had to rewrite to get measured.

    The last value is whether this link states a relationship at all, which is
    what the block-level no-link check counts. See states_a_relationship().
    """
    link = LINK.match(line, at)
    if not link:
        raise LabelSyntax(f'expected a link or a label at "{line[at:]}"')
    states = states_a_relationship(link.group(0))
    opener = inline_opener(link.group(0))
    at = skip_space(line, link.end())
    if at < len(line) and line[at] == "|":
        ends, labels = read_pipe_label(line, at)
    elif opener in INLINE_LINKS:
        ends, labels = read_inline_label(line, at, opener)
    else:
        ends, labels = at, []
    return ends, labels, states


def statement_end(line: str, at: int) -> int:
    """Where the statement starting at `at` ends: its `;`, or the line's end.

    Quotes are respected, so a `;` inside a label does not split a statement.
    """
    quoted = False
    while at < len(line):
        if line[at] == '"':
            quoted = not quoted
        elif line[at] == ";" and not quoted:
            return at
        at += 1
    return at


def continues_a_node(line: str, at: int) -> bool:
    """Whether node syntax continues at `at`, so the word before it was an id.

    Three things follow a node id and never follow a keyword statement: the
    brackets round its label, a `:::className` suffix, and a link, which mermaid
    lets a space precede as in `end --> b`.
    """
    return bool(
        OPEN_RUN.match(line, at)
        or CLASS_SUFFIX.match(line, at)
        or LINK.match(line, skip_space(line, at))
    )


def opening_keyword(line: str, at: int) -> str:
    """The keyword this statement opens with, or "" when it opens with a node.

    A word in KEYWORDS opens a keyword statement only where a node id cannot
    continue. Until 2026-09-09 the word alone decided it, so a node whose id
    spells a keyword was skipped as styling: review of PR #25 found
    `end["<a long label>"] --> b` reaching the diagram unmeasured, with exit 0,
    where the checker before that fix measured it.
    """
    word = IDENT.match(line, at)
    if not word or word.group(0) not in KEYWORDS:
        return ""
    if continues_a_node(line, word.end()):
        return ""
    return word.group(0)


def read_keyword_statement(line: str, at: int, keyword: str) -> tuple[int, list[Label]]:
    """A statement opening with a keyword, its label if it has one, and its end.

    Only `subgraph` carries a label. The rest are graph syntax and styling.
    Their statement is skipped to its `;` and no further: until 2026-09-09 a
    line whose first word was a keyword was skipped whole, so review of PR #18
    found `classDef chg fill:#eee; c1["<eight words>"]` passing with exit 0.
    """
    end = statement_end(line, at)
    if keyword != SUBGRAPH:
        return end, []
    return end, [("cluster", "", subgraph_title(line[at:end]))]


def scan(line: str) -> Scanned:
    """Every label on one line, its links, and the first part it cannot read.

    A label is (kind, node id, label text). The line is read as mermaid writes
    it: statements separated by `;`, each a node, then a link, then a node, for
    as long as it runs. Nothing is skipped -- a label the checker cannot read is
    a label nothing has checked, and it reaches the diagram unmeasured.

    The labels already measured are returned alongside the error rather than
    thrown away with it. A line can hold an over-budget label and, after it, a
    statement the checker cannot read, and an author who is told only about the
    second one fixes it and then learns about the first.

    Until 2026-09-09 the scan stopped at the first `;`, so review of PR #18
    found `a["p"]; b["q"]; c["r"]` measured only the label of `a`.

    The links are counted here because here is where they are already parsed. A
    second reader of the same syntax drifts from this one, and a regex over the
    raw line finds the `-->` inside a quoted label.
    """
    found: list[Label] = []
    links = 0
    at = skip_space(line, 0)
    starting, expect_node = True, True
    try:
        while at < len(line):
            if line[at] == ";":
                at, starting, expect_node, labels = at + 1, True, True, []
            elif starting and (keyword := opening_keyword(line, at)):
                at, labels = read_keyword_statement(line, at, keyword)
            elif line[at] == "&" and not expect_node:
                at, expect_node, labels = at + 1, True, []
            elif expect_node:
                at, labels = read_node(line, at)
                starting, expect_node = False, False
            else:
                at, labels, states = read_link(line, at)
                if states:
                    links += 1
                expect_node = True
            found += labels
            at = skip_space(line, at)
    except LabelSyntax as unreadable:
        return Scanned(found, links, str(unreadable))
    return Scanned(found, links, None)


def subgraph_title(statement: str) -> str:
    """The title of one subgraph statement, from its brackets or from the rest.

    A statement, never a line: `subgraph s["a"]; x --> y` read as a line gives a
    title running to the last `]` on it, which is node syntax and not a title.
    """
    opened, closed = statement.find("["), statement.rfind("]")
    if 0 <= opened < closed:
        return statement[opened + 1 : closed].strip().strip('"').strip()
    return statement[len(SUBGRAPH) :].strip().strip('"').strip()


def measure(where: str, subject: str, text: str, max_words: int) -> list[str]:
    """One label against both budgets: its words, then its rendered width."""
    problems: list[str] = []
    count = len(words(text))
    if count > max_words:
        problems.append(
            f"{where}: {subject} has {count} words, at most {max_words} allowed"
        )
    size = width(text)
    if size > MAX_LABEL_CHARS:
        problems.append(
            f"{where}: {subject} is {size} characters, "
            f"at most {MAX_LABEL_CHARS} allowed"
        )
    return problems


def measure_short_label(where: str, kind: str, text: str) -> list[str]:
    """An edge label or a subgraph title, budgeted in words and characters."""
    return measure(where, f'{SHORT_LABELS[kind]} "{text}"', text, MAX_LABEL_WORDS)


def measure_node_label(where: str, ident: str, text: str) -> list[str]:
    """A node label, budgeted in lines, and in words and characters a line."""
    problems: list[str] = []
    parts = BREAK.split(text)
    if len(parts) > MAX_NODE_LINES:
        problems.append(
            f"{where}: node {ident}, label has {len(parts)} lines, "
            f"at most {MAX_NODE_LINES} allowed"
        )
    for index, part in enumerate(parts, 1):
        problems += measure(
            where, f"node {ident}, label line {index}", part, MAX_WORDS_PER_LINE
        )
    return problems


def check_line(path: str, number: int, line: str) -> Read:
    """What one line of the graph draws, and what is wrong with it."""
    where = f"{path}:{number}"
    scanned = scan(line)
    problems: list[str] = []
    for kind, ident, text in scanned.labels:
        if kind == "node":
            problems += measure_node_label(where, ident, text)
        else:
            problems += measure_short_label(where, kind, text)
    if scanned.unreadable:
        problems.append(f"{where}: {scanned.unreadable}")
    return Read(tuple(problems), scanned.links, scanned.unreadable is not None)


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
