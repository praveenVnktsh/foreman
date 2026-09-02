#!/usr/bin/env bash
# Claim: skills/board/queue.py orders a board's Todo cards by Linear's priority,
# oldest first inside a priority, and refuses anything it cannot rank.
#
# The failure it prevents: a tick that picks the next card by eye. Linear's
# scale is 0 = No priority, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low, so a
# plain ascending sort puts every UNTRIAGED card ahead of every urgent one --
# the board would then dispatch its least understood work first. A missing
# priority is refused for the same reason: a tick that forgot to ask Linear for
# the field would otherwise get a confident order that ignores every priority on
# the board, with exit code 0 and nothing to say so.
#
# It drives the real script over a pipe. No fixture instance, no git repository.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
queue="$root/skills/board/queue.py"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# $1 name, $2 expected stdout (newline separated), $3 JSON on stdin
orders() {
  local name="$1" want="$2" got
  got="$(printf '%s' "$3" | "$queue" 2>&1)"
  [[ "$got" == "$want" ]] && ok "$name" || bad "$name: wanted [$want], got [$got]"
}

# $1 name, $2 substring the refusal must contain, $3 JSON on stdin
refuses() {
  local name="$1" want="$2" got
  if got="$(printf '%s' "$3" | "$queue" 2>&1)"; then
    bad "$name: accepted, printed [$got]"
    return
  fi
  case "$got" in
    *"$want"*) ok "$name" ;;
    *) bad "$name: refused, but the message never says '$want': $got" ;;
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

refuses "a missing priority is refused, and the message names the card" \
  "ABC-8" \
  '[{"identifier":"ABC-7","priority":1},{"identifier":"ABC-8"}]'

refuses "a null priority is refused rather than read as untriaged" \
  "ABC-7" \
  '[{"identifier":"ABC-7","priority":null}]'

refuses "a boolean priority is refused rather than read as urgent" \
  "boolean" \
  '[{"identifier":"ABC-7","priority":true}]'

refuses "a priority outside the scale is refused by value" \
  "9" \
  '[{"identifier":"ABC-7","priority":9}]'

refuses "a priority name Linear does not use is refused" \
  "critical" \
  '[{"identifier":"ABC-7","priority":"critical"}]'

refuses "a malformed identifier is refused" \
  "ABC 7" \
  '[{"identifier":"ABC 7","priority":1}]'

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

exit "$fail"
