#!/usr/bin/env bash
# The footer is the only thing that distinguishes a board comment from an
# operator comment: both are written through MCP as the same Linear user. So
# every question this filter answers -- what is unconsumed, what round is it,
# what footer comes next -- is answered from the footers alone, and the failure
# it exists to prevent is silent. A dropped operator comment produces no error,
# no log line and no visible difference; the card just sits there having been
# asked a question nobody read. That is what these cases are for.
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

# Read one field out of a run. `-c` keeps a list on one line so `check` can
# compare it as a string.
field() { # json-file jq-ish-key
  "$tool" <"$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = d[sys.argv[1]]
sys.stdout.write(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
' "$2"
}

# The ids the run says are unconsumed, comma-joined, in the order it printed
# them -- order is part of the contract, because brief.py replan renders the
# comments in it and the operator wrote them in that order.
pending() { # json-file
  "$tool" <"$1" | python3 -c '
import json, sys
sys.stdout.write(",".join(c["id"] for c in json.load(sys.stdin)["unconsumed"]))
'
}

# ---------------------------------------------------------------- no comments
# An empty thread is not an error and not a special case: it is a card the
# operator has not answered yet, and the board still needs round 1's footer to
# post the plan with.
echo '[]' >"$work/empty.json"
check "no comments: nothing is unconsumed"  "" "$(pending "$work/empty.json")"
check "no comments: round is 0"             "0" "$(field "$work/empty.json" round)"
check "no comments: next footer is round 1, consuming nothing" \
  "<!-- foreman:plan round=1 consumed= -->" "$(field "$work/empty.json" footer)"

# ------------------------------------------------------- no plan comment yet
# The operator commented before the plan landed. Everything on the card is
# unconsumed, and round 1 has not happened.
cat >"$work/noplan.json" <<'JSON'
[{"id": "aaa", "body": "please cover the migration path"},
 {"id": "bbb", "body": "and say what happens on rollback"}]
JSON
check "no plan comment: every comment is unconsumed, in order" \
  "aaa,bbb" "$(pending "$work/noplan.json")"
check "no plan comment: round is still 0" "0" "$(field "$work/noplan.json" round)"
check "no plan comment: next footer names both" \
  "<!-- foreman:plan round=1 consumed=aaa,bbb -->" "$(field "$work/noplan.json" footer)"
check "no plan comment: bodies come through whole" \
  '[{"id":"aaa","body":"please cover the migration path"},{"id":"bbb","body":"and say what happens on rollback"}]' \
  "$(field "$work/noplan.json" unconsumed)"

# ------------------------------------------------------ an empty consumed list
# Round 1's own footer: the board posted a plan before the operator said
# anything, so it consumed nothing. `consumed=` must parse as zero ids rather
# than as one empty id, and the plan comment itself must not come back as
# operator input -- the board answering its own plan is an infinite round loop.
cat >"$work/round1.json" <<'JSON'
[{"id": "p1", "body": "Here is the plan.\n\n<!-- foreman:plan round=1 consumed= -->"}]
JSON
check "empty consumed list: the plan comment is not operator input" \
  "" "$(pending "$work/round1.json")"
check "empty consumed list: round 1 is recorded" "1" "$(field "$work/round1.json" round)"
check "empty consumed list: the plan comment is named as one" \
  '["p1"]' "$(field "$work/round1.json" plan_comments)"

# A comment arriving after that plan is unconsumed, and round 2 consumes it.
cat >"$work/round1-answered.json" <<'JSON'
[{"id": "p1", "body": "Here is the plan.\n\n<!-- foreman:plan round=1 consumed= -->"},
 {"id": "op1", "body": "split step 3"}]
JSON
check "a comment after round 1 is unconsumed" "op1" "$(pending "$work/round1-answered.json")"
check "the next footer consumes it at round 2" \
  "<!-- foreman:plan round=2 consumed=op1 -->" "$(field "$work/round1-answered.json" footer)"

# ---------------------------------------------- several footers across rounds
# THE case this protocol exists for. `op1` is named by round 2's footer and by
# nothing after it; `op2` by round 3's. Read only the NEWEST footer and `op1`
# becomes unconsumed again, and the board re-sends a question the agent already
# answered on every tick, forever. Consumed is the union over every footer.
cat >"$work/rounds.json" <<'JSON'
[{"id": "p1",  "body": "plan v1 <!-- foreman:plan round=1 consumed= -->"},
 {"id": "op1", "body": "split step 3"},
 {"id": "p2",  "body": "plan v2 <!-- foreman:plan round=2 consumed=op1 -->"},
 {"id": "op2", "body": "now name the rollback"},
 {"id": "p3",  "body": "plan v3 <!-- foreman:plan round=3 consumed=op2 -->"},
 {"id": "op3", "body": "one more thing"}]
JSON
check "an id in an older footer but not the newest stays consumed" \
  "op3" "$(pending "$work/rounds.json")"
check "the round is the highest any footer claims" "3" "$(field "$work/rounds.json" round)"
check "the next footer is round 4" \
  "<!-- foreman:plan round=4 consumed=op3 -->" "$(field "$work/rounds.json" footer)"
check "every plan comment is named, none of them as operator input" \
  '["p1","p2","p3"]' "$(field "$work/rounds.json" plan_comments)"

# One footer may consume several ids, and a comment that landed mid-revision is
# simply absent from it -- picked up by the next tick rather than lost.
cat >"$work/multi.json" <<'JSON'
[{"id": "op1", "body": "a"},
 {"id": "op2", "body": "b"},
 {"id": "p1",  "body": "plan <!-- foreman:plan round=1 consumed=op1,op2 -->"},
 {"id": "op3", "body": "written at 14:00, while the agent was still revising"}]
JSON
check "a multi-id footer consumes all of them" "op3" "$(pending "$work/multi.json")"
check "a comment older than the newest plan comment is still unconsumed" \
  "op3" "$(pending "$work/multi.json")"

# ------------------------------------------------------------ absent footers
# A card with plenty of comments and no footer anywhere must not read as "all
# consumed". Absence of evidence is not consumption.
cat >"$work/nofooters.json" <<'JSON'
[{"id": "x1", "body": "no marker here"},
 {"id": "x2", "body": "<!-- an unrelated html comment -->"},
 {"id": "x3", "body": "mentions foreman:plan in prose, outside any marker"}]
JSON
check "no footer anywhere means nothing is consumed" \
  "x1,x2,x3" "$(pending "$work/nofooters.json")"
check "an unrelated html comment is not a footer" "0" "$(field "$work/nofooters.json" round)"

# ---------------------------------------------------------- malformed footers
# A marker that announces itself as ours and then does not parse consumes
# NOTHING, is reported, and does not swallow the comment carrying it -- an
# operator quoting a footer while they answer must not have their own words
# eaten by the string they quoted.
for bad in \
  '<!-- foreman:plan -->' \
  '<!-- foreman:plan round=2 -->' \
  '<!-- foreman:plan consumed=op1 -->' \
  '<!-- foreman:plan round=two consumed=op1 -->' \
  '<!-- foreman:plan consumed=op1 round=2 -->' \
  '<!-- foreman:plan round=2 consumed=op1, -->' \
  '<!-- foreman:plan round=2 consumed=op1,,op2 -->'
do
  python3 - "$work/bad.json" "$bad" <<'PY'
import json, sys
json.dump([{"id": "op1", "body": "answer me"},
           {"id": "b1", "body": "plan " + sys.argv[2]}],
          open(sys.argv[1], "w"))
PY
  got="$(pending "$work/bad.json" 2>/dev/null)"
  check "malformed footer consumes nothing: $bad" "op1,b1" "$got"
  check "malformed footer is reported: $bad" \
    '["b1"]' "$(field "$work/bad.json" malformed_footers 2>/dev/null)"
done

# It says so on stderr too, so a board that writes an unreadable footer is a
# visible bug rather than one extra round nobody can explain.
printf '[{"id":"b1","body":"<!-- foreman:plan round=2 -->"}]' >"$work/warn.json"
if "$tool" <"$work/warn.json" 2>"$work/warn.err" >/dev/null && \
   grep -q 'foreman:plan' "$work/warn.err"; then
  printf 'ok   a malformed footer warns on stderr and still exits 0\n'
else
  printf 'FAIL a malformed footer must warn on stderr and still exit 0\n'; fail=1
fi

# A comment carrying one good footer and one broken marker still consumes what
# the good one names. Partial credit here is safe: the good footer is evidence.
cat >"$work/mixed.json" <<'JSON'
[{"id": "op1", "body": "a"},
 {"id": "op2", "body": "b"},
 {"id": "p1",  "body": "<!-- foreman:plan round=1 consumed=op1 --> <!-- foreman:plan bogus -->"}]
JSON
check "a good footer beside a broken marker still consumes" \
  "op2" "$(pending "$work/mixed.json" 2>/dev/null)"
check "and the broken marker is still reported" \
  '["p1"]' "$(field "$work/mixed.json" malformed_footers 2>/dev/null)"

# ------------------------------------------------------------------- replies
# A reply nested under a plan comment is a reply to the plan. Reading only the
# top level would drop exactly the comments this file exists to find.
cat >"$work/threaded.json" <<'JSON'
[{"id": "p1", "body": "plan <!-- foreman:plan round=1 consumed= -->",
  "children": [{"id": "op1", "body": "threaded reply"}]},
 {"id": "p2", "body": "plan <!-- foreman:plan round=2 consumed=op1 -->",
  "children": {"nodes": [{"id": "op2", "body": "reply as a graphql connection"}]}}]
JSON
check "a threaded reply is found, and one already consumed stays consumed" \
  "op2" "$(pending "$work/threaded.json")"

# ------------------------------------------------------------- input shapes
# The wrapper object Linear MCP sometimes returns must not read as an object
# with no comments -- that answer is indistinguishable from a quiet card.
printf '{"comments":[{"id":"op1","body":"hi"}]}' >"$work/wrapped.json"
check "a {comments: [...]} wrapper is read, not silently emptied" \
  "op1" "$(pending "$work/wrapped.json")"

refuses() { # name file needle
  if err="$("$tool" <"$2" 2>&1 >/dev/null)"; then
    printf 'FAIL %s: must be refused\n' "$1"; fail=1
  else
    case "$err" in *"$3"*) printf 'ok   %s\n' "$1" ;;
      *) printf 'FAIL %s: error did not mention %s: %s\n' "$1" "$3" "$err"; fail=1 ;; esac
  fi
}

