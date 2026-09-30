#!/usr/bin/env bash
# Claim: .github/workflows/release.yml cuts a release only after CI passed on
# a push to main -- never on a bare push, which released in parallel with the
# tests, and never on a pull request, which would run a contributor's branch --
# releases the commit CI ran on, one release at a time, with the write
# permission the release needs and a checkout pinned to a commit.
#
# It reads the workflow file rather than running it: GitHub runs it, not this
# suite. What it can prove here is the trigger, the guard, the permission and
# the command, which are what make it deploy or fail to.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo_root/.github/workflows/release.yml"
ci="$repo_root/.github/workflows/ci.yml"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

[[ -f "$wf" ]] && ok "the release workflow exists" || { bad "no $wf"; exit 1; }

# The workflow it waits for is named by CI's own `name:`, so a rename of one
# without the other makes the release wait for a run that never comes.
ci_name="$(sed -n 's/^name:[[:space:]]*//p' "$ci" | head -1)"
grep -qE '^[[:space:]]*workflow_run:' "$wf" \
  && grep -qE "workflows:[[:space:]]*\[$ci_name\]" "$wf" \
  && grep -qE 'types:[[:space:]]*\[completed\]' "$wf" \
  && grep -qE 'branches:[[:space:]]*\[main\]' "$wf" \
  && ok "it runs when the '$ci_name' workflow completes on main" \
  || bad "it does not trigger on workflow_run of '$ci_name' on main"

grep -qE '^[[:space:]]*push:' "$wf" \
  && bad "it runs on push, which releases before CI has passed" \
  || ok "it does not run on a bare push"

grep -qE '^[[:space:]]*pull_request(_target)?:' "$wf" \
  && bad "it runs on a pull request, which would run a contributor's branch" \
  || ok "it does not run on pull_request"

grep -qF "github.event.workflow_run.conclusion == 'success'" "$wf" \
  && grep -qF "github.event.workflow_run.event == 'push'" "$wf" \
  && grep -qF "github.event.workflow_run.head_repository.full_name == github.repository" "$wf" \
  && ok "it releases only a successful CI run of a push to this repository" \
  || bad "the job is not guarded on success, a push event and this repository"

grep -qE 'RELEASE_SHA:[[:space:]]*\$\{\{[[:space:]]*github\.event\.workflow_run\.head_sha[[:space:]]*\}\}' "$wf" \
  && ok "it releases the commit CI ran on, not main's head" \
  || bad "it does not pass the CI run's head_sha as RELEASE_SHA"

grep -qE '^concurrency:' "$wf" \
  && grep -qE 'cancel-in-progress:[[:space:]]*false' "$wf" \
  && ok "releases run one at a time and none is cancelled" \
  || bad "no concurrency group, or one that cancels a release in progress"

grep -qE '^[[:space:]]*contents:[[:space:]]*write' "$wf" \
  && ok "it grants contents: write, which creating a release needs" \
  || bad "it does not grant contents: write"

unpinned="$(grep -E 'uses:' "$wf" | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)"
[[ -z "$unpinned" ]] \
  && ok "every action is pinned to a commit" \
  || bad "an action is not pinned to a commit: $unpinned"

grep -qE 'run:[[:space:]]*bin/release\.sh' "$wf" \
  && ok "it cuts the release through bin/release.sh" \
  || bad "it does not run bin/release.sh"

exit "$fail"
