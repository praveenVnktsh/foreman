#!/usr/bin/env python3
"""What the board concludes from `gh`, without asking `gh` anything.

Run by `ops/tests/test-board-deploy-outcomes.sh`, which owns the description of
why these cases exist. Every case replaces `reconcile.run` and
`reconcile.run_json` outright, so nothing here touches the network, a checkout,
or GitHub — the subject is the *reasoning*, and the reasoning is what has been
wrong. Each defect below shipped and was found by a reviewer or by production.
"""

from __future__ import annotations

import io
import json
import os
import sys
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))          # ops/tests/lib
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
BOARD = os.path.join(REPO_ROOT, ".claude", "skills", "board")
sys.path.insert(0, BOARD)

import reconcile  # noqa: E402
import waitfor  # noqa: E402

FAILURES: list[str] = []

# Captured before any case runs, so `World.install()` can put it back.
REAL_COMMIT_ON_MAIN = reconcile.commit_on_main


def check(ok: bool, what: str, detail: str = "") -> None:
    if ok:
        print(f"    ok: {what}")
        return
    FAILURES.append(f"{what}{': ' + detail if detail else ''}")
    print(f"    FAIL: {what} {detail}")


# A run with no DEPLOY_STEP in it: what a skipped deploy job looks like once the
# run has completed. Distinct from an unreadable run, which is `None`.
NO_DEPLOY_STEP: dict = {"jobs": [{"steps": [{"name": "Set up job"}]}]}


def deploy_job(conclusion: str) -> dict:
    return {"jobs": [{"steps": [
        {"name": "Check out the tested main revision", "conclusion": "success"},
        {"name": reconcile.DEPLOY_STEP, "conclusion": conclusion},
    ]}]}


class World:
    """The only `gh` and `git` these functions get to see.

    `views` maps a run id to what `gh run view` answers; a missing id answers
    None, which is the lookup FAILING rather than the run having no deploy step.
    """

    def __init__(self, *, deploy_runs=(), views=None, ancestors=(),
                 ci_runs=(), attempt=1, prs=(), diff=(0, "")):
        self.deploy_runs = deploy_runs
        self.views = views or {}
        self.ancestors = set(ancestors)
        self.ci_runs = ci_runs
        self.attempt = attempt
        self.prs = prs
        self.diff = diff
        self.calls: list[list[str]] = []

    def run_json(self, args, cwd=None):
        self.calls.append(args)
        if args[:3] == ["gh", "run", "list"]:
            return self.ci_runs if "--branch" in args else self.deploy_runs
        if args[:3] == ["gh", "run", "view"]:
            return self.views.get(int(args[3]))
        if args[:2] == ["gh", "api"]:
            return self.attempt
        if args[:3] == ["gh", "pr", "list"]:
            return self.prs
        raise AssertionError(f"unstubbed run_json: {args}")

    def run(self, args, cwd=None):
        self.calls.append(args)
        if args[:2] == ["git", "fetch"]:
            return (0, "")
        if args[:2] == ["git", "merge-base"]:
            return (0, "") if (args[3], args[4]) in self.ancestors else (1, "")
        if args[:3] == ["gh", "pr", "diff"]:
            return self.diff
        raise AssertionError(f"unstubbed run: {args}")

    def install(self):
        reconcile.run_json = self.run_json
        reconcile.run = self.run
        # Reset the one reader a case can replace on its own. Two cases below
        # monkeypatch `commit_on_main` and nothing used to put it back, so a
        # deploy case appended after them would inherit "git cannot answer"
        # forever: it would return {"done": False} and pass whatever it asserted
        # about waiting, with the on-main check never running. Coverage that
        # reads as real is worse than none.
        reconcile.commit_on_main = REAL_COMMIT_ON_MAIN
        return self


def gh_run(rid, head, status="completed", conclusion="success"):
    return {"databaseId": rid, "headSha": head, "status": status,
            "conclusion": conclusion, "url": f"https://gh/run/{rid}"}


A = "a" * 40   # the card's merge commit
B = "b" * 40   # a merge that overtook it two minutes later


# --- deploy_verdict ---------------------------------------------------------

print("==> a failed `gh run list` is a failed lookup, not an absence of runs")
World(deploy_runs=None).install()
v = reconcile.deploy_verdict(A)
check(not v["verified"] and not v["terminal"], "an unreadable list keeps the wait open")
check("gh failed" in v["reason"], "it names the lookup", v["reason"])
check("no deploy-mango" not in v["reason"],
      "it does not claim there is no run yet", v["reason"])

