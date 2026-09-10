#!/usr/bin/env bash
# `board.toml`'s `[docs] required` list is quoted verbatim into every build
# prompt (skills/board/brief.py, via bin/contract.py), so a required doc that
# names five states while `bin/resolve-ids.py`'s STATE_ROLES pins seven tells
# the very agent changing STATE_ROLES that a column it can see does not exist.
# That happened on 2026-09-09: `Plan` and `Needs Human` had joined the loop,
# but docs/specs/2026-08-27-autonomous-board-runner-design.md still said "the
# five states and four labels" and named none of them.
#
# The check is narrow on purpose. It pins ONE sentence per document -- the one
# of the shape "<count> states and <count> labels" -- and reads both numbers
# against len(STATE_ROLES) and len(LABEL_ROLES). No other number in any doc is
# looked at. An earlier version flagged every number standing before the word
# "states", anywhere. Correct prose counting a subset of the columns -- "the
# two states a card can be dispatched from" -- then reddened the whole suite,
# and a red suite blocks every merge on the board. That is a worse failure
# than the one this test prevents.
#
# Three properties this file is built on:
#   - It reads the required docs off the contract, never off a list retyped
#     here. A fourth doc added to board.toml is covered without an edit here.
#   - It reads both tables out of bin/resolve-ids.py rather than retyping the
#     names, because a test that restates what it checks stays green while the
#     source says something else.
#   - It matches each document on its own, with whitespace normalised first.
#     Searching the docs concatenated let an ordinary English word in one doc
#     -- `Done`, `Todo`, `Backlog` -- stand in for a column name a different
#     doc was supposed to carry. Scanning line by line let a paragraph reflow
#     hide a stale count across a line break.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
fail=0

ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# --- Read REQUIRED_DOCS off the contract, not off a list retyped here -------
#
# Through a temp file, never `$(...)`: bash 3.2 discards NUL bytes in command
# substitution (skills/board/config.sh explains this at length), and the wire
# format between contract.py and every shell consumer is NUL-separated.
pairs_file="$(mktemp)"
trap 'rm -f "$pairs_file"' EXIT
if ! "$root/bin/contract.py" "$root/board.toml" > "$pairs_file"; then
  bad "bin/contract.py board.toml refused to load; nothing else here can run"
  exit "$fail"
fi

docs_result="$(python3 - "$pairs_file" "$root" <<'PY'
import sys

pairs_file, root = sys.argv[1], sys.argv[2]
raw = open(pairs_file, "rb").read().split(b"\0")
pairs = dict(zip(raw[::2], raw[1::2]))
value = pairs.get(b"REQUIRED_DOCS", b"").decode()
docs = [d for d in value.split(" ") if d]

if not docs:
    print("FAIL board.toml's [docs] required is empty; this test would check nothing")
    sys.exit(0)

import os
missing = [d for d in docs if not os.path.isfile(os.path.join(root, d))]
if missing:
    print("FAIL these required docs do not exist on disk: " + ", ".join(missing))
    sys.exit(0)

print("OK " + " ".join(docs))
PY
)"
case "$docs_result" in
  "OK "*)
    # Doc paths are board.toml file paths -- none contain a space -- so plain
    # word splitting recovers the list this test's own python just printed.
    # shellcheck disable=SC2206
    required_docs=(${docs_result#OK })
    ok "REQUIRED_DOCS from bin/contract.py names ${#required_docs[@]} doc(s), all present on disk"
    ;;
  *)
    bad "${docs_result#FAIL }"
    exit "$fail"
    ;;
esac

# --- Read both tables out of resolve-ids.py, and check the pinned sentence --
#
# One python pass does every check, so the two parses -- and the refusal if
# either comes back empty -- happen once.
check_output="$(python3 - "$root/bin/resolve-ids.py" "$root" "${required_docs[@]}" <<'PY'
import os
import re
import sys

# Doc paths come off the contract relative to the repository root, and this
# test must answer the same from any working directory -- run-all.sh runs
# each file with `bash "$t"` and never cd's. So every read joins $root,
# while the messages below keep the relative path the contract names.
resolver_path, root, doc_paths = sys.argv[1], sys.argv[2], sys.argv[3:]
resolver = open(resolver_path, encoding="utf-8").read()


def parse_roles(table, role_prefix):
    """Pull the display names out of one `("ROLE", "Name")` table."""
    block = re.search(re.escape(table) + r" = \[(.*?)\]", resolver, re.DOTALL)
    if not block:
        return []
    row = r'\("' + role_prefix + r'_[A-Z_]+",\s*"([^"]+)"\)'
    return re.findall(row, block.group(1))


states = parse_roles("STATE_ROLES", "STATE")
labels = parse_roles("LABEL_ROLES", "LABEL")

empty = [name for name, roles in (("STATE_ROLES", states), ("LABEL_ROLES", labels))
         if not roles]
if empty:
    print("REFUSE " + " and ".join(empty) + " in bin/resolve-ids.py parsed to "
          "nothing; this test would check nothing")
    sys.exit(0)

# Both directions off one list: the index is the value, the list is the word.
WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven",
         "eight", "nine", "ten", "eleven", "twelve"]
