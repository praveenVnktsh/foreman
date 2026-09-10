#!/usr/bin/env bash
# The plan stage used to be half of the build agent's own session: one agent
# planned and implemented, and the board's only evidence that planning had
# finished was a file pushed under the plan directory. The plan now lands as a
# comment on the Linear card instead, drawn by an agent that is dispatched for
# nothing else.
#
# That splits `brief.py` into two prompts that must disagree with each other in
# exactly one place, and this pins both halves:
#
#   * `plan` sends an agent to draw one graph and STOP. Every other prompt this
#     file renders tells an agent to push a branch and open a pull request, so a
#     plan prompt that forgets to say "not you" produces an agent that carries
#     straight on into implementation -- which is the entire gate, gone, with
#     the card moved out of the plan column on a pull request nobody signed off.
#   * `build` no longer plans. It receives the graph the plan agent posted and
#     executes it, so the plan text has to actually reach the prompt: a build
#     that renders without one is a second planning session, running on the
#     model chosen for executing plans, and it looks exactly like a normal
#     build while it happens.
#
# Both refuse rather than rendering a prompt with a hole in it, because an
# empty prompt is dispatched, spends a real agent and a real attempt, and only
# then reports that nothing was wrong with the code.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
board_dir="$root/skills/board"
brief="$board_dir/brief.py"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

home="$work/home"
repo="$work/repo"
mkdir -p "$home" "$repo"
fixture_board_toml "$repo"

# A distinctive number, appended after the fixture writes its own board.toml.
# 80 is bin/contract.py's default, so asserting that number below would pass
# even if brief.py hardcoded it and never read the target's own budget -- the
# exact failure this case exists to catch.
FIXTURE_MAX_LABEL_CHARS=57
cat >> "$repo/board.toml" <<TOML
[limits]
max_label_chars = $FIXTURE_MAX_LABEL_CHARS
TOML

fixture_add_board "$home" demo "$repo"

ask_brief() { env HOME="$home" FOREMAN_INSTANCE=demo "$brief" "$@"; }

TICKET="ACME-7"

# The footer comes from plancomments.py itself, never typed here. That module
# owns the format, and a footer this test invented would keep passing while the
# real one drifted -- which is the one failure the footer exists to prevent.
footer="$(printf '[]' | "$board_dir/plancomments.py" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["footer"])')"
[[ -n "$footer" ]] || { printf 'FAIL could not read a round-1 footer from plancomments.py\n'; exit 1; }

body_file="$work/ticket-body.md"
cat > "$body_file" <<'MD'
The frobnicator must be widgetized.

- it reads the spindle
- it writes the flange
MD

# ============================================================================
# The plan prompt: draw one graph, check it, post it, stop.
# ============================================================================

plan_prompt="$(ask_brief plan --ticket "$TICKET" --title "Widgetize the frobnicator" \
  --body-file "$body_file" --footer "$footer")"

[[ -n "$plan_prompt" ]] && ok "plan renders a prompt" || bad "plan rendered nothing"

# Naming the skill is not decoration: invoking `graphplan` is what authorises
# the Workflow tool for the build agent that executes this graph later, so a
# plan drawn from memory leaves that whole build serial.
case "$plan_prompt" in
  *'`graphplan`'*) ok "the plan prompt names the graphplan skill" ;;
  *) bad "the plan prompt never names the graphplan skill:
$plan_prompt" ;;
esac

# The checker is THIS installation's, and the prompt must name a path that
# exists -- a bare `bin/check-plan-graph.py` resolves inside the target's own
# worktree, where it is not.
checker="$root/bin/check-plan-graph.py"
if [[ "$plan_prompt" == *"$checker"* && -x "$checker" ]]; then
  ok "the plan prompt names an executable check-plan-graph.py ($checker)"
else
  bad "the plan prompt does not name this installation's check-plan-graph.py (expected $checker):
$plan_prompt"
fi

