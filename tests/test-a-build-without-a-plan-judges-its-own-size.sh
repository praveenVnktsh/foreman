#!/usr/bin/env bash
# A card without `needs-plan` skips the plan stage and goes straight to a
# build. That build gets no graph, so its prompt has to carry the judgement the
# plan stage used to make: SMALL is built directly, anything else is planned by
# the build agent itself, posted to the card under the board's footer, and then
# executed without stopping. This pins the three ways that prompt can fail:
#
#   * rendered without a footer, the agent posts a plan the board reads back as
#     an operator comment on every tick after;
#   * rendered like the planned build, the agent reads "the plan is already
#     drawn", finds no plan, and builds a large change unplanned;
#   * rendered like the plan stage, the agent posts its graph and stops, and a
#     card nobody parked sits in progress with no pull request.
#
# It also pins the branch sentence: the board finds the pull request by branch
# name (reconcile.py lists pull requests by head branch), not by the ticket key
# in its body.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
board_dir="$root/skills/board"
brief="$board_dir/brief.py"

# shellcheck source=lib/without-board.sh
source "$here/lib/without-board.sh"
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
# A distinctive budget, so the prompt can only carry it by reading board.toml.
cat >> "$repo/board.toml" <<'TOML'
[limits]
max_label_chars = 61
TOML
fixture_add_board "$home" demo "$repo"

ask_brief() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo "$brief" "$@"
}

TICKET="ACME-9"
body_file="$work/body.md"
printf 'Rename the flange reader.\n' > "$body_file"

# The footer comes from plancomments.py, never typed here: that module owns
# the format.
footer="$(printf '[]' | "$board_dir/plancomments.py" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["footer"])')"

prompt="$(ask_brief build --ticket "$TICKET" --title "Rename the flange reader" \
  --body-file "$body_file" --footer "$footer")"

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

holds "the triage build names the SMALL judgement" "**SMALL**"
holds "the triage build names the PLANNED judgement" "**PLANNED**"
holds "a doubtful card is planned, not built directly" "When in doubt, it is PLANNED"
holds "a PLANNED card invokes graphplan as a skill" '`graphplan` skill as a skill'
holds "the triage build carries the footer verbatim" "$footer"
holds "the triage build checks its graph against the target's own budget" \
  "$root/bin/check-plan-graph.py --max-label-chars 61"
holds "the triage build carries on after posting" "Do not stop after posting"
holds "the triage build asks for the judgement in the pull request body" \
  '`Size: SMALL` or `Size: PLANNED`'
holds "the triage build still opens a pull request" "Open a pull request"
lacks "the triage build does not claim a plan was drawn" "already drawn"
lacks "the triage build has no plan section" "## The plan"

holds "the build prompt says the board finds the pull request by branch name" \
  "finds your pull request by that branch name"
lacks "the build prompt no longer says the ticket key is how the board finds it" \
  "so the board can find it"

# A planned card's build is unchanged: it executes the graph it was handed.
plan_file="$work/plan.md"
printf 'graph TD\n  a1["a1 . rename it"]\n' > "$plan_file"
prompt="$(ask_brief build --ticket "$TICKET" --title "Rename the flange reader" \
  --body-file "$body_file" --plan-file "$plan_file")"
holds "a planned build still says the plan is already drawn" "already drawn"
lacks "a planned build does not ask the agent to judge its size" "**SMALL**"

# Neither a plan nor a footer is a build with no way to post a plan.
if out="$(ask_brief build --ticket "$TICKET" --title "Rename" 2>"$work/e1")"; then
  bad "build rendered with neither --plan-file nor --footer:
$out"
else
  case "$(cat "$work/e1")" in
    *"--plan-file"*"--footer"*) ok "build refuses neither --plan-file nor --footer, naming both" ;;
    *) bad "build refused neither flag without naming them: $(cat "$work/e1")" ;;
  esac
fi

# A footer plancomments.py cannot parse marks nothing as the board's.
if out="$(ask_brief build --ticket "$TICKET" --title "Rename" \
    --footer "<!-- plan round one -->" 2>"$work/e2")"; then
  bad "build rendered with a footer plancomments.py cannot read:
$out"
else
  case "$(cat "$work/e2")" in
    *footer*) ok "build refuses a footer plancomments.py cannot read" ;;
    *) bad "build refused an unreadable footer without naming it: $(cat "$work/e2")" ;;
  esac
fi

exit "$fail"
