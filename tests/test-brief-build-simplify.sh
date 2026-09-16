#!/usr/bin/env bash
# Review used to buy quality with rounds: two reviewers, twice, on every card.
# Most of what they returned was a `warning` or a `note` that stopped nothing
# and was never read again. The build now cleans up after itself instead --
# `/simplify` on its own diff, before the pull request is opened -- and this
# file pins the two halves of that step that can silently go missing.
#
# WHERE it sits is the first half. Run after the pull request is open, the pass
# rewrites a diff a reviewer has already been dispatched for; run before the
# tests, it ships a refactor nothing re-ran. So the prompt must place it after
# the test command and before the pull request, and the order is asserted by
# position, not by both strings merely being present somewhere.
#
# WHO CAN RUN IT is the second. `/simplify` is a Claude Code built-in, so a
# codex or opencode installation has nothing to invoke. Dropping the paragraph
# there would leave a build agent unable to report that it skipped the step,
# and the board would read a diff that never had a cleanup pass as one that
# did. Telling it to do the pass by hand is worse: a freehand refactor of one's
# own diff is a second uninstructed change in the same pull request.
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

git_q() {
  git -c user.name="Simplify Test" -c user.email="simplify-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# One target repository, served by all three installations below. Its contract
# is what the prompt has to quote -- `make check` is the test command the
# simplify step re-runs, and nothing outside this file knows that name.
target="$work/target"
git_q init -q -b main "$target"
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
echo "seed" > "$target/seed.txt"
git_q -C "$target" add -A
git_q -C "$target" commit -q -m "Seed"

TICKET="ACME-7"
body_file="$work/ticket-body.md"
printf 'Do the thing.\n' > "$body_file"
plan_file="$work/plan.md"
printf 'graph TD\n  a1["a1 . do it"]\n' > "$plan_file"

ask_build() { # <home> <foreman_home>
  env HOME="$1" FOREMAN_HOME="$2" FOREMAN_INSTANCE=demo "$brief" build \
    --ticket "$TICKET" --title "Widgetize the frobnicator" \
    --body-file "$body_file" --plan-file "$plan_file"
}

# The index of the first occurrence of a string in $prompt, or -1. Position is
# the claim here, so both halves of an ordering check have to come from the
# same prompt and the same measurement.
index_of() { # needle
  local pre="${prompt%%"$1"*}"
  if [[ "$pre" == "$prompt" ]]; then printf '%s\n' -1; else printf '%s\n' "${#pre}"; fi
}

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

# ============================================================================
# Part 1 -- Claude Code: the step is there, between the tests and the pull
# request.
# ============================================================================

home="$work/home"
fixture_add_instance "$home" demo "$target"
prompt="$(ask_build "$home" "$home/.foreman")"

holds "the claude build prompt invokes /simplify" "/simplify"
holds "the claude build prompt scopes the pass to this branch's diff" \
  "this branch's diff"
holds "the claude build prompt re-runs the tests after the pass" \
  "run \`make check\` again"

# A refactor outside the diff is the scheduled cleanup's work. Without this,
# the cheapest reading of "simplify" is "simplify whatever you were looking
# at", and the pull request grows a change nobody asked for.
holds "the claude build prompt sends wider refactors to the scheduled cleanup" \
  "belongs to the scheduled cleanup"

i_test="$(index_of 'Run `make check`')"
i_simplify="$(index_of '/simplify')"
i_pr="$(index_of 'Open a pull request')"
if [[ "$i_test" -lt 0 || "$i_simplify" -lt 0 || "$i_pr" -lt 0 ]]; then
  bad "the build prompt is missing the test command, /simplify or the pull request step
$prompt"
elif [[ "$i_test" -lt "$i_simplify" && "$i_simplify" -lt "$i_pr" ]]; then
  ok "the /simplify step sits after the test command and before the pull request"
else
  bad "the /simplify step is out of order (test $i_test, simplify $i_simplify, pull request $i_pr):
$prompt"
fi

# ============================================================================
# Part 2 -- codex and opencode: the step is named and skipped, never imitated.
# ============================================================================

alt="$work/alt"
mkdir -p "$alt"
# A root holding several installations and no default refuses on every read,
# so one of the two claims it. Which one is immaterial here: the build prompt
# is rendered for the FOREMAN_HOME it is handed.
fixture_add_installation "$alt" codex codex --default
fixture_add_installation "$alt" opencode opencode

for harness in codex opencode; do
  alt_home="$alt/.foreman/$harness"
  fixture_add_board_in "$alt_home" demo "$target"
  prompt="$(ask_build "$alt" "$alt_home")"

  holds "the $harness build prompt still names the step it is skipping" "/simplify"
  holds "the $harness build prompt says to skip it" "Skip the \`/simplify\` step"
  holds "the $harness build prompt names this installation's harness" \
    "harness is \`$harness\`"
  holds "the $harness build prompt asks for the skip in the report" \
    "report that you skipped it"

  # The two ways the skip can go wrong: an agent that runs the step anyway, or
  # one that refactors freehand in its place.
  lacks "the $harness build prompt does not tell the agent to invoke the skill" \
    "invoke the built-in"
  holds "the $harness build prompt forbids imitating the skill by hand" \
    "Do not imitate the skill by hand"
done

exit "$fail"