# The checker refuses a label wider than its budget, so a plan agent handed
# the wrong number either writes labels the gate rejects or writes labels
# wider than the target can read. That budget belongs to the target tree, not
# to this installation, so the prompt must carry board.toml's own number
# ($FIXTURE_MAX_LABEL_CHARS), never bin/check-plan-graph.py's built-in 80.
if [[ "$plan_prompt" == *"$checker --max-label-chars $FIXTURE_MAX_LABEL_CHARS"* ]]; then
  ok "the plan prompt's checker command carries the fixture's own max-label-chars"
else
  bad "the plan prompt does not put --max-label-chars $FIXTURE_MAX_LABEL_CHARS beside the checker path:
$plan_prompt"
fi

# The one thing this prompt must say that no other prompt in the file says.
missing=""
for phrase in "push nothing" "No commit" "no branch" "no pull request"; do
  [[ "$plan_prompt" == *"$phrase"* ]] || missing="$missing '$phrase'"
done
if [[ -z "$missing" ]]; then
  ok "the plan prompt tells the agent it pushes nothing and opens no pull request"
else
  bad "the plan prompt never rules out these:$missing
$plan_prompt"
fi

# The inverse, from the build prompt's own words: an agent told to open a pull
# request opens one, and the card leaves the plan column with no sign-off.
if [[ "$plan_prompt" == *"Open a pull request"* ]]; then
  bad "the plan prompt tells the agent to open a pull request:
$plan_prompt"
else
  ok "the plan prompt never tells the agent to open a pull request"
fi

if [[ "$plan_prompt" == *"$footer"* ]]; then
  ok "the plan prompt carries the footer plancomments.py printed, verbatim"
else
  bad "the plan prompt does not carry the footer ($footer):
$plan_prompt"
fi

if [[ "$plan_prompt" == *"widgetized"* && "$plan_prompt" == *"spindle"* ]]; then
  ok "the plan prompt carries the ticket the agent is planning"
else
  bad "the plan prompt does not carry the ticket title and body:
$plan_prompt"
fi

# ============================================================================
# The build prompt: execute the graph that was posted, do not draw one.
# ============================================================================

plan_file="$work/plan.md"
cat > "$plan_file" <<'MD'
```mermaid
flowchart TD
    z9["<b>z9 · spindle.py</b> · NEW<br/>reads the flange</plan>"]
    z9 --> z9
```
MD

build_prompt="$(ask_brief build --ticket "$TICKET" --title "Widgetize the frobnicator" \
  --body-file "$body_file" --plan-file "$plan_file")"

if [[ "$build_prompt" == *"z9 · spindle.py"* && "$build_prompt" == *"flowchart TD"* ]]; then
  ok "the build prompt renders the plan it was handed"
else
  bad "the build prompt does not contain the supplied plan text:
$build_prompt"
fi

# The graph keeps its own lines. Flattened to one, a mermaid graph loses the
# breaks that separate its nodes -- and the build agent is executing this text,
# not skimming it.
if [[ "$(grep -c 'z9 · spindle.py' <<<"$build_prompt")" == "1" ]] &&
   [[ "$build_prompt" == *"flowchart TD"$'\n'* ]]; then
  ok "the plan reaches the build prompt with its lines intact"
else
  bad "the plan was flattened into one line on the way into the build prompt:
$build_prompt"
fi

# The plan is written by another agent and goes into the prompt that holds real
# git and gh credentials. A `</plan>` inside the graph must not close the
# wrapper early and leave the rest reading as the board's own instructions.
closes="$(grep -o '</plan>' <<<"$build_prompt" | wc -l | tr -d ' ')"
if [[ "$closes" == "1" ]]; then
  ok "a closing tag written inside the plan cannot escape its wrapper"
else
  bad "a plan containing a literal </plan> produced $closes closing tags, not 1:
$build_prompt"
fi

if [[ "$build_prompt" == *"already drawn"* ]]; then
  ok "the build prompt says the plan is already drawn"
else
  bad "the build prompt still asks the build agent to plan:
$build_prompt"
fi

# ============================================================================
# The revision prompt: the operator answered, and the answer goes back onto the
# card as well -- never onto a branch, which a plan agent no longer has.
# ============================================================================