print("==> a descendant's deploy that BROKE is this commit's answer, and it is final")
World(
    deploy_runs=[gh_run(2, B), gh_run(1, A)],
    views={2: deploy_job("failure"), 1: deploy_job("skipped")},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-failed",
      "a failed descendant deploy is terminal", json.dumps(v))
check(B[:12] in v["reason"], "it names the descendant that broke", v["reason"])

print("==> a stale-revision stand-down with a descendant still running is not final")
World(
    deploy_runs=[gh_run(2, B, status="in_progress", conclusion=""), gh_run(1, A)],
    views={1: deploy_job("skipped")},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and v["step_conclusion"] == "skipped",
      "a skipped step keeps the wait open", json.dumps(v))

print("==> a run that completed with no deploy step at all is final")
World(deploy_runs=[gh_run(1, A)], views={1: NO_DEPLOY_STEP}).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-never-ran",
      "a missing deploy step is terminal", json.dumps(v))

print("==> a run `gh run view` could not read teaches nothing and stops nothing")
World(deploy_runs=[gh_run(1, A)], views={}).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"], "an unreadable run keeps the wait open", json.dumps(v))
check("could not read" in v["reason"], "it says the run was unreadable", v["reason"])

print("==> a terminal failure wins over a NEWER stand-down, whatever the list order")
# ci.yml gives every push its own concurrency group, and one self-hosted runner
# serves them, so CI for A and CI for B queue and can complete out of order.
# deploy-mango is workflow_run-triggered, so BOTH deploy runs report
# headSha = main's tip = B. The older run (id 1) checked out B
# and broke; the newer one (id 2) stood down. First-writer-wins over a
# newest-first list discarded the failure and waited the budget every tick —
# this card's own defect, surviving by ordering.
World(
    deploy_runs=[gh_run(2, B), gh_run(1, B)],
    views={2: deploy_job("skipped"), 1: deploy_job("failure")},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-failed",
      "an older failure beats a newer stand-down", json.dumps(v))
check("run 1" in v["reason"], "and it is the failing run that is named", v["reason"])

print("==> a successful deploy still wins over a newer failure")
World(
    deploy_runs=[gh_run(3, B), gh_run(2, A)],
    views={3: deploy_job("failure"), 2: deploy_job("success")},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(v["verified"] and v["terminal"], "an own successful deploy verifies", json.dumps(v))

print("==> a descendant that does not carry this commit is never consulted")
w = World(deploy_runs=[gh_run(9, B)], views={9: deploy_job("failure")}).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and v["reason"].endswith("yet"),
      "an unrelated failure is not this commit's", json.dumps(v))
check(not any(c[:3] == ["gh", "run", "view"] for c in w.calls),
      "ancestry is checked before the network round trip")


# --- waitfor.deploy_state / wait --------------------------------------------

