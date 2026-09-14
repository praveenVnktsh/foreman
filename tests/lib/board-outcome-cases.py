#!/usr/bin/env python3
"""What the board concludes from `gh`, without asking `gh` anything.

Run by `tests/test-board-deploy-outcomes.sh`, which owns the description of
why these cases exist. Every case replaces `reconcile.run` and
`reconcile.run_json` outright, so nothing here touches the network, a checkout,
or GitHub — the subject is the *reasoning*, and the reasoning is what has been
wrong. Each defect below shipped and was found by a reviewer or by production.

Importing `reconcile` shells out to `config.sh`, which since Task 2/3 refuses
to load without a FOREMAN_INSTANCE and an instance directory declaring a
REPO whose board.toml passes `bin/contract.py`. The caller sets that up
(see tests/lib/instance-fixture.sh) before running this file.
"""

from __future__ import annotations

import io
import json
import os
import sys
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))          # tests/lib
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
BOARD = os.path.join(REPO_ROOT, "skills", "board")
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


SELECTION_STEP = "Choose the revision to deploy"


def selection_job(job_id: int, selection: str, deploy: str) -> dict:
    """A deploy run whose one job holds the selection step and the deploy step.

    The job carries a `databaseId` because the selection's reason is only in
    that job's log: `gh run view --json jobs` has no step outputs.
    """
    return {"jobs": [{"databaseId": job_id, "steps": [
        {"name": "Set up job", "conclusion": "success"},
        {"name": SELECTION_STEP, "conclusion": selection},
        {"name": reconcile.DEPLOY_STEP, "conclusion": deploy},
    ]}]}


def job_log(reason: str) -> str:
    """A raw job log as GitHub serves it: a timestamp, one space, the content."""
    stamp = "2026-09-14T22:09:28.8742176Z"
    return "\r\n".join(f"{stamp} {line}" for line in (
        "##[group]Run scripts/choose-revision.sh", "deploy=false",
        f"revision={B}", f"reason={reason}",
    )) + "\r\n"


def log_fetches(w: "World") -> list[list[str]]:
    return [c for c in w.calls if c[:2] == ["gh", "api"] and c[2].endswith("/logs")]


class World:
    """The only `gh` and `git` these functions get to see.

    `views` maps a run id to what `gh run view` answers; a missing id answers
    None, which is the lookup FAILING rather than the run having no deploy step.
    `logs` maps a job id to its raw log; a missing id is `gh api` failing.
    """

    def __init__(self, *, deploy_runs=(), views=None, ancestors=(),
                 ci_runs=(), attempt=1, prs=(), diff=(0, ""),
                 ls_remote=(2, ""), compare=(0, "[]"), logs=None):
        self.deploy_runs = deploy_runs
        self.views = views or {}
        self.logs = logs or {}
        self.ancestors = set(ancestors)
        self.ci_runs = ci_runs
        self.attempt = attempt
        self.prs = prs
        self.diff = diff
        # A card with no branch on origin is the default, so a case about
        # something else never has to say anything about the plan.
        self.ls_remote = ls_remote
        self.compare = compare
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
        if args[:2] == ["git", "ls-remote"]:
            return self.ls_remote
        # Matched on the compare path, not on `gh api` alone: a later `gh api`
        # asking something else must still hit the AssertionError below rather
        # than quietly collect this answer.
        if args[:2] == ["gh", "api"] and "/compare/" in args[2]:
            return self.compare
        # The exact path reconcile.selection_reason asks for, so a reader that
        # fetched some other job's log, or the run's, hits the AssertionError.
        prefix, suffix = "repos/{owner}/{repo}/actions/jobs/", "/logs"
        if (len(args) == 3 and args[:2] == ["gh", "api"]
                and args[2].startswith(prefix) and args[2].endswith(suffix)):
            job_id = int(args[2][len(prefix):-len(suffix)])
            return (0, self.logs[job_id]) if job_id in self.logs else (1, "")
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


def gh_run(rid, head, status="completed", conclusion="success", event="workflow_run"):
    return {"databaseId": rid, "headSha": head, "status": status,
            "conclusion": conclusion, "url": f"https://gh/run/{rid}", "event": event}


A = "a" * 40   # the card's merge commit
B = "b" * 40   # a merge that overtook it two minutes later


# --- deploy_verdict ---------------------------------------------------------

