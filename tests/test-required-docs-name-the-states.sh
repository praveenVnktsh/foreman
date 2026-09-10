#!/usr/bin/env bash
# `board.toml`'s `[docs] required` list is quoted verbatim into every build
# prompt (skills/board/brief.py, via bin/contract.py), so a required doc that
# names five states while `bin/resolve-ids.py`'s STATE_ROLES pins seven tells
# the very agent changing STATE_ROLES that a column it can see does not exist.
# That happened on 2026-09-09: `Plan` and `Needs Human` had joined the loop,
# but docs/specs/2026-08-27-autonomous-board-runner-design.md still said "the
# five states and four labels" and named none of them.
#
# This reads the required docs off the contract, never off a hardcoded list --
# a fourth doc added to board.toml is covered by this test without an edit
# here -- and it reads STATE_ROLES out of resolve-ids.py rather than retyping
# the names, because a test that restates what it checks stays green while the
# source says something else.
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

# --- Parse STATE_ROLES out of resolve-ids.py, and check both claims --------
#
# One python pass does both checks (names present, no stale count) so the
# STATE_ROLES parse -- and the refusal if it comes back empty -- happens once.
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

m = re.search(r"STATE_ROLES = \[(.*?)\]", resolver, re.DOTALL)
roles = re.findall(r'\("STATE_[A-Z_]+",\s*"([^"]+)"\)', m.group(1)) if m else []
if not roles:
    print("REFUSE STATE_ROLES in bin/resolve-ids.py parsed to nothing; "
          "this test would check nothing")
    sys.exit(0)

docs = {p: open(os.path.join(root, p), encoding="utf-8").read() for p in doc_paths}
lines = {p: text.split("\n") for p, text in docs.items()}
all_text = "\n".join(docs.values())

problems = []

# Claim 1: every STATE_ROLES display name appears somewhere in the required
# docs, taken together, case-sensitively and on word boundaries -- so `Plan`
# does not match `plans`.
for name in roles:
    if not re.search(r"\b" + re.escape(name) + r"\b", all_text):
        problems.append(f"no required doc names the state `{name}` "
                         f"(bin/resolve-ids.py's STATE_ROLES pins it)")

# Claim 2: no required doc quotes a stale state count. A number word or a
# digit run immediately before "states" (case-insensitive) must spell
# len(STATE_ROLES) -- today's count -- or it is describing a board that no
# longer exists.
WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven",
         "eight", "nine", "ten", "eleven", "twelve"]
word_to_n = {w: i for i, w in enumerate(WORDS)}
count_re = re.compile(r"\b(" + "|".join(WORDS) + r"|\d+)\s+states\b", re.IGNORECASE)
expected = len(roles)

for path, text in lines.items():
    for lineno, line in enumerate(text, start=1):
        for match in count_re.finditer(line):
            token = match.group(1).lower()
            found = word_to_n[token] if token in word_to_n else int(token)
            if found != expected:
                problems.append(
                    f"{path}:{lineno} says {found} states, but bin/resolve-ids.py's "
                    f"STATE_ROLES now has {expected}: {line.strip()!r}")

if problems:
    print("FAIL " + "\n     ".join(problems))
else:
    print(f"OK {expected} states, all named, no stale count")
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
    bad "unexpected output parsing STATE_ROLES against the required docs: $check_output"
    ;;
esac

exit "$fail"
