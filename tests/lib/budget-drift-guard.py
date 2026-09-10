#!/usr/bin/env python3
"""Report every budget number a document states outside its one copy of a rule.

    budget-drift-guard.py <file> "$(bin/check-plan-graph.py --limits)"

The budget belongs to `bin/check-plan-graph.py`. A document may reproduce it
once, verbatim, and the second argument is that wording. Every other number the
document names beside "words", "lines" or "characters" is a second copy, and a
second copy drifts out of step with the constant the moment one changes.

Exit 0 when nothing outside the exempt copy names such a number. Exit 1 when
something does, printing each as `path:line: phrase`. Exit 2 when there is no
answer to give: the file cannot be read, or it states no copy of the rule at
all, so there is nothing to exempt. The caller reports the three differently,
because a crash reported as drift sends the reader to edit a correct file.

Any number is searched for, never only the ones the rule prints today. Review
of PR #34 on 2026-09-10 caught a version scoped to today's numbers: when a
limit changes, the old number stays in the prose, and that stale copy -- the
drift this file exists to catch -- was the one thing it could no longer see.

Three earlier faults, from review of PR #30 on the same day. The guard read the
file line by line, so "80 characters", split by the prose wrap, went unreported
for as long as it existed. It typed the limits of the day into the test itself.
And it located the exempt copy by the fence around it, so a language tag on
that fence shifted the range and reported the exempt copy as drift.
"""

from __future__ import annotations

import pathlib
import re
import sys

USAGE = 'usage: budget-drift-guard.py <file> "<the rule, as it prints>"'

# A number as English writes it: digits, a word, or a compound like
# "sixty-four", which is also written with a space. A budget is spelled as
# often as it is typed -- "a four-word budget" is what review found on
# 2026-09-09 -- so digits alone leave half the copies unsearched.
ONES = (
    "one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen"
).split()
TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()
COMPOUND = rf"(?:{'|'.join(TENS)})[\s-](?:{'|'.join(ONES)})"
NUMBER = rf"\d+|{COMPOUND}|{'|'.join(TENS + ONES)}"

# What a label budget is counted in. A number beside one of these words reads
# as the budget whether it was meant to or not, which is why the rule gets one
# copy and the prose points at it.
UNITS = r"(?:word|line|character)s?"

BUDGET_NUMBER = re.compile(rf"\b(?:{NUMBER})[\s-]+{UNITS}\b", re.IGNORECASE)


def exempt_span(text: str, rule: str) -> tuple[int, int] | None:
    """Where the document's one copy of the rule sits, however it wraps.

    Every run of whitespace in the rule matches a run of whitespace in the
    document, so a copy the prose wrapped is found where it is. The span is the
    whole exemption, so no fence has to be located: a language tag on the fence
    around it moves nothing.
    """
    wrapped = r"\s+".join(re.escape(word) for word in rule.split())
    found = re.search(wrapped, text)
    return found.span() if found else None


def drift(text: str, exempt: tuple[int, int]) -> list[tuple[int, str]]:
    """Every budget number outside the exempt copy, by line and as written."""
    found: list[tuple[int, str]] = []
    for hit in BUDGET_NUMBER.finditer(text):
        if exempt[0] <= hit.start() < exempt[1]:
            continue
        # The line is counted here rather than read from a line-by-line scan,
        # which is what missed a copy the wrap had split in two.
        line = text.count("\n", 0, hit.start()) + 1
        found.append((line, " ".join(hit.group().split())))
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    path, rule = pathlib.Path(argv[0]), argv[1]
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, ValueError) as unreadable:
        print(f"{path}: cannot read: {unreadable}", file=sys.stderr)
        return 2
    exempt = exempt_span(text, rule)
    if exempt is None:
        print(f"{path}: states no copy of the rule, so nothing is exempt", file=sys.stderr)
        return 2
    found = drift(text, exempt)
    for line, said in found:
        print(f"{path}:{line}: {said}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
