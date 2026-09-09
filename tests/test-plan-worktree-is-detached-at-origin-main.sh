#!/usr/bin/env bash
# The plan stage no longer commits or pushes anything: it posts its mermaid
# graph to the Linear card as a comment and stops. A branch cut for a plan
# agent therefore sits on the card for nothing -- worse, a build dispatched
# afterwards would inherit or reset that branch, which is exactly the coupling
# this change removes. So a `--role plan` dispatch must cut a THROWAWAY
# DETACHED worktree at origin/main, the same shape `--role review` already
# takes at its own --ref, and it must never create a branch named for the
# card. A `--role build` dispatched afterwards must still get its own branch,
# cut fresh from origin/main, untouched by whatever the plan worktree did.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work_dir/target"
branch_name="foreman/demo/PRA-9"

dispatch_fixture_run --ticket PRA-9 --role plan --attempt 1

# The plan worktree's basename composes ticket, role and attempt the same way
# review's does (see dispatch.sh's role table), so it lands at exactly this
# path -- never at the card's own worktree_path("$TICKET"), which a later
# build dispatch also uses and must not find pre-occupied by a plan.
plan_worktree="$target/.claude/worktrees/foreman-demo-PRA-9-plan-1"
build_worktree="$target/.claude/worktrees/foreman-demo-PRA-9"

if [[ -d "$plan_worktree" ]]; then
  ok "a plan dispatch cuts a worktree named for ticket, role and attempt"
else
  bad "a plan dispatch cuts a worktree named for ticket, role and attempt: $plan_worktree does not exist"
fi

# HEAD in a detached worktree is a commit sha, not a branch, and `git branch
# --show-current` prints nothing for it. A worktree cut with `-B <branch>`
# would print the branch name instead.
if [[ -d "$plan_worktree" ]]; then
  current_branch="$(_dispatch_git -C "$plan_worktree" branch --show-current)"
  if [[ -z "$current_branch" ]]; then
    ok "the plan worktree is detached, not on a branch"
  else
    bad "the plan worktree is detached, not on a branch: checked out $current_branch"
  fi

  plan_sha="$(_dispatch_git -C "$plan_worktree" rev-parse HEAD)"
  if [[ "$plan_sha" == "$DISPATCH_SEED_SHA" ]]; then
    ok "the plan worktree sits at origin/main"
  else
    bad "the plan worktree sits at origin/main: HEAD is $plan_sha, origin/main is $DISPATCH_SEED_SHA"
  fi
fi

# The card's own branch must not exist at all after a plan dispatch. Its
# presence would mean a later build inherits or resets a branch the plan
# agent had no business creating.
if _dispatch_git -C "$target" show-ref --verify --quiet "refs/heads/$branch_name"; then
  bad "a plan dispatch creates no branch named for the card: $branch_name exists"
else
  ok "a plan dispatch creates no branch named for the card"
fi

# Now dispatch a build for the same ticket. It must get its OWN worktree, cut
# fresh from origin/main onto the card's branch -- unaffected by the plan
# worktree that came before it.
dispatch_fixture_run --ticket PRA-9 --role build --attempt 1

if [[ -d "$build_worktree" ]]; then
  build_branch="$(_dispatch_git -C "$build_worktree" branch --show-current)"
  if [[ "$build_branch" == "$branch_name" ]]; then
    ok "a build dispatched afterwards still gets its own branch cut from origin/main"
  else
    bad "a build dispatched afterwards still gets its own branch cut from origin/main: checked out '$build_branch', wanted $branch_name"
  fi
else
  bad "a build dispatched afterwards still gets its own branch cut from origin/main: $build_worktree does not exist"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: the plan stage cuts a detached worktree at origin/main\n'
exit "$fail"
