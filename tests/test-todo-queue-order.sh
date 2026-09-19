#!/usr/bin/env bash
# Claim: skills/board/queue.py orders a board's Todo cards by Linear's priority,
# oldest first inside a priority, skips a card whose priority it cannot read,
# and refuses the whole batch only when a card cannot even be named.
#
# The failure it prevents: a tick that picks the next card by eye. Linear's
# scale is 0 = No priority, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low, so a
# plain ascending sort puts every UNTRIAGED card ahead of every urgent one --
# the board would then dispatch its least understood work first.
#
# PRA-197: refusing the whole batch over one card's bad priority used to stall
# every dispatch on the board, Urgent cards included, in silence -- a board
# that never dispatches looks exactly like a board with no work. A missing or
# unreadable priority now costs only its own card; the card is still refused,
# but out loud on stderr, and every other card still dispatches.
#
# PRA-342: a board where every card is unrankable used to exit 0 with empty
# stdout -- exactly what an empty Todo list produces. The tick could not tell
# a stalled board from an idle one. Exit 3 is what separates them: it means
# cards came in and not one of them could be ranked.
#
# PRA-352: that stall signal moved from 2 to 3. 2 is a usage error everywhere
# else on this board -- skills/board/waitfor.py draws the same line -- so a
# stalled board that exited 2 read to the tick the same as a mistyped
# invocation. refuses() also accepted any non-zero exit, so it could not tell
# a batch refusal from a nothing-ranked stall either; it now pins exit 1.
#
# It drives the real script over a pipe. No fixture instance, no git repository.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
queue="$root/skills/board/queue.py"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# There is one foreman and no routing: the tick hands queue.py its own board's
# cards, so every card is ranked. Each case below measures the order alone.

# $1 name, $2 expected stdout (newline separated), $3 JSON on stdin
orders() {
  local name="$1" want="$2" got
  got="$(printf '%s' "$3" | "$queue" 2>&1)"
  [[ "$got" == "$want" ]] && ok "$name" || bad "$name: wanted [$want], got [$got]"
}

# $1 name, $2 substring the refusal must contain, $3 JSON on stdin
refuses() {
  local name="$1" want="$2" got status
  got="$(printf '%s' "$3" | "$queue" 2>&1)"; status=$?
  if [[ $status -ne 1 ]]; then
    bad "$name: exited $status, wanted 1"
    return
  fi
  case "$got" in
    *"$want"*) ok "$name" ;;
    *) bad "$name: refused, but the message never says '$want': $got" ;;
  esac
}

# $1 name, $2 expected exit status (0 if some card ranked, 3 if none did),
# $3 expected stdout (newline separated, "" for none), $4 identifier the
# stderr skip line must name, $5 substring the skip reason must carry, $6
# JSON on stdin
#
# orders() and refuses() fold stderr into stdout with 2>&1, which cannot judge
# a skip: a skip writes to BOTH streams, so neither "wanted one stream" helper
# can tell it apart from an order or a refusal. queue.py is a pure filter --
# same input, same output, no side effect -- so running it twice, once with
# stderr discarded and once with stdout discarded, reads each stream on its
# own with no scratch file.
skips() {
  local name="$1" want_status="$2" want_out="$3" want_id="$4" want_word="$5" json="$6"
  local out out_status err
  out="$(printf '%s' "$json" | "$queue" 2>/dev/null)"; out_status=$?
  err="$(printf '%s' "$json" | "$queue" 2>&1 >/dev/null)"
  if [[ $out_status -ne $want_status ]]; then
    bad "$name: exited $out_status, wanted $want_status"
    return
  fi
  if [[ "$out" != "$want_out" ]]; then
    bad "$name: stdout wanted [$want_out], got [$out]"
    return
  fi
  case "$err" in
    *"skipped $want_id"*"$want_word"*) ok "$name" ;;
    *) bad "$name: stderr never reports $want_id with '$want_word': $err" ;;
  esac
}

orders "urgent, high, medium and low come out in that order" \
  "$(printf 'ABC-4\nABC-3\nABC-2\nABC-1')" \
  '[{"identifier":"ABC-1","priority":4},
    {"identifier":"ABC-2","priority":3},
    {"identifier":"ABC-3","priority":2},
    {"identifier":"ABC-4","priority":1}]'

orders "an untriaged card queues behind every triaged one" \
  "$(printf 'ABC-2\nABC-1')" \
  '[{"identifier":"ABC-1","priority":0},
    {"identifier":"ABC-2","priority":4}]'

orders "within one priority the older card goes first" \
  "$(printf 'ABC-2\nABC-9\nABC-31')" \
  '[{"identifier":"ABC-31","priority":2},
    {"identifier":"ABC-2","priority":2},
    {"identifier":"ABC-9","priority":2}]'