def wait_once(state: dict) -> tuple[int, dict]:
    """One poll of `wait`, with its stdout captured."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = waitfor.wait(lambda: state, 1, "test")
    return code, json.loads(buf.getvalue())


print("==> a deploy that ran and failed is exit 3 and never `satisfied`")
World(
    deploy_runs=[gh_run(2, B), gh_run(1, A)],
    views={2: deploy_job("failure"), 1: deploy_job("skipped")},
    ancestors={(A, B)},
).install()
state = waitfor.deploy_state(A)
check(not state.get("done") and state.get("stop"), "the state stops the wait", json.dumps(state))
code, out = wait_once(state)
# 3 and not 2: argparse exits 2 for a usage error and prints no JSON at all, so
# a settled-and-failed 2 would read a mistyped command as a broken production.
check(code == 3, f"exit 3, got {code}")
check(out["satisfied"] is False, "not satisfied", json.dumps(out))
check(out["outcome"] == "deploy-failed", "outcome names the failure", json.dumps(out))

print("==> a verified deploy is exit 0 and satisfied")
World(deploy_runs=[gh_run(1, A)], views={1: deploy_job("success")}).install()
code, out = wait_once(waitfor.deploy_state(A))
check(code == 0 and out["satisfied"] is True and out["outcome"] == "satisfied",
      "a real deploy satisfies the wait", json.dumps(out))

print("==> a commit that is not on main stops the wait without satisfying it")
World(deploy_runs=[]).install()
reconcile.commit_on_main = lambda sha: False
code, out = wait_once(waitfor.deploy_state(A))
check(code == 3 and out["outcome"] == "not-on-main",
      "not-on-main is its own outcome", json.dumps(out))
World(deploy_runs=[]).install()
check(reconcile.commit_on_main is REAL_COMMIT_ON_MAIN,
      "installing a world restores the reader the last case replaced")

print("==> a budget that expires is still exit 1")
code, out = wait_once({"done": False})
check(code == 1 and out["satisfied"] is False and out["outcome"] == "budget-expired",
      "the timeout outcome is unchanged", json.dumps(out))

print("==> git failing to answer keeps the wait open rather than stopping it")
World(deploy_runs=[]).install()
reconcile.commit_on_main = lambda sha: None
state = waitfor.deploy_state(A)
check(not state.get("done") and not state.get("stop"),
      "an unanswerable git keeps waiting", json.dumps(state))


# --- main_ci_state ----------------------------------------------------------

def ci(conclusion, status="completed", attempt=1):
    World(ci_runs=[gh_run(7, A, status=status, conclusion=conclusion)],
          attempt=attempt).install()
    return reconcile.main_ci_state()


print("==> a cancelled or startup_failure run is `main` untested, never `main` red")
for concl in ("cancelled", "startup_failure", "stale", "skipped",
              "action_required", "timed_out"):
    s = ci(concl)
    check(s["verdict"] == "untested", f"{concl} is untested", s["verdict"])
    check(A[:12] not in s["reason"], f"{concl} names no commit", s["reason"])

print("==> a real failure is still red, and names the commit")
s = ci("failure")
check(s["verdict"] == "red", "failure is red", s["verdict"])
check(A[:12] in s["reason"], "red names the commit that broke it", s["reason"])

print("==> a completed run with no conclusion accuses nobody either")
s = ci("")
check(s["verdict"] == "untested", "an empty conclusion is untested", s["verdict"])
check(A[:12] not in s["reason"], "and names no commit", s["reason"])

print("==> green, and a run that has not concluded")
check(ci("success")["verdict"] == "green", "success is green")
check(ci("neutral")["verdict"] == "green", "neutral is green")
check(ci("", status="in_progress")["verdict"] == "running",
      "an unfinished FIRST attempt is not red")

print("==> a re-run in flight is `rerunning`, and never licenses dispatch")
# The recovery defeating the stand-down it recovers from: `gh run rerun` resets
# the SAME run to in_progress with a null conclusion, so the next tick used to
# read `running` — whose documented licence to dispatch rests on "the branch
# point is a commit that already passed". Here it is a commit that concluded
# failure minutes ago.
s = ci("", status="in_progress", attempt=2)
check(s["verdict"] == "rerunning", "attempt 2 in flight is its own verdict", s["verdict"])
check(s["attempt"] == 2, "and it carries the attempt count", json.dumps(s))
check(s["rerunnable"] is False, "a re-run already in flight is not re-run again")
World(ci_runs=[gh_run(7, A, status="queued", conclusion="")], attempt=None).install()
s = reconcile.main_ci_state()
check(s["verdict"] == "unknown",
      "an in-flight run whose attempt cannot be read is not `running`", s["verdict"])

print("==> an empty answer and a failed lookup are different answers")
World(ci_runs=[]).install()
check(reconcile.main_ci_state()["verdict"] == "none", "no runs at all is `none`")
World(ci_runs=None).install()
s = reconcile.main_ci_state()
check(s["verdict"] == "unknown", "a failed lookup is `unknown`")
check(s["rerunnable"] is False, "an unknown state is never re-run")

print("==> one re-run per run, bounded by GitHub's own attempt count")
s = ci("failure", attempt=1)
check(s["rerunnable"] is True and s["rerun"] == "gh run rerun 7",
      "a first attempt is re-runnable", json.dumps(s))
check(ci("failure", attempt=2)["rerunnable"] is False,
      "a second attempt is not re-run again")
check(ci("cancelled", attempt=1)["rerunnable"] is True,
      "an untested `main` recovers the same way")
World(ci_runs=[gh_run(7, A, conclusion="failure")], attempt=None).install()
check(reconcile.main_ci_state()["rerunnable"] is False,
      "an unreadable attempt count is not re-run")
check(ci("success")["rerunnable"] is False, "a green `main` is never re-run")


# --- pr_for -----------------------------------------------------------------

print("==> an unreadable diff still reports everything that is not about the diff")
World(
    prs=[{"number": 5, "state": "OPEN", "isDraft": True,
          "mergeStateStatus": "BEHIND", "statusCheckRollup": []}],
    diff=(1, ""),
).install()
pr = reconcile.pr_for("PRA-1")
check(pr["risk"] == "unknown", "the diff is unknown", json.dumps(pr.get("risk")))
check(pr["needs_update"] is True and pr["is_draft"] is True,
      "needs_update and is_draft survive the unreadable path", json.dumps(pr))

if FAILURES:
    print("\nFAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
print("\nPASS")
