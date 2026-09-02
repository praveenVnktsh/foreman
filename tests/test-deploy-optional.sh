#!/usr/bin/env bash
# A target that declares no `[deploy]` at all must still be able to reach
# `Done`. board.toml's own comment and the design spec both say "no [deploy]
# means merged is done" -- but `reconcile.deploy_verdict()` ran `gh run list
# --workflow ""` unconditionally, for every target with no [deploy], including
# foreman's own board.toml (this repository IS instance #1 -- see board.toml's
# header). Nothing in reconcile.py or SKILL.md ever produced `deploy.verified:
# true` for that case, so a card on such a target could build, review and
# merge, and then sit in `In Review` forever waiting for a deploy that was
# never configured and was never going to run.
#
# `reconcile` shells out to config.sh at import time (see reconcile.py's own
# `_load_config`), which since Task 2/3 requires a FOREMAN_INSTANCE and an
# instance directory declaring a REPO whose board.toml passes
# bin/contract.py. This file's fixture instance is the point: its board.toml
# declares no [deploy] table.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
git -C "$fixture_repo" init -q -b main
cat >"$fixture_repo/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "fixture"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
TOML
# No [deploy] table above -- deliberately.

py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"
board_home="$py_home/.foreman/instances/demo"

echo "==> what reconcile.py concludes when no [deploy] is configured"
HOME="$py_home" FOREMAN_INSTANCE=demo BOARD_HOME="$board_home" python3 - "$here/../skills/board" <<'PY'
import json
import os
import sys

sys.path.insert(0, sys.argv[1])
import reconcile  # noqa: E402

failures = []


def check(ok, what, detail=""):
    if ok:
        print(f"    ok: {what}")
    else:
        failures.append(f"{what}{': ' + detail if detail else ''}")
        print(f"    FAIL: {what} {detail}")


check(reconcile.DEPLOY_WORKFLOW == "", "the fixture contract loads DEPLOY_WORKFLOW empty",
      repr(reconcile.DEPLOY_WORKFLOW))
check(reconcile.DEPLOY_STEP == "", "the fixture contract loads DEPLOY_STEP empty",
      repr(reconcile.DEPLOY_STEP))


def explode(*args, **kwargs):
    raise AssertionError(f"gh/git was called when no [deploy] is configured: {args!r} {kwargs!r}")


reconcile.run_json = explode
reconcile.run = explode

sha = "c" * 40
verdict = reconcile.deploy_verdict(sha)
check(verdict.get("verified") is True,
      "deploy_verdict reports verified=True with no [deploy] configured", json.dumps(verdict))
check(verdict.get("terminal") is True,
      "deploy_verdict reports terminal=True with no [deploy] configured", json.dumps(verdict))
check(verdict.get("outcome") == "no-deploy-configured",
      "deploy_verdict names the outcome no-deploy-configured", json.dumps(verdict))

# --- the same thing, through the tick's actual entry point -------------------
#
# deploy_verdict() alone proves the function; reconcile() proves the caller
# that actually decides `Done` never even reaches `gh run list`. `pr_for` and
# `commit_on_main` are stubbed to report a clean merge without touching gh or
# git -- the subject here is deploy reasoning, not merge detection, which
# tests/test-board-deploy-outcomes.sh already covers.
ticket = "PRA-99"
merge_sha = "d" * 40
reconcile.pr_for = lambda t: {
    "number": 7, "state": "MERGED", "mergeCommit": {"oid": merge_sha},
    "url": "https://example/pr/7", "checks": {},
}
reconcile.commit_on_main = lambda sha: True
# `plan_pushed` asks origin for the card's branch, for the same reason `pr_for`
# asks gh for the pull request: it is a reader this file is not about. The
# claim here is that the DEPLOY path makes no call when no deploy is
# configured, and `run = explode` is how that is caught -- so every other
# reader reconcile() legitimately uses is stubbed, exactly as the two above are.
reconcile.plan_pushed = lambda branch: {"state": "absent", "reason": "stubbed"}

record = reconcile.reconcile(ticket, agents=[])
check(record["merged"] is True, "reconcile() sees the card as merged")
check(record["commit_on_main"] is True, "reconcile() sees the commit on main")
check(record["deploy"].get("verified") is True,
      "reconcile()'s own record reports deploy.verified=True with no [deploy] configured",
      json.dumps(record["deploy"]))
# The three conditions SKILL.md's step 5 reads before moving a card to Done.
check(record["merged"] and record["commit_on_main"] and record["deploy"].get("verified"),
      "all three of SKILL.md's Done conditions hold for a target with no [deploy]")

if failures:
    print(f"\n{len(failures)} FAILURE(S)")
    sys.exit(1)
PY