print("==> a failed `gh run list` is a failed lookup, not an absence of runs")
World(deploy_runs=None).install()
v = reconcile.deploy_verdict(A)
check(not v["verified"] and not v["terminal"], "an unreadable list keeps the wait open")
check("gh failed" in v["reason"], "it names the lookup", v["reason"])
check("no deploy run" not in v["reason"],
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
# the deploy workflow is workflow_run-triggered, so BOTH deploy runs report
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

# --- deploy_verdict with a selection step ------------------------------------
#
# The target's deploy workflow now QUEUES merges for a scheduled run. Its
# selection step says why in a `reason=` line that only the job log holds. A
# skipped deploy step looks the same whether the run queued the commit or stood
# down for a descendant, so every case below turns on the reason being READ.

QUEUED = "queued: nothing up to aaaaaaa is labelled fast-track; the next scheduled run deploys it"
STAND_DOWN = "stand-down: a newer revision is already on its way"

print("==> a run that queued this commit is terminal, and it read the reason to say so")
w = World(deploy_runs=[gh_run(1, A)],
          views={1: selection_job(77, "success", "skipped")},
          logs={77: job_log(QUEUED)}).install()
v = reconcile.deploy_verdict(A)
check(v.get("terminal") and v.get("outcome") == "deploy-queued",
      "a queued run is terminal as deploy-queued", json.dumps(v))
check(v["verified"] is False, "and it is never verified", json.dumps(v))
check(len(log_fetches(w)) == 1 and log_fetches(w)[0][2].endswith("/jobs/77/logs"),
      "the reason came from the selection job's log", str(log_fetches(w)))

print("==> a stand-down skip reads its reason and still waits")
w = World(deploy_runs=[gh_run(1, A)],
          views={1: selection_job(77, "success", "skipped")},
          logs={77: job_log(STAND_DOWN)}).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and v.get("outcome") is None,
      "a stand-down is not terminal", json.dumps(v))
check((v.get("selection_reason") or "").startswith("stand-down:"),
      "the reason was read, not inferred from the skip", json.dumps(v))

print("==> a skipped deploy whose log cannot be read never reads as queued")
w = World(deploy_runs=[gh_run(1, A)],
          views={1: selection_job(77, "success", "skipped")},
          logs={}).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and v.get("outcome") != "deploy-queued",
      "an unreadable log keeps the wait open", json.dumps(v))
check(len(log_fetches(w)) == 1 and "could not read" in v["reason"],
      "it tried the log and says it could not read the reason", v["reason"])

print("==> a selection that failed is terminal, and no log is fetched for it")
w = World(deploy_runs=[gh_run(1, A)],
          views={1: selection_job(77, "failure", "skipped")},
          logs={77: job_log(QUEUED)}).install()
v = reconcile.deploy_verdict(A)
check(v.get("terminal") and v.get("outcome") == "deploy-selection-failed",
      "a failed selection is deploy-selection-failed", json.dumps(v))
check(v["verified"] is False, "and it is not verified", json.dumps(v))
check(not log_fetches(w), "a failed selection has no reason worth a log fetch",
      str(log_fetches(w)))

print("==> a scheduled run's deploy on a descendant verifies, past a newer queued run")
# The scheduled run is what deploys a queued commit, so a run list filtered to
# `workflow_run` would never see the answer. The newer queued run is terminal,
# and it must still lose to a deploy that happened.
w = World(
    deploy_runs=[gh_run(3, B), gh_run(2, B, event="schedule")],
    views={3: selection_job(79, "success", "skipped"),
           2: selection_job(78, "success", "success")},
    logs={79: job_log(QUEUED)},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(v["verified"] is True, "the scheduled descendant deploy verifies", json.dumps(v))
check([c[2] for c in log_fetches(w)] == ["repos/{owner}/{repo}/actions/jobs/79/logs"],
      "the newer run was read as queued first, and the deploy still won",
      str(log_fetches(w)))
list_calls = [c for c in w.calls if c[:3] == ["gh", "run", "list"]]
check(len(list_calls) == 1 and not any(a.startswith("--event") for a in list_calls[0]),
      "gh run list does not filter by event", str(list_calls))

print("==> an older failure still beats a newer queued run")
w = World(
    deploy_runs=[gh_run(2, B), gh_run(1, B)],
    views={2: selection_job(78, "success", "skipped"),
           1: selection_job(77, "success", "failure")},
    logs={78: job_log(QUEUED)},
    ancestors={(A, B)},
).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-failed" and "run 1" in v["reason"],
      "the broken production is the answer, naming the older run", json.dumps(v))
