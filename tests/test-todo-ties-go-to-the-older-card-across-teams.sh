#!/usr/bin/env bash
# Claim: inside one priority, `queue.py` puts the card Linear created first
# ahead, across team keys, and falls back to the card number only for cards
# that carry no creation date.
#
# The failure it prevents: ties were broken by the card NUMBER alone. Linear
# numbers each team key on its own, so XYZ-3 can be a year younger than
# ABC-40, and a board that picks up two teams' cards dispatched the newer card
# first, again and again, while the older one waited behind every newcomer on
# the other team. Oldest first is the rule the number stood in for.
#
# It drives the real script over a pipe, as test-todo-queue-order.sh does.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
queue="$root/skills/board/queue.py"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

orders() {  # $1 claim, $2 wanted stdout, $3 JSON on stdin
  local got
  got="$(printf '%s' "$3" | "$queue" 2>&1)"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got]"
}

orders "an older card on another team goes first despite its higher number" \
  "$(printf 'ABC-40\nXYZ-3')" \
  '[{"identifier":"XYZ-3","priority":2,"createdAt":"2026-09-01T00:00:00.000Z"},
    {"identifier":"ABC-40","priority":2,"createdAt":"2025-09-01T00:00:00.000Z"}]'

orders "priority still outranks age" \
  "$(printf 'XYZ-3\nABC-40')" \
  '[{"identifier":"XYZ-3","priority":1,"createdAt":"2026-09-01T00:00:00.000Z"},
    {"identifier":"ABC-40","priority":2,"createdAt":"2025-09-01T00:00:00.000Z"}]'

orders "a dated card goes ahead of an undated one in its band" \
  "$(printf 'XYZ-9\nABC-1')" \
  '[{"identifier":"ABC-1","priority":3},
    {"identifier":"XYZ-9","priority":3,"createdAt":"2026-09-01T00:00:00Z"}]'

orders "undated cards on one team still go oldest number first" \
  "$(printf 'ABC-2\nABC-10')" \
  '[{"identifier":"ABC-10","priority":3},{"identifier":"ABC-2","priority":3}]'

[[ "$fail" -eq 0 ]] && printf 'PASS: ties go to the card created first\n'
exit "$fail"
