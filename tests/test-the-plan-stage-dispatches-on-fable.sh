#!/usr/bin/env bash
# The planning stage runs on `fable`, and nothing else decides that.
#
# The model follows the STAGE. The plan is drawn once, before any code exists,
# and every build agent afterwards is only as good as the graph it was handed --
# so that is where the strongest model is spent. An earlier attempt at this
# arrangement inverted it (closed, unmerged): fable for every build node, opus
# for the planner, which spends the strongest model on typing out a plan the
# weakest one drew.
#
# `PLAN_MODEL=` empty must reach the CLI as an empty `--model`, which Claude
# Code reads as "inherit". `:-` would silently reinstate fable over an
# operator's explicit off -- the bug AGENT_SKIP_PERMISSIONS and
# HOST_SLOT_STALE_MINUTES both shipped.
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

check_model() { # description expected-repr
  local desc="$1" want="$2" got
  got="$(dispatch_fixture_model)"
  if [[ -z "$got" ]]; then
    bad "$desc: the dispatch never reached \`claude --bg --model\`"
    # The reason is in the dispatch's own output, not in this assertion. Print
    # it here, before the EXIT trap deletes $work_dir along with the log
    # (PRA-349): two callers of this fixture shipped DISPATCH_RUN_LOG and then
    # never printed it, so the next allowlist gap cost the same debugging
    # round again with only "never reached `claude --bg`" in CI.
    dispatch_fixture_show_run_log
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected --model $want, got $got"
  fi
}

dispatch_fixture_run --ticket PRA-1 --role plan --attempt 1
check_model "a plan dispatch runs on fable" "'fable'"

export PLAN_MODEL=sonnet
dispatch_fixture_run --ticket PRA-2 --role plan --attempt 1
check_model "PLAN_MODEL overrides the default" "'sonnet'"

export PLAN_MODEL=
dispatch_fixture_run --ticket PRA-3 --role plan --attempt 1
check_model "an explicitly empty PLAN_MODEL reaches the CLI as inherit" "''"
unset PLAN_MODEL

# The agent name is what `waitfor.py`, `watch-agents.py` and `reconcile.py`
# match a dispatched agent by, and a stage with no name of its own is a stage
# no board can wait for. It starts at the INSTALLATION: the fixture's home
# declares no installation.toml, so bin/installation.py reads it as the lone
# Claude installation and the segment is `claude`.
dispatch_fixture_run --ticket PRA-4 --role plan --attempt 2
if grep -qx 'foreman/claude/demo/PRA-4/plan-2' "$DISPATCH_ARGV_LOG"; then
  ok "a plan agent is named foreman/<installation>/<board>/<ticket>/plan-<attempt>"
else
  bad "a plan agent is named foreman/<installation>/<board>/<ticket>/plan-<attempt>: got $(grep -A1 -x -- --name "$DISPATCH_ARGV_LOG" | tail -1)"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: the plan stage is dispatched on fable\n'
exit "$fail"
