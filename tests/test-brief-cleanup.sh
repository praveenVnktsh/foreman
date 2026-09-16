#!/usr/bin/env bash
# The scheduled cleanup agent is the only thing left that files cards, and it
# is the one dispatched role with no ticket, no branch and no pull request. Its
# whole contract lives in its prompt, so this file is where that contract is
# pinned: at most one card, verified against `main` before it is filed, gated
# behind `needs-plan` when the plan is large or touches a risk path, and never
# a commit or a pull request of its own.
#
# The ids are the other half. A cleanup agent files into a Linear state, in a
# project, with a label, and all three are ids that `bin/resolve-ids.py` wrote
# into `ids.env`. A prompt that names them by NAME instead is a card filed
# nowhere, discovered after a whole pass has been spent deciding what to file,
# so an ids.env missing any of them refuses here rather than rendering a prompt
# with a hole in it.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
board_dir="$root/skills/board"
brief="$board_dir/brief.py"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

git_q() {
  git -c user.name="Brief Test" -c user.email="brief-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# The same fixture shape test-brief-uses-the-contract.sh builds: a target repo
# with a real origin and a board.toml nothing outside this file knows. The
# [cleanup] and [risk] tables are this file's own addition -- the node budget
# and the risk paths are what the gate paragraph is made of, and a target that
# declares neither would prove only that the defaults render.
origin="$work/origin.git"
target="$work/target"
git_q init -q --bare "$origin"
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
[docs]
required = ["OPERATING.md", "STYLE.md"]
[risk]
paths = ["db/migrations/", "infra/"]
[cleanup]
max_plan_nodes = 5
[limits]
max_label_chars = 77
TOML
echo "seed" > "$target/seed.txt"
git_q -C "$target" add -A
git_q -C "$target" commit -q -m "Seed"
git_q -C "$target" remote add origin "$origin"
git_q -C "$target" push -q origin main

home="$work/home"
fixture_add_instance "$home" demo "$target"

# ids.env is written by bin/resolve-ids.py from Linear, never by hand -- these
# are stand-ins for what it caches. They are deliberately unlike real Linear
# UUIDs and deliberately hold the label's own name, so an assertion below can
# say both things at once: the label reached the prompt, and it reached it as
# the id and not as the word.
ids_env="$home/.foreman/instances/demo/ids.env"
write_ids() { # every KEY=VALUE line the caller wants, one per argument
  mkdir -p "$(dirname -- "$ids_env")"
  : > "$ids_env"
  local pair
  for pair in "$@"; do printf '%s\n' "$pair" >> "$ids_env"; done
}
PROJECT_ID="id-project-9c2"
STATE_ID="id-state-in-plan-11"
CLEANUP_ID="id-label-cleanup-2a9"
NEEDS_PLAN_ID="id-label-needs-plan-7f3"
write_ids "LINEAR_PROJECT_ID=$PROJECT_ID" "STATE_IN_PLAN=$STATE_ID" \
  "LABEL_CLEANUP=$CLEANUP_ID" "LABEL_NEEDS_PLAN=$NEEDS_PLAN_ID"

ask_brief() { # subcommand and args...
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo "$brief" "$@"
}

holds() { # label needle
  case "$prompt" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 -- the prompt does not contain: $2
$prompt" ;;
  esac
}

# ============================================================================
# Part 1 -- the prompt states the cleanup agent's whole contract.
# ============================================================================

prompt="$(ask_brief cleanup --board demo --since 2026-09-12T04:00:00Z)"

# The one-card cap is the reason this role exists. Step 7 used to write three
# follow-ups per merged card, most of them no-ops, and the cap is what replaced
# it -- a cleanup that files two cards is that failure again with a new name.
holds "the prompt caps the pass at one card" "at most one"

# A finding is a claim about code that may already have changed. evidence.sh
# fetches and then answers; `git show origin/main:<path>` reads a local ref no
# fetch is guaranteed to have refreshed, so a prompt that does not name
# evidence.sh is one whose agent files cards against a stale main.
holds "the prompt verifies candidates with evidence.sh" "evidence.sh"
holds "the prompt reads evidence against main" "evidence.sh main"

# The gate is the operator's sign-off. Only they remove `needs-plan`, so the
# agent adding it can only make the gate stricter -- and it has to reach the
# prompt as the id, because a label applied by name is a label Linear does not
# find.
holds "the gate names the needs-plan label" "$NEEDS_PLAN_ID"
holds "the gate names the node budget the contract declares" "more than 5 nodes"
holds "the gate names the target's risk paths verbatim" '`db/migrations/`, `infra/`'
holds "the gate applies to the new card alone" "that card and no other"

# This role never touches the repository. It is dispatched into a worktree with
# real git and gh credentials like every other role, and the only thing keeping
# it out of them is this sentence.
holds "the prompt forbids pushing a commit" "never push a commit"
holds "the prompt forbids opening a pull request" "never open a pull request"

# Every id is pasted, never a name: the state and project a card is filed into,
# and the label it carries.
for id in "$PROJECT_ID" "$STATE_ID" "$CLEANUP_ID"; do
  holds "the prompt pastes the id $id" "$id"
done
holds "the prompt says the ids are ids and not names" "paste them, never a name"

# The plan is checked against THIS target's budget, not the checker's default
# and not the example in the graphplan skill.
holds "the prompt checks the plan graph with the target's own budget" \
  "--max-label-chars 77"

# The window comes from the stamp the tick wrote, so the agent knows which
# merges it has already seen.
holds "the prompt names the window it searches" "merged since 2026-09-12T04:00:00Z"

# ============================================================================
# Part 2 -- `never` is the first run on a board, and it means everything.
# ============================================================================

prompt="$(ask_brief cleanup --board demo --since never)"
holds "a board with no stamp yet searches every merged pull request" \
  "every pull request this board has merged"

# ============================================================================
# Part 3 -- a stamp nobody can parse, and an ids.env missing a label, both
# refuse rather than rendering a prompt with a hole in it.
# ============================================================================

if err="$(ask_brief cleanup --board demo --since "last tuesday" 2>&1 >/dev/null)"; then
  bad "a --since that is neither \`never\` nor a UTC stamp rendered a prompt anyway"
else
  case "$err" in
    *"--since"*) ok "an unparseable --since refuses, naming the argument" ;;
    *) bad "an unparseable --since refused without naming the argument: $err" ;;
  esac
fi

# The label the cleanup card carries is resolved by bin/resolve-ids.py like
# every other id. Without it the agent would file a card with no label, which
# no later pass can tell apart from a card an operator wrote by hand.
write_ids "LINEAR_PROJECT_ID=$PROJECT_ID" "STATE_IN_PLAN=$STATE_ID" \
  "LABEL_NEEDS_PLAN=$NEEDS_PLAN_ID"
set +e
err="$(ask_brief cleanup --board demo --since never 2>&1 >/dev/null)"
status=$?
set -e
if [[ "$status" != 1 ]]; then
  bad "an ids.env with no LABEL_CLEANUP exited $status, not 1"
elif [[ "$err" == *"ids.env"* && "$err" == *"LABEL_CLEANUP"* ]]; then
  ok "an ids.env with no LABEL_CLEANUP refuses with exit 1, naming ids.env"
else
  bad "the refusal names neither ids.env nor the missing key: $err"
fi

exit "$fail"
