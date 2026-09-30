#!/usr/bin/env bash
# Review is light: one reviewer, one round, two severities. The review prompt
# has to say all of that, because the reviewer runs a skill that grades
# CRITICAL, WARNING and NOTE and promotes what several personas found. Left to
# the skill, a style point found twice came back as a WARNING-promoted-to-
# CRITICAL, and a severity the board does not read blocks the card.
#
# It also pins round 2's wording. A blocking finding buys one fix and never a
# second review, so round 2 exists only after a CLEAN round whose head moved.
# The prompt used to tell that reviewer an author had pushed a fix for blocking
# findings, which never happened.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
brief="$root/skills/board/brief.py"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# `review` reads no board config, so no fixture is needed.
prompt="$("$brief" review --ticket ACME-4 --pr 12 --round 1 --out "$work/1a.json")"

holds() { # label needle
  case "$prompt" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 -- the prompt does not contain: $2
$prompt" ;;
  esac
}
lacks() { # label needle
  case "$prompt" in
    *"$2"*) bad "$1 -- the prompt still contains: $2
$prompt" ;;
    *) ok "$1" ;;
  esac
}

holds "the review says it is light" "light review: one reviewer, one round"
holds "the review asks for blocking or note and nothing else" \
  'two severities, `blocking` and `note`, and nothing else'
holds "blocking is reserved for a concrete failing scenario" "concrete failing scenario"
holds "the review turns off the skill's promotion rule" "do not promote a finding"
holds "the review says a blocking fix merges without a second review" \
  "nobody reviews it again"
lacks "the review no longer offers a warning severity" '`warning` —'
lacks "round 1 is not told it is a later round" "review round"

prompt="$("$brief" review --ticket ACME-4 --pr 12 --round 2 --out "$work/2a.json")"
holds "round 2 says the earlier round found nothing blocking" "found nothing blocking"
holds "round 2 says the head moved" "The head has moved since"
lacks "round 2 no longer claims a fix was pushed for blocking findings" "pushed a fix"

exit "$fail"