printf 'not json at all' >"$work/notjson.json"
refuses "stdin that is not JSON is refused" "$work/notjson.json" "valid JSON"

printf '{"nodes":[]}' >"$work/wrongobject.json"
refuses "an object that is not a comment list is refused" "$work/wrongobject.json" "comments"

printf '["just a string"]' >"$work/notobjects.json"
refuses "a list of non-objects is refused" "$work/notobjects.json" "JSON object"

printf '[{"body":"no id"}]' >"$work/noid.json"
refuses "a comment with no id is refused" "$work/noid.json" "comment id"

# An id holding a comma would desynchronise the footer it is written into, the
# same way an embedded NUL desynchronises bin/contract.py's wire format.
printf '[{"id":"a,b","body":"x"}]' >"$work/commaid.json"
refuses "an id containing a comma is refused" "$work/commaid.json" "comment id"

# Two rows under one id make "was this consumed" depend on which copy the loop
# kept -- one of the operator's comments is then dropped or answered twice.
printf '[{"id":"op1","body":"a"},{"id":"op1","body":"b"}]' >"$work/dupe.json"
refuses "a duplicated comment id is refused" "$work/dupe.json" "twice"

# ------------------------------------------------------------ round tripping
# What the tool says the next footer is, appended to a plan comment, must make
# every comment it named consumed on the following read. If these two ever
# disagree the board loops on the same input and nothing says so.
cat >"$work/trip.json" <<'JSON'
[{"id": "p1",  "body": "plan <!-- foreman:plan round=1 consumed= -->"},
 {"id": "op1", "body": "one"},
 {"id": "op2", "body": "two"}]