orders "the priority names order exactly as their numbers do" \
  "$(printf 'ABC-2\nABC-3\nABC-4\nABC-5\nABC-1')" \
  '[{"identifier":"ABC-1","priority":"No priority"},
    {"identifier":"ABC-2","priority":" urgent "},
    {"identifier":"ABC-3","priority":"HIGH"},
    {"identifier":"ABC-4","priority":"Medium"},
    {"identifier":"ABC-5","priority":"low"}]'

orders "an issue's other Linear fields are ignored" \
  "ABC-7" \
  '[{"identifier":"ABC-7","priority":1,"title":"t","state":{"name":"Todo"}}]'

orders "a float priority ranks as its integer value: 1.0 sorts as Urgent" \
  "$(printf 'ABC-1\nABC-2')" \
  '[{"identifier":"ABC-1","priority":1.0},
    {"identifier":"ABC-2","priority":4}]'

skips "a missing priority skips its own card, and the message names it" \
  0 "ABC-7" "ABC-8" "missing" \
  '[{"identifier":"ABC-7","priority":1},{"identifier":"ABC-8"}]'

skips "a null priority skips its own card rather than read as untriaged" \
  3 "" "ABC-7" "null" \
  '[{"identifier":"ABC-7","priority":null}]'

skips "a boolean priority skips its own card rather than read as urgent" \
  3 "" "ABC-7" "boolean" \
  '[{"identifier":"ABC-7","priority":true}]'

skips "a priority outside the scale skips its own card, named by value" \
  3 "" "ABC-7" "9" \
  '[{"identifier":"ABC-7","priority":9}]'

skips "a priority name Linear does not use skips its own card" \
  3 "" "ABC-7" "critical" \
  '[{"identifier":"ABC-7","priority":"critical"}]'

skips "a float that is not a whole number skips only its own card" \
  0 "ABC-2" "ABC-1" "whole number" \
  '[{"identifier":"ABC-1","priority":2.5},{"identifier":"ABC-2","priority":1}]'

skips "one unrankable card is skipped and every other card is still ordered" \
  0 "$(printf 'ABC-1\nABC-3')" "ABC-2" "missing" \
  '[{"identifier":"ABC-1","priority":1},
    {"identifier":"ABC-2"},
    {"identifier":"ABC-3","priority":4}]'

board='[{"identifier":"ABC-1","priority":null},
        {"identifier":"ABC-2","priority":true},
        {"identifier":"ABC-3","priority":9}]'
out="$(printf '%s' "$board" | "$queue" 2>/dev/null)"; out_status=$?
err="$(printf '%s' "$board" | "$queue" 2>&1 >/dev/null)"
if [[ $out_status -eq 3 && -z "$out" \
      && "$err" == *"skipped ABC-1"* && "$err" == *"skipped ABC-2"* \
      && "$err" == *"skipped ABC-3"* ]]; then
  ok "a whole board of unrankable cards exits 3, distinct from an empty Todo list, and names every card on stderr"
else
  bad "a whole board of unrankable cards: stdout=[$out] stderr=[$err] exit=$out_status"
fi

# Exit 3 is a number. The line below it is the only thing that tells the
# operator what the number means and what to do about it, so a status with no
# statement is half the signal -- and deleting the statement leaves every other
# case here green.
case "$err" in
  *"nothing was ranked"*"in Linear"*)
    ok "exit 3 says on stderr what it means and where the operator fixes it" ;;
  *)
    bad "exit 3 never states that nothing ranked, or never sends the operator to Linear: $err" ;;
esac

refuses "a malformed identifier is refused" \
  "ABC 7" \
  '[{"identifier":"ABC 7","priority":1}]'

refuses "an item that is not a JSON object is refused" \
  "object" \
  '[{"identifier":"ABC-7","priority":1},"ABC-8"]'

refuses "the same card listed twice is refused" \
  "twice" \
  '[{"identifier":"ABC-7","priority":1},{"identifier":"ABC-7","priority":2}]'

refuses "input that is not a JSON list is refused" \
  "list" \
  '{"identifier":"ABC-7","priority":1}'

refuses "input that is not JSON at all is refused" \
  "JSON" \
  'ABC-7'

got="$(printf '[]' | "$queue" 2>&1)"; status=$?
if [[ $status -eq 0 && -z "$got" ]]; then
  ok "an empty list prints nothing and exits 0"
else
  bad "an empty list printed [$got] and exited $status"
fi

out="$(printf '[]' | "$queue" extra-argument 2>/dev/null)"; out_status=$?
err="$(printf '[]' | "$queue" extra-argument 2>&1 >/dev/null)"
if [[ $out_status -eq 2 && -z "$out" && "$err" == *"usage"* ]]; then
  ok "an extra argument exits 2 and names the usage on stderr"
else
  bad "an extra argument: stdout=[$out] stderr=[$err] exit=$out_status"
fi

exit "$fail"
