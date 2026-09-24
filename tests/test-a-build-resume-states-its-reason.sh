#!/usr/bin/env bash
# Claim: a build resume states why it was resumed, and reconcile.py's
# build_attempts arithmetic can only tell a charged ci-fix resume from a fix
# or retry resume by reading it off the history row `dispatch.sh` writes.
#
# `--reason` is required on `--resume --role build`, refused everywhere else,
# and only `ci-fix`, `fix` or `retry` are valid. The row it produces carries
# `role` and `reason`; a resume of any other role keeps the row it always
# wrote, with no `role` key at all, so reconcile.py's plan_rounds -- which
# counts rows with role=plan -- cannot double-count a build resume as a plan
# one.
#
# Drives the real dispatch.sh through tests/lib/dispatch-fixture.sh, the same
# fixture test-dispatch-spawns-on-the-fallback-tier.sh uses: `claude` is the
# only external boundary stubbed, so a spawn and a resume both run dispatch.sh's
# own worktree, model and history-writing code for real.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
is_eq() { # description want got
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1: wanted [$2], got [$3]"
}

history_for() { printf '%s/.foreman/instances/demo/cards/%s/history.jsonl\n' "$DISPATCH_HOME" "$1"; }

resume_row_count() { # ticket
  local file
  file="$(history_for "$1")"
  [[ -f "$file" ]] && grep -c '"action":"resume"' "$file" || printf '0\n'
}

last_resume_row() { # ticket
  local file
  file="$(history_for "$1")"
  [[ -f "$file" ]] && grep '"action":"resume"' "$file" | tail -1
}

spawned() { # ticket -- whether the fixture's `claude --bg` was reached this run
  [[ -s "$DISPATCH_ARGV_LOG" ]]
}

# --- a build resume without --reason is refused and logs nothing -----------
dispatch_fixture_run --ticket RSN-1 --role build --attempt 1
if spawned; then
  ok "the fresh build dispatch spawned"
else
  bad "the fresh build dispatch spawned"
  dispatch_fixture_show_run_log
fi
before="$(resume_row_count RSN-1)"
dispatch_fixture_resume --ticket RSN-1 --role build --attempt 1
if grep -q -- '--reason must be ci-fix, fix or retry' "$DISPATCH_RUN_LOG"; then
  ok "a build resume with no --reason is refused"
else
  bad "a build resume with no --reason is refused"
  dispatch_fixture_show_run_log
fi
after="$(resume_row_count RSN-1)"
is_eq "no resume row was logged for the refused build resume" "$before" "$after"

# --- a build resume with an unknown --reason is refused ---------------------
dispatch_fixture_resume --ticket RSN-1 --role build --attempt 1 --reason bogus
if grep -q -- '--reason must be ci-fix, fix or retry' "$DISPATCH_RUN_LOG"; then
  ok "a build resume with an unknown --reason is refused"
else
  bad "a build resume with an unknown --reason is refused"
  dispatch_fixture_show_run_log
fi
is_eq "no resume row was logged for the unknown reason" "$before" "$(resume_row_count RSN-1)"

# --- --reason on a fresh (non-resume) dispatch is refused -------------------
dispatch_fixture_run --ticket RSN-2 --role build --attempt 1 --reason ci-fix
if grep -q -- '--reason must be ci-fix, fix or retry' "$DISPATCH_RUN_LOG"; then
  ok "--reason on a fresh dispatch is refused"
else
  bad "--reason on a fresh dispatch is refused"
  dispatch_fixture_show_run_log
fi
if spawned; then
  bad "the fresh dispatch never reached claude --bg once --reason was refused"
else
  ok "the fresh dispatch never reached claude --bg once --reason was refused"
fi

# --- --reason with a non-build role is refused, resumed or not -------------
dispatch_fixture_run --ticket RSN-3 --role plan --attempt 1 --reason ci-fix
if grep -q -- '--reason must be ci-fix, fix or retry' "$DISPATCH_RUN_LOG"; then
  ok "--reason on a non-build role is refused"
else
  bad "--reason on a non-build role is refused"
  dispatch_fixture_show_run_log
fi

# --- a build resume with --reason ci-fix appends the row with role and reason
dispatch_fixture_run --ticket RSN-4 --role build --attempt 1
dispatch_fixture_resume --ticket RSN-4 --role build --attempt 1 --reason ci-fix
row="$(last_resume_row RSN-4)"
if [[ "$row" == *'"role":"build"'* && "$row" == *'"reason":"ci-fix"'* ]]; then
  ok "a build resume with --reason ci-fix logs role build and reason ci-fix"
else
  bad "a build resume with --reason ci-fix logs role build and reason ci-fix: got [$row]"
fi

# --- a plan resume's row carries no role key --------------------------------
dispatch_fixture_run --ticket RSN-5 --role plan --attempt 1
dispatch_fixture_resume --ticket RSN-5 --role plan --attempt 1
row="$(last_resume_row RSN-5)"
if [[ -n "$row" && "$row" != *'"role"'* ]]; then
  ok "a plan resume's row has no role key"
else
  bad "a plan resume's row has no role key: got [$row]"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: a build resume states its reason\n'
exit "$fail"
