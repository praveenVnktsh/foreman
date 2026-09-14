#!/usr/bin/env bash
# Claim: skills/board/queue.py filters a board's Todo candidates to one
# installation before it ranks them, on route.py's verdict, and that filter
# never changes the ranking of what survives it.
#
# docs/specs/2026-09-14-installations-per-harness-design.md, "Routing": a card
# belongs to exactly one installation, by its `foreman:<name>` label; the
# default installation also owns every unlabelled card. Two installations
# ranking the same foreign card is the double-dispatch this design exists to
# prevent, so this file is what proves queue.py never does that.
#
# It drives the real script over a pipe, exactly like
# tests/test-todo-queue-order.sh, which this file does not repeat: that file
# already covers ranking once routing has nothing left to filter. This file
# adds the installation, so every JSON fixture here carries "labels" and every
# invocation carries --installation, --default and --siblings.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
queue="$root/skills/board/queue.py"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# queue.py is a pure filter -- same input, same output, no side effect -- so
# running it twice, once with stderr discarded and once with stdout discarded,
# reads each stream on its own with no scratch file. test-todo-queue-order.sh's
# skips() is the same pattern; this file needs it for every case here, not
# only skips, because routing puts something worth checking on both streams.
#
# $1 name, $2 want_status, $3 want_out (newline separated, "" for none),
# $4 want_err_substring ("" to skip the stderr check), $5 args (space
# separated -- every fixture's flags fit on one line), $6 JSON on stdin
route_case() {
  local name="$1" want_status="$2" want_out="$3" want_err="$4" args="$5" json="$6"
  local out out_status err
  out="$(printf '%s' "$json" | "$queue" $args 2>/dev/null)"; out_status=$?
  err="$(printf '%s' "$json" | "$queue" $args 2>&1 >/dev/null)"
  if [[ $out_status -ne $want_status ]]; then
    bad "$name: exited $out_status, wanted $want_status (stderr: $err)"
    return
  fi
  if [[ "$out" != "$want_out" ]]; then
    bad "$name: stdout wanted [$want_out], got [$out]"
    return
  fi
  if [[ -n "$want_err" && "$err" != *"$want_err"* ]]; then
    bad "$name: stderr never carries '$want_err': $err"
    return
  fi
  ok "$name"
}

# --- an installation keeps its own labelled cards and ranks them as before ---
# GraphQL shape: issue['labels']['nodes'][i]['name']. Ranking (urgent before
# low) is test-todo-queue-order.sh's own claim; this repeats just enough of it
# to show routing left the order untouched.
route_case \
  "an installation keeps its own labelled cards and ranks them as before" \
  0 "$(printf 'ABC-2\nABC-1')" "" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":4,"labels":{"nodes":[{"name":"foreman:claude"}]}},
    {"identifier":"ABC-2","priority":1,"labels":{"nodes":[{"name":"foreman:claude"}]}}]'

# --- drops a card labelled for a sibling and names it on stderr ---
# Flat list of names -- the second shape route.py reads -- is the shape
# tolerance claim: the GraphQL case above and this one route identically.
route_case \
  "drops a card labelled for a sibling and names it on stderr" \
  0 "ABC-1" "dropped ABC-2" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":["foreman:claude"]},
    {"identifier":"ABC-2","priority":1,"labels":["foreman:codex"]}]'

# --- keeps an unlabeled card only under --default ---
# Flat list of {"name": ...} objects -- the third shape route.py reads.
route_case \
  "an unlabelled card is dropped when this installation is not the default" \
  0 "" "dropped ABC-1" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":[{"name":"other-team"}]}]'

route_case \
  "the same unlabelled card is kept once --default is passed" \
  0 "ABC-1" "" \
  "--installation claude --default --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":[{"name":"other-team"}]}]'

# --- a label naming no sibling is reported, and exit 3 means nothing ranked ---
# route.py's UnknownOwner message ("names no installation on this machine")
# surfaces inside queue.py's own "dropped" line, so this checks for both: the
# card is named, and the reason is not silently swallowed into "foreign".
route_case \
  "a label naming no sibling is reported, and exits 3 when it was the only card" \
  3 "" "dropped ABC-1: ABC-1: label foreman:ghost names no installation on this machine" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":["foreman:ghost"]}]'

# One rankable card beside that unroutable one. This is the pair the exit-code
# contract turns on: exit 3 promises an EMPTY stdout, so a batch that produced
# an order cannot use it to report the label -- an order the tick may not act
# on is worse than no order at all. The unroutable card is still named on
# stderr on this run, which is where SKILL.md tells the tick to read it and
# report it to the operator who fixes the label in Linear.
route_case \
  "one rankable card beside an unroutable one exits 0 with the order, and still names it" \
  0 "ABC-1" "dropped ABC-2: ABC-2: label foreman:ghost names no installation on this machine" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":["foreman:claude"]},
    {"identifier":"ABC-2","priority":1,"labels":["foreman:ghost"]}]'

# --- a batch that is entirely foreign exits 0 with empty stdout ---
# This is the case route.py's own docstring calls out: a board that is mostly
# a sibling's work is not a stalled board here, so it must NOT exit 3 the way
# the unroutable case just above does.
route_case \
  "a batch that is entirely foreign exits 0 with empty stdout" \
  0 "" "" \
  "--installation claude --siblings claude,codex" \
  '[{"identifier":"ABC-1","priority":1,"labels":["foreman:codex"]},
    {"identifier":"ABC-2","priority":2,"labels":["foreman:codex"]}]'

# --- the old argv (no --installation) exits 2 ---
# --installation and --siblings are both required, so a caller still on the
# pre-routing argv gets a usage error, not a batch that ranks every card on
# the board -- the double-dispatch this design exists to prevent.
out="$(printf '[{"identifier":"ABC-1","priority":1}]' | "$queue" 2>/dev/null)"; out_status=$?
err="$(printf '[{"identifier":"ABC-1","priority":1}]' | "$queue" 2>&1 >/dev/null)"
if [[ $out_status -eq 2 && -z "$out" && "$err" == *"usage"* ]]; then
  ok "the old argv, with no --installation, exits 2"
else
  bad "the old argv: stdout=[$out] stderr=[$err] exit=$out_status"
fi

exit "$fail"