check([c[2] for c in log_fetches(w)] == ["repos/{owner}/{repo}/actions/jobs/78/logs"],
      "the queued run was read, and lost on rank", str(log_fetches(w)))


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

print("==> a queued deploy is exit 0 and satisfied, named deploy-queued")
World(deploy_runs=[gh_run(1, A)],
      views={1: selection_job(77, "success", "skipped")},
      logs={77: job_log(QUEUED)}).install()
state = waitfor.deploy_state(A)
check(state.get("done") is True, "the queued state is done", json.dumps(state))
code, out = wait_once(state)
check(code == 0 and out["satisfied"] is True and out["outcome"] == "deploy-queued",
      "a queued deploy satisfies the wait under its own outcome", json.dumps(out))

print("==> a stand-down on main keeps waiting")
World(deploy_runs=[gh_run(1, A)],
      views={1: selection_job(77, "success", "skipped")},
      logs={77: job_log(STAND_DOWN)}).install()
# On main, so the not-on-main stop cannot be what keeps this from `done`.
reconcile.commit_on_main = lambda sha: True
state = waitfor.deploy_state(A)
check(not state.get("done") and not state.get("stop"),
      "a stand-down neither satisfies nor stops the wait", json.dumps(state))
check((state.get("verdict", {}).get("selection_reason") or "").startswith("stand-down:"),
      "and it waits on a reason it read", json.dumps(state))

print("==> a failed selection is exit 3 and never satisfied")
World(deploy_runs=[gh_run(1, A)],
      views={1: selection_job(77, "failure", "skipped")}).install()
code, out = wait_once(waitfor.deploy_state(A))
check(code == 3 and out["satisfied"] is False
      and out["outcome"] == "deploy-selection-failed",
      "a failed selection stops the wait under its own outcome", json.dumps(out))


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

print("==> pr_for's --head branch carries this instance's namespace, not just the ticket")
# Reverting `return f"{BOARD_NAME_PREFIX}/{ticket}"` back to
# `f"board/{ticket}"` is the most consequential regression in this file: get it
# wrong and reconcile never finds the pull request for any card again. The
# fixture's home has no installation.toml, so its names are legacy and the
# branch is foreman/<board>/<ticket>: the branch an un-migrated machine's open
# pull requests sit on. The World stub's
# dispatch on `run_json` matches only on args[:3] (["gh", "pr", "list"]) and
# answers the same `prs` regardless of `--head`, so this has to inspect the
# recorded call directly rather than trust the stub to notice a wrong branch.
w = World(prs=[]).install()
reconcile.pr_for("PRA-7")
pr_list_calls = [c for c in w.calls if c[:3] == ["gh", "pr", "list"]]
check(len(pr_list_calls) == 1, "exactly one gh pr list call", str(pr_list_calls))
head = None
if pr_list_calls and "--head" in pr_list_calls[0]:
    head = pr_list_calls[0][pr_list_calls[0].index("--head") + 1]
check(head == f"foreman/{reconcile.INSTANCE}/PRA-7",
      "the --head value is the instance-scoped branch, not board/PRA-7", head)

print("==> reconcile()'s worktree field finds the instance-scoped worktree dispatch.sh actually creates")
# `worktree = os.path.join(REPO, ".claude", "worktrees",
#                          f"{BOARD_WORKTREE_PREFIX}-{ticket}")`
# has to match what `worktree_path()` in config.sh actually names, or every
# card's reported worktree reads as absent. Only a directory at the CORRECT
# name is created, so a reversion to the old `board-{ticket}` shape (or any
# other mismatch) reports `None` here instead of the real path.
World(prs=[]).install()
wt_dir = os.path.join(
    reconcile.REPO, ".claude", "worktrees",
    f"foreman-{reconcile.INSTANCE}-PRA-8")
os.makedirs(wt_dir, exist_ok=True)
record = reconcile.reconcile("PRA-8", [])
check(record["worktree"] == wt_dir,
      "the worktree path reconcile() looks for is the one dispatch.sh creates",
      record["worktree"])


if FAILURES:
    print("\nFAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
print("\nPASS")
