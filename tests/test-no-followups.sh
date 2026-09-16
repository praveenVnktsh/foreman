#!/usr/bin/env bash
# The follow-up step is gone from SKILL.md, and the single review round that
# replaced it is written down.
#
# SKILL.md is not documentation about the board: the tick reads it and does what
# it says. So a step deleted from the design and left in this file is a step the
# board still runs -- cards written into Backlog after every merge, on a knob
# bin/contract.py no longer emits, by a tick that reads the empty MAX_FOLLOWUPS
# as a cap of nothing. Nothing else catches that: the contract test proves the
# key is gone from the contract, and this file is the only place the instruction
# to use it could survive.
#
# The two labels stay. Cards written before this change still carry follow-up
# and follow-ups-written, and bin/resolve-ids.py still resolves both so those
# cards keep loading -- so the rule here is not "the word is absent" but "the
# word survives only in the Labels table, saying nothing writes it".
#
# NO APOSTROPHE AND NO BACKTICK below reaches the here-doc. The whole Python
# block runs inside a command substitution, which bash tokenises before the
# quoted here-doc protects anything, so one unpaired quote character kills the
# file at parse time with no test having run.
#
# See docs/specs/2026-09-15-cleanup-and-light-review-design.md.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
skill="$root/skills/board/SKILL.md"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

if ! out="$(python3 - "$skill" 2>&1 <<'PY'
import pathlib, re, sys

lines = pathlib.Path(sys.argv[1]).read_text().split("\n")
text = "\n".join(lines)
problems = []

# A heading is a step the tick works through. One naming follow-ups is the
# deleted section back, whatever it now says inside.
headings = [l for l in lines if re.match(r"(?i)^#{1,6} .*follow-?ups?\b", l)]
if headings:
    problems.append("SKILL.md still carries a follow-ups heading:\n  "
                    + "\n  ".join(headings))

# The knob bin/contract.py stopped emitting. Named here, it reaches the config
# snippet the tick prints as an empty value under set -u.
if "MAX_FOLLOWUPS" in text:
    hits = [l for l in lines if "MAX_FOLLOWUPS" in l]
    problems.append("SKILL.md still names MAX_FOLLOWUPS, which the contract no "
                    "longer emits:\n  " + "\n  ".join(hits))


def section_of(index):
    for line in reversed(lines[:index + 1]):
        if line.startswith("## "):
            return line[3:].strip()
    return "(before the first section)"


# Every surviving mention belongs to the Labels table, which explains that the
# two labels are kept only so older cards still resolve. A mention anywhere else
# is an instruction, because everywhere else in this file is a step.
stray = [(i, l) for i, l in enumerate(lines)
         if re.search(r"(?i)follow-?ups?\b", l) and section_of(i) != "Labels"]
if stray:
    problems.append(
        "SKILL.md mentions follow-ups outside the Labels table, where the only "
        "thing left to say about them is that nothing writes them:\n  "
        + "\n  ".join("%d (%s): %s" % (i + 1, section_of(i), l.strip())
                      for i, l in stray))

# The single review round that replaced them. merged-after-fix is the history
# entry SKILL.md logs before merging a fixed card with no second reviewer, and
# "board-failed: fix unresolved" is the released reason for a fix agent that
# pushed nothing. reconcile.py computes the verdict behind each; a document that
# names neither is a tick that writes neither.
for needle, what in (
    ("merged-after-fix", "the history entry logged before a fix merges"),
    ("board-failed: fix unresolved",
     "the released reason for a finding the fix agent could not resolve"),
):
    if needle not in text:
        problems.append("SKILL.md never names " + needle + " -- " + what)

if problems:
    sys.exit("\n\n".join(problems))
print("no follow-up step survives; merged-after-fix and the unresolved-fix exit "
      "are both written down")
PY
)"; then
  bad "$out"
else
  ok "$out"
fi

exit "$fail"