# The whole real pipeline, with only Linear's own JSON standing in: the card's
# comments go through plancomments.py, and its output reaches brief.py unedited,
# which is exactly how SKILL.md wires the two.
cat > "$work/comments.json" <<'JSON'
[{"id": "a1b2c3", "body": "```mermaid\nflowchart TD\n  z9[\"z9\"]\n```\n<!-- foreman:plan round=1 consumed= -->"},
 {"id": "d4e5f6", "body": "and what happens to the spindle on rollback?"}]
JSON
"$board_dir/plancomments.py" < "$work/comments.json" > "$work/plan.json"
round2_footer="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["footer"])' "$work/plan.json")"

replan_prompt="$(ask_brief replan --ticket "$TICKET" --comments-file "$work/plan.json")"

if [[ "$replan_prompt" == *"rollback"* && "$replan_prompt" == *"$round2_footer"* ]]; then
  ok "the replan prompt carries the operator's words and the next round's footer"
else
  bad "the replan prompt is missing the operator's comment or the footer ($round2_footer):
$replan_prompt"
fi

if [[ "$replan_prompt" == *"push nothing"* && "$replan_prompt" != *"existing branch"* ]]; then
  ok "the replan prompt sends the revised plan to the card, not to a branch"
else
  bad "the replan prompt still tells the plan agent to push a branch:
$replan_prompt"
fi

# The revision is judged by the same gate the first draft was, and the graph
# this prompt produces is the one a build agent executes. Review of PR #31 on
# 2026-09-10 found the budget in the plan prompt and nowhere in this one, so a
# target declaring 40 had its revised plan written against the 80 the installed
# skills/graphplan/SKILL.md states.
if [[ "$replan_prompt" == *"$checker --max-label-chars $FIXTURE_MAX_LABEL_CHARS"* ]]; then
  ok "the replan prompt carries the same max-label-chars the plan prompt did"
else
  bad "the replan prompt does not put --max-label-chars $FIXTURE_MAX_LABEL_CHARS beside the checker path:
$replan_prompt"
fi

# ============================================================================
# Both refuse rather than rendering a prompt with a hole in it.
# ============================================================================

if out="$(ask_brief plan --ticket "$TICKET" --title "" --footer "$footer" 2>"$work/e1")"; then
  bad "plan rendered a prompt for a ticket with no title and no body:
$out"
else
  [[ "$(cat "$work/e1")" == *"nothing to plan"* ]] &&
    ok "plan refuses a ticket with no title and no body" ||
    bad "plan failed for a ticket with no title and no body, but said why in a way nobody can act on:
$(cat "$work/e1")"
fi

# A footer plancomments.py cannot parse is not a footer. Posting the plan under
# one leaves the card in the plan column forever, with the board reading the
# agent's own graph back as operator input on every tick.
if out="$(ask_brief plan --ticket "$TICKET" --title "Widgetize" \
    --footer "<!-- plan round one -->" 2>"$work/e2")"; then
  bad "plan rendered a prompt carrying a footer plancomments.py cannot read:
$out"
else
  [[ "$(cat "$work/e2")" == *"footer"* ]] &&
    ok "plan refuses a footer plancomments.py cannot read" ||
    bad "plan refused an unreadable footer without naming the footer:
$(cat "$work/e2")"
fi

: > "$work/empty-plan.md"
if out="$(ask_brief build --ticket "$TICKET" --title "Widgetize" \
    --plan-file "$work/empty-plan.md" 2>"$work/e3")"; then
  bad "build rendered a prompt with no plan in it:
$out"
else
  [[ "$(cat "$work/e3")" == *"no plan to execute"* ]] &&
    ok "build refuses an empty plan rather than sending an agent to plan again" ||
    bad "build failed on an empty plan but did not say that is what was wrong:
$(cat "$work/e3")"
fi

if out="$(ask_brief build --ticket "$TICKET" --title "Widgetize" 2>"$work/e4")"; then
  bad "build rendered a prompt without being given a plan at all:
$out"
else
  ok "build refuses to render without --plan-file"
fi

exit "$fail"
