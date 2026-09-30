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

# The external boundary is `gh` and `git`, so both are real or stubbed there and
# nowhere inside reconcile.py. `git` runs against a real bare origin holding the
# merge commit. `gh` is a script on PATH that logs every call and answers only
# `pr list`; a `gh run ...` call means reconcile went looking for a deploy.
git -C "$fixture_repo" -c user.email=t@e -c user.name=t commit -q --allow-empty -m seed
git init -q --bare "$work_dir/origin.git"
git -C "$fixture_repo" remote add origin "$work_dir/origin.git"
git -C "$fixture_repo" push -q origin main
merge_sha="$(git -C "$fixture_repo" rev-parse HEAD)"
stub_bin="$work_dir/bin"; gh_log="$work_dir/gh.log"
mkdir -p "$stub_bin"; : >"$gh_log"
cat >"$stub_bin/gh" <<GH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$gh_log"
if [[ "\$1 \$2" == "pr list" ]]; then
  printf '[{"number":7,"state":"MERGED","headRefOid":"%s","mergeStateStatus":"CLEAN","mergeCommit":{"oid":"%s"},"url":"https://example/pr/7","isDraft":false,"title":"t","statusCheckRollup":[],"isCrossRepository":false}]\\n' "$merge_sha" "$merge_sha"
  exit 0
fi
exit 1
GH
chmod +x "$stub_bin/gh"

py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"
board_home="$py_home/.foreman/instances/demo"

echo "==> what reconcile.py concludes when no [deploy] is configured"
# FOREMAN_HOME is named explicitly. config.sh no longer derives it from $HOME:
# it asks bin/installation.py, which reads the home as the parent of this
# clone. An explicit home is what that derivation yields to, and it is how this
# file stays pointed at its temporary directory.
HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
  BOARD_HOME="$board_home" PATH="$stub_bin:$PATH" GH_LOG="$gh_log" MERGE_SHA="$merge_sha" \
  python3 - "$here/../skills/board" <<'PY'
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


def deploy_calls():
    """Every `gh run ...` the stub saw: the lookup a no-deploy target must skip."""
    with open(os.environ["GH_LOG"]) as f:
        return [line for line in f if line.startswith("run ")]


sha = "c" * 40
verdict = reconcile.deploy_verdict(sha)
check(verdict.get("verified") is True,
      "deploy_verdict reports verified=True with no [deploy] configured", json.dumps(verdict))
check(verdict.get("terminal") is True,
      "deploy_verdict reports terminal=True with no [deploy] configured", json.dumps(verdict))
check(verdict.get("outcome") == "no-deploy-configured",
      "deploy_verdict names the outcome no-deploy-configured", json.dumps(verdict))

check(not deploy_calls(), "deploy_verdict made no gh run call with no [deploy] configured",
      repr(deploy_calls()))

# --- the same thing, through the tick's actual entry point -------------------
#
# deploy_verdict() alone proves the function; reconcile() proves the caller
# that actually decides `Done` never even reaches `gh run list`. The merge is
# real at the boundary: the `gh` on PATH answers `pr list` with a merged pull
# request, and the merge commit is on a real origin/main.
ticket = "PRA-99"
merge_sha = os.environ["MERGE_SHA"]

record = reconcile.reconcile(ticket, agents=[])
check(record["merged"] is True, "reconcile() sees the card as merged")
check(record["commit_on_main"] is True, "reconcile() sees the commit on main")
check(record["deploy"].get("verified") is True,
      "reconcile()'s own record reports deploy.verified=True with no [deploy] configured",
      json.dumps(record["deploy"]))
check(not deploy_calls(), "reconcile() made no gh run call with no [deploy] configured",
      repr(deploy_calls()))
# The three conditions SKILL.md's step 5 reads before moving a card to Done.
check(record["merged"] and record["commit_on_main"] and record["deploy"].get("verified"),
      "all three of SKILL.md's Done conditions hold for a target with no [deploy]")

if failures:
    print(f"\n{len(failures)} FAILURE(S)")
    sys.exit(1)
PY