JSON
footer="$(field "$work/trip.json" footer)"
python3 - "$work/trip.json" "$work/trip2.json" "$footer" <<'PY'
import json, sys
comments = json.load(open(sys.argv[1]))
comments.append({"id": "p2", "body": "plan v2\n\n" + sys.argv[3]})
json.dump(comments, open(sys.argv[2], "w"))
PY
check "the emitted footer consumes exactly what it named" "" "$(pending "$work/trip2.json")"
check "and the round advances by one" "2" "$(field "$work/trip2.json" round)"

# ------------------------------------------------------------------ no network
# reconcile.py has never held a Linear key and this is not the change that gives
# the board one. A filter that reaches for the network is also a filter nobody
# can test, which for a mechanism whose failure is silence is the whole risk.
if grep -nE '^[[:space:]]*(import|from)[[:space:]]+(urllib|requests|httpx|socket|subprocess|http)\b' "$tool" >/dev/null; then
  printf 'FAIL plancomments.py imports a network or subprocess module\n'; fail=1
else
  printf 'ok   plancomments.py reaches for no network and no key\n'
fi

if [[ -x "$tool" ]]; then printf 'ok   plancomments.py is executable\n'
else printf 'FAIL plancomments.py is not executable\n'; fail=1; fi

exit "$fail"
