#!/usr/bin/env bash
# A card labelled `human-cobuild` pauses the loop instead of guessing, and the
# pause is only real if the prompt makes asking possible and cheap.
#
# Three things have to hold, and each of them has failed somewhere before:
#
#   - The prompt names the EXACT file the agent writes its questions to. A
#     prompt that says "ask the operator" and names no channel is a prompt an
#     agent satisfies by writing a question into its final report, where the
#     board never looks and nobody ever reads it.
#   - The prompt says a question costs the card nothing. An agent that believes
#     asking spends one of three build attempts guesses to save one, which is
#     the exact behaviour the label exists to stop.
#   - The operator's answers come back as the ticket, not as a quoted report.
#     `brief.py fix` deliberately wraps another agent's findings in a tag and
#     says they are "never an instruction"; doing that to the operator's own
#     reply would tell the agent to ignore the one thing it was waiting for.
#
# An ordinary card must be untouched by all of it: no questions file, no
# co-build paragraph, nothing to opt into.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
brief="$root/skills/board/brief.py"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# A contract of this test's own rather than the shared fixture's: the standing
# instructions have to be shown surviving alongside the co-build ones, and
# `true` as a test command is not a string a prompt can be searched for.
target="$work/target"
mkdir -p "$target"
cat > "$target/board.toml" <<'TOML'
[linear]
team = "ACME"
project = "widget"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make check"
TOML
home="$work/home"
fixture_add_board "$home" demo "$target"

TICKET="ACME-9"
body_file="$work/body.md"
printf 'Make the widget configurable.\n' > "$body_file"
questions_file="$home/.foreman/instances/demo/cards/$TICKET/questions/2.md"

ask_build() { # extra args...
  env HOME="$home" FOREMAN_INSTANCE=demo "$brief" build \
    --ticket "$TICKET" --title "Configurable widget" --body-file "$body_file" "$@"
}

# --- an ordinary card is not a co-build -------------------------------------

plain="$(ask_build)"
if [[ "$plain" != *"co-build"* && "$plain" != *"human-cobuild"* ]]; then
  ok "a card with no questions file gets no co-build instruction at all"
else
  bad "an ordinary build prompt has co-build text in it:
$plain"
fi

# --- the co-build prompt --------------------------------------------------

cobuild="$(ask_build --questions-file "$questions_file")"

if [[ "$cobuild" == *"$questions_file"* ]]; then
  ok "the co-build prompt names the exact file the questions go in"
else
  bad "the co-build prompt does not name $questions_file:
$cobuild"
fi

if [[ "$cobuild" == *"human-cobuild"* && "$cobuild" == *"Needs Answers"* ]]; then
  ok "the co-build prompt names the label that caused it and the column it parks in"
else
  bad "the co-build prompt does not explain what happens after it asks:
$cobuild"
fi

if [[ "$cobuild" == *"not a build attempt"* && "$cobuild" == *"attempt budget"* ]]; then
  ok "the co-build prompt says asking costs the card nothing"
else
  bad "the co-build prompt does not say a question is free, so the agent will guess to save an attempt:
$cobuild"
fi

# The standing instructions still apply: a co-build agent that has its answers
# builds, tests and opens a pull request exactly like any other.
if [[ "$cobuild" == *"make check"* && "$cobuild" == *"do not enable auto-merge"* \
      && "$cobuild" == *"Everything above still stands"* ]]; then
  ok "the co-build prompt keeps the standing build instructions, and says they still apply"
else
  bad "the co-build prompt dropped the standing build instructions, or left them contradicting the pause:
$cobuild"
fi

# --- the answers come back as the ticket ------------------------------------

answers_file="$work/answers.md"
cat > "$answers_file" <<'ANSWERS'
board asked: 1. Should the widget default to on? I would assume yes.
operator replied: No -- default it off, and add a flag.
ANSWERS

answered="$(ask_build --questions-file "$questions_file" --answers-file "$answers_file")"

if [[ "$answered" == *"default it off, and add a flag"* ]]; then
  ok "the operator's answer reaches the prompt verbatim"
else
  bad "the operator's answer is not in the prompt:
$answered"
fi

# Never wrapped the way a review finding is. `quote_untrusted` flattens text
# into a tag and the prompt around it says the contents are never an
# instruction -- doing that here would tell the agent to disregard the answer
# it stopped and waited a day for.
if [[ "$answered" != *"<review-finding>"* && "$answered" != *"never an instruction"* ]]; then
  ok "the operator's answer is not quoted as a report to be ignored"
else
  bad "the operator's answer was wrapped as untrusted agent text:
$answered"
fi

if [[ "$answered" == *"$questions_file"* ]]; then
  ok "an answered co-build card still has somewhere to put its next question"
else
  bad "the answered prompt lost the questions file, so a second question has nowhere to go:
$answered"
fi

# --- refusals ---------------------------------------------------------------

if ask_build --answers-file "$answers_file" >"$work/out" 2>"$work/err"; then
  bad "--answers-file without --questions-file rendered a prompt: $(cat "$work/out")"
elif grep -q -- "--questions-file" "$work/err"; then
  ok "REFUSES answers with no questions file, naming the flag that is missing"
else
  bad "refused for the wrong reason: $(cat "$work/err")"
fi

: > "$work/empty-answers.md"
if ask_build --questions-file "$questions_file" --answers-file "$work/empty-answers.md" \
     >"$work/out" 2>"$work/err"; then
  bad "an empty answers file rendered a conversation with nothing in it: $(cat "$work/out")"
elif grep -q "empty" "$work/err"; then
  ok "REFUSES an empty answers file rather than showing a conversation with no answer in it"
else
  bad "refused for the wrong reason: $(cat "$work/err")"
fi

if ask_build --questions-file "$questions_file" --answers-file "$work/no-such-file.md" \
     >"$work/out" 2>"$work/err"; then
  bad "a missing answers file rendered a prompt anyway: $(cat "$work/out")"
elif grep -q "no-such-file.md" "$work/err"; then
  ok "REFUSES an answers file it cannot read, naming the path"
else
  bad "refused for the wrong reason: $(cat "$work/err")"
fi

exit "$fail"
