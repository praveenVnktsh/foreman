#!/usr/bin/env bash
# reconcile.py used to silently substitute the literal "CI" for an empty
# CI_WORKFLOW, justified by a design doc describing a DIFFERENT codebase's
# reasons for not mirroring config.sh into the running board -- a doc that
# does not exist in this repository. `checks.ci_workflow` is REQUIRED and
# refused blank by bin/contract.py, so the only way CI_WORKFLOW reaches
# reconcile.py empty is an environment override (config.sh reads a
# contract-emitted key with `-`, not `:-`, so `CI_WORKFLOW=` overrides even a
# board.toml that named a real workflow). Substituting "CI" there means
# reconcile checks a workflow board.toml never named, silently, instead of
# refusing the way every other required value in this codebase does.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
git -C "$fixture_repo" init -q -b main
cat >"$fixture_repo/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "fixture"
[checks]
required = ["Tests"]
ci_workflow = "Build and Test"
[test]
command = "true"
TOML

py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

# FOREMAN_HOME is named explicitly in both runs below. config.sh no longer
# derives it from $HOME: it asks bin/installation.py, which reads the home as
# the parent of this clone. An explicit home is what that derivation yields to,
# and it is how this file stays pointed at its temporary directory.
echo "==> the ordinary case: CI_WORKFLOW comes from board.toml, no substitution"
if out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo python3 -c "
import sys
sys.path.insert(0, '$board_dir')
import reconcile
assert reconcile.CI_WORKFLOW == 'Build and Test', reconcile.CI_WORKFLOW
print('ok')
" 2>&1)"; then
  [[ "$out" == "ok" ]] && ok "CI_WORKFLOW reflects board.toml's own value" \
    || bad "unexpected output: $out"
else
  bad "importing reconcile failed for the ordinary case: $out"
fi

echo "==> an explicitly empty CI_WORKFLOW override is refused, not silently patched to \"CI\""
if err="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo CI_WORKFLOW= python3 -c "
import sys
sys.path.insert(0, '$board_dir')
import reconcile
print('UNEXPECTEDLY LOADED with CI_WORKFLOW=' + repr(reconcile.CI_WORKFLOW))
" 2>&1)"; then
  bad "reconcile.py loaded despite CI_WORKFLOW= : $err"
else
  if grep -qi "CI_WORKFLOW is empty" <<<"$err"; then
    ok "an empty CI_WORKFLOW override is refused loudly, naming itself"
  else
    bad "refused, but not with the expected message: $err"
  fi
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: CI_WORKFLOW has no second source of truth\n'
exit "$fail"
