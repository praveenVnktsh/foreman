#!/usr/bin/env bash
# An operator answers a plan by quoting it, footer included, and writing their
# question under the quote. plancomments.py scanned the whole body for a
# footer, found the quoted one, and took the reply for the board's own plan
# comment: the question was excluded from `unconsumed` and never reached the
# agent, with nothing on stderr (audit, 2026-09-30). A comment is the board's
# only when its footer is on the final non-empty line, outside a quote and
# outside a code fence.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
tool="$root/skills/board/plancomments.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

check() { # name expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

# `<pending ids> | <plan comment ids>` for a thread whose second comment has
# the given body. The first comment is always a real round-1 plan comment.
read_thread() { # body
  python3 - "$work/thread.json" "$1" <<'PY'
import json, sys
json.dump([
    {"id": "p1", "body": "```mermaid\ngraph TD; A-->B\n```\n<!-- foreman:plan round=1 consumed= -->"},
    {"id": "op1", "body": sys.argv[2]},
], open(sys.argv[1], "w"))
PY
  "$tool" <"$work/thread.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(c["id"] for c in d["unconsumed"]) + " | " + ",".join(d["plan_comments"]))
'
}

footer='<!-- foreman:plan round=1 consumed= -->'

check "a quoted plan comment with a question under it is the operator's" "op1 | p1" \
  "$(read_thread $'> ```mermaid\n> graph TD; A-->B\n> ```\n> '"$footer"$'\n\nPlease split node B.')"

check "a reply that ends inside the quote is the operator's" "op1 | p1" \
  "$(read_thread $'Please split node B:\n\n> graph TD; A-->B\n> '"$footer")"

check "a footer inside a closed code fence is the operator's" "op1 | p1" \
  "$(read_thread $'Why does it say this?\n\n```\n'"$footer"$'\n```')"

check "a footer inside an unclosed code fence is the operator's" "op1 | p1" \
  "$(read_thread $'Why does it say this?\n\n```\n'"$footer")"

check "a footer with a line of text after it is the operator's" "op1 | p1" \
  "$(read_thread "$footer"$'\nand what about rollback?')"

# The board's own shape still reads as the board's: the footer last, bare,
# with trailing blank lines allowed.
check "a footer on the final line is the board's" " | p1,op1" \
  "$(read_thread $'graph TD; C-->D\n\n'"$footer"$'\n\n')"

exit "$fail"
