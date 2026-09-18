#!/usr/bin/env bash
# A stage may name ordered model candidates. When the first is unavailable,
# dispatch marks it and tries the next, and the card is never charged an
# attempt for a model the provider refused. See
# docs/specs/2026-09-18-project-level-installs-design.md.
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

health="$DISPATCH_HOME/.foreman/model-health.json"
recorded() { # <model>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)" \
    "$health" "$1"
}

# The build stage names two candidates, and the first looks rate-limited.
export BUILD_MODELS=$'opus\nsonnet'
export DISPATCH_FAIL_MODELS="opus"

dispatch_fixture_run --ticket PRA-1 --role build --attempt 1
got="$(dispatch_fixture_model)"
if [[ "$got" == "'sonnet'" ]]; then
  ok "an unavailable first candidate falls to the next"
else
  bad "expected --model 'sonnet', got $got"
  dispatch_fixture_show_run_log
fi

if recorded opus; then
  ok "the failed candidate is recorded unavailable"
else
  bad "opus is not recorded in $health"
fi
if recorded sonnet; then
  bad "sonnet was recorded unavailable though it spawned"
else
  ok "the succeeding candidate is not recorded"
fi

# A later dispatch skips the marked candidate without needing it to fail again.
export DISPATCH_FAIL_MODELS=""
dispatch_fixture_run --ticket PRA-2 --role build --attempt 1
got="$(dispatch_fixture_model)"
if [[ "$got" == "'sonnet'" ]]; then
  ok "a candidate already marked unavailable is skipped"
else
  bad "expected --model 'sonnet' again, got $got"
  dispatch_fixture_show_run_log
fi

exit "$fail"
