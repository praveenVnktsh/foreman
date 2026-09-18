#!/usr/bin/env bash
# Claim: .github/workflows/release.yml cuts a release on a push to main and
# nothing else -- not on a pull request, which would run a contributor's branch
# -- and it has the write permission the release needs.
#
# It reads the workflow file rather than running it: GitHub runs it, not this
# suite. What it can prove here is the trigger, the permission and the command,
# which are the three things that make it deploy or fail to.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo_root/.github/workflows/release.yml"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

[[ -f "$wf" ]] && ok "the release workflow exists" || { bad "no $wf"; exit 1; }

grep -qE '^[[:space:]]*push:' "$wf" \
  && grep -qE 'branches:[[:space:]]*\[main\]' "$wf" \
  && ok "it runs on a push to main" \
  || bad "it does not trigger on a push to main"

grep -qE '^[[:space:]]*pull_request:' "$wf" \
  && bad "it runs on pull_request, which would run a contributor's branch" \
  || ok "it does not run on pull_request"

grep -qE '^[[:space:]]*contents:[[:space:]]*write' "$wf" \
  && ok "it grants contents: write, which creating a release needs" \
  || bad "it does not grant contents: write"

grep -qE 'run:[[:space:]]*bin/release\.sh' "$wf" \
  && ok "it cuts the release through bin/release.sh" \
  || bad "it does not run bin/release.sh"

exit "$fail"