WORD_TO_N = {word: n for n, word in enumerate(WORDS)}
NUMBER = r"(?:" + "|".join(WORDS) + r"|\d+)"

# The one sentence shape this test reads a count from, in any required doc.
# docs/specs/2026-08-27-autonomous-board-runner-design.md carries it today:
# "and the seven states and five labels -- to ids".
PINNED = re.compile(r"\b(" + NUMBER + r")\s+states\s+and\s+(" + NUMBER + r")\s+labels\b",
                    re.IGNORECASE)

# How far either side of a match to look for a sentence boundary. A heading
# carries no full stop, so an unbounded search would quote half a document.
QUOTE_WINDOW = 200


def number_of(token):
    token = token.lower()
    return WORD_TO_N[token] if token in WORD_TO_N else int(token)


def sentence_around(text, start, end):
    """Quote the sentence holding a match.

    A line number is gone once the document is normalised, so the quote is
    what tells the reader where to go.
    """
    left = text.rfind(". ", max(0, start - QUOTE_WINDOW), start)
    begin = left + 2 if left >= 0 else max(0, start - QUOTE_WINDOW)
    right = text.find(". ", end, end + QUOTE_WINDOW)
    stop = right + 1 if right >= 0 else min(len(text), end + QUOTE_WINDOW)
    return text[begin:stop]


problems = []
carriers = []

for path in doc_paths:
    raw = open(os.path.join(root, path), encoding="utf-8").read()
    # Every run of whitespace becomes one space, so a paragraph reflow cannot
    # split a count away from the noun it counts.
    text = re.sub(r"\s+", " ", raw)

    matches = list(PINNED.finditer(text))
    if not matches:
        continue
    carriers.append(path)

    for match in matches:
        found_states = number_of(match.group(1))
        found_labels = number_of(match.group(2))
        if (found_states, found_labels) == (len(states), len(labels)):
            continue
        problems.append(
            f"{path} says {found_states} states and {found_labels} labels, but "
            f"bin/resolve-ids.py has {len(states)} states and {len(labels)} "
            f"labels: {sentence_around(text, match.start(), match.end())!r}")

    # A doc that pins the counts has to name the columns too -- checked in
    # this doc alone, because `Done`, `Todo` and `Backlog` are ordinary
    # English words that another required doc will contain by accident.
    # Case-sensitive, on word boundaries, so `Plan` does not match `plans`.
    for name in states:
        if not re.search(r"\b" + re.escape(name) + r"\b", text):
            problems.append(
                f"{path} pins the counts but never names the state `{name}` "
                f"(bin/resolve-ids.py's STATE_ROLES pins it)")

if not carriers:
    problems.append(
        "no required doc says \"<count> states and <count> labels\", so this "
        "check reads nothing; looked in: " + ", ".join(doc_paths))

if problems:
    print("FAIL " + "\n     ".join(problems))
else:
    print(f"OK {len(states)} states and {len(labels)} labels, pinned and named in "
          + ", ".join(carriers))
PY
)"

case "$check_output" in
  "OK "*)
    ok "${check_output#OK }"
    ;;
  "REFUSE "*)
    bad "${check_output#REFUSE }"
    ;;
  "FAIL "*)
    bad "${check_output#FAIL }"
    ;;
  *)
    bad "unexpected output checking the required docs against bin/resolve-ids.py: $check_output"
    ;;
esac

exit "$fail"
