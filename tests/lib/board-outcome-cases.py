#!/usr/bin/env python3
"""What the board concludes from `gh` and `git`, with only GitHub replaced.

Run by `tests/test-board-deploy-outcomes.sh`, which owns the description of
why these cases exist. Each defect below shipped and was found by a reviewer or
by production.

`reconcile.run` and `reconcile.run_json` run for real. Every `gh` they start is
`tests/lib/gh-scenario-stub.py`, first on PATH, answering from the scenario
the case's `World` writes. Every `git` is real git, in a checkout of a small
real origin built below. So the argv reconcile builds, the exit codes it reads
and the JSON it parses are all under test, not only the reasoning over them.

Importing `reconcile` shells out to `config.sh`, which refuses to load without
a FOREMAN_INSTANCE and an instance directory declaring a REPO whose board.toml
passes `bin/contract.py`. The caller sets that up (see
tests/lib/instance-fixture.sh) before running this file, and declares
`db/migrations/` as the one risk path.
"""

from __future__ import annotations

import atexit
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))          # tests/lib
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
BOARD = os.path.join(REPO_ROOT, "skills", "board")
GH_STUB = os.path.join(HERE, "gh-scenario-stub.py")
sys.path.insert(0, BOARD)

import reconcile  # noqa: E402
import waitfor  # noqa: E402

FAILURES: list[str] = []

# The one risk path the fixture's board.toml declares. Read through config.sh
# like any other target's, so the risk scan below reads a real contract.
RISK_PATH = "db/migrations/"
if reconcile.HIGH_RISK_PATHS != [RISK_PATH]:
    sys.exit(f"board-outcome-cases: the fixture must declare [risk] paths = "
             f"[{RISK_PATH!r}]; config.sh gave {reconcile.HIGH_RISK_PATHS}")


def check(ok: bool, what: str, detail: str = "") -> None:
    if ok:
        print(f"    ok: {what}")
        return
    FAILURES.append(f"{what}{': ' + detail if detail else ''}")
    print(f"    FAIL: {what} {detail}")


# --- the git world ------------------------------------------------------------
#
# A real origin with main at BASE -> A -> B. SIDE is cut from BASE and LATE
# from B, each on a branch of its own. REPO is a checkout of it, which is where
# reconcile runs git.

SCRATCH = tempfile.mkdtemp(prefix="board-outcomes-")
atexit.register(shutil.rmtree, SCRATCH, ignore_errors=True)
ORIGIN = os.path.join(SCRATCH, "origin.git")
# Where REPO's origin points while a case needs `git fetch` to fail.
UNREACHABLE = os.path.join(SCRATCH, "no-such-origin.git")
AUTHOR = os.path.join(SCRATCH, "author")


def git(cwd: str, *args: str) -> str:
    """git in `cwd`, with an identity and no signing, whatever the machine says."""
    done = subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
         "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, capture_output=True, text=True, check=True)
    return done.stdout.strip()


def commit(message: str) -> str:
    with open(os.path.join(AUTHOR, "log.txt"), "a", encoding="utf-8") as f:
        f.write(message + "\n")
    git(AUTHOR, "add", "log.txt")
    git(AUTHOR, "commit", "-q", "-m", message)
    return git(AUTHOR, "rev-parse", "HEAD")


# REPO holds only the fixture's board.toml. Refuse anything that is already a
# checkout: this file rewrites its origin, and a real one is not a fixture.
if os.path.exists(os.path.join(reconcile.REPO, ".git")):
    sys.exit(f"board-outcome-cases: REPO {reconcile.REPO} is already a git "
             f"checkout; point it at an empty fixture directory")
git(SCRATCH, "init", "-q", "--bare", ORIGIN)
git(ORIGIN, "symbolic-ref", "HEAD", "refs/heads/main")
os.makedirs(AUTHOR)
git(AUTHOR, "init", "-q", "-b", "main")
git(AUTHOR, "remote", "add", "origin", ORIGIN)
BASE = commit("base")
A = commit("the card's merge commit")
B = commit("a merge that overtook it two minutes later")
git(AUTHOR, "push", "-q", "origin", "main")
git(AUTHOR, "checkout", "-q", "-b", "side", BASE)
SIDE = commit("a commit that does not carry the card's")
git(AUTHOR, "push", "-q", "origin", "side")
# On origin under a branch of its own, and later made main's tip by one case.
git(AUTHOR, "checkout", "-q", "-b", "late", B)
LATE = commit("a merge after B")
git(AUTHOR, "push", "-q", "origin", "late")
git(reconcile.REPO, "init", "-q")
git(reconcile.REPO, "remote", "add", "origin", ORIGIN)
git(reconcile.REPO, "fetch", "-q", "origin")
# A head no checkout has: git answers 128 for it, never 0 or 1.
GHOST = "f" * 40

# --- the gh world ---------------------------------------------------------------

STUB_BIN = os.path.join(SCRATCH, "bin")
SCENARIO = os.path.join(SCRATCH, "scenario.json")
CALLS = os.path.join(SCRATCH, "calls.jsonl")
os.makedirs(STUB_BIN)
with open(os.path.join(STUB_BIN, "gh"), "w", encoding="utf-8") as f:
    f.write(f'#!/bin/sh\nexec "{sys.executable}" "{GH_STUB}" "$@"\n')
os.chmod(os.path.join(STUB_BIN, "gh"), 0o755)
os.environ["PATH"] = STUB_BIN + os.pathsep + os.environ.get("PATH", "")
os.environ["GH_STUB_SCENARIO"] = SCENARIO
os.environ["GH_STUB_LOG"] = CALLS

TICKET = "ACME-1"


GH_FAILED = {"exit": 1, "stderr": "HTTP 502: Bad Gateway\n"}


def answer(value) -> dict:
    """A scenario answer: None is gh failing, a str is raw output, else JSON."""
    if value is None:
        return GH_FAILED
    if isinstance(value, str):
        return {"stdout": value}
    return {"stdout": json.dumps(value)}


def listing(rows) -> dict:
    """A list answer: None is gh failing, any other iterable is the rows."""
    return GH_FAILED if rows is None else answer(list(rows))


def exited(result: tuple[int, str]) -> dict:
    """A raw answer, as `(exit code, stdout)`."""
    code, out = result
    return {"exit": code, "stdout": out}


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


# What the pull request files API prints through reconcile's `--jq`: one JSON
# list per file. Spelled here rather than read from reconcile, because the
# scripted answer is only what gh prints if the program is this one.
FILES_JQ = '.[] | [.filename, (.previous_filename // "")] | @json'

# The world the last `install()` set up, so the next one can settle it.
_installed: "World | None" = None


class World:
    """What `gh` answers, and whether git can reach origin, for one case.

    `views` maps a run id to what `gh run view` answers, and `logs` maps a job
    id to its raw log; None is gh failing. An id missing from either is not
    scripted at all, and a call for it fails the case: a case about a failed
    read says so with None. `deploy_runs`, `ci_runs` and `attempt` of None are
    the list or the counter failing to read.
    """

    def __init__(self, *, deploy_runs=(), views=None, ci_runs=(), attempt=1,
                 prs=(), diff=(0, ""), files=(1, ""), logs=None,
                 ticket=TICKET, origin_reachable=True):
        self.origin_reachable = origin_reachable
        self.settled = False
        workflow = reconcile.DEPLOY_WORKFLOW
        runs = "{owner}/{repo}/actions"
        self.scenario = {
            f"run list --workflow {workflow} *": listing(deploy_runs),
            f"run list --workflow {reconcile.CI_WORKFLOW} --branch main *":
                listing(ci_runs),
            # The branch is spelled out, not taken from reconcile.branch_for:
            # a pull request looked up on any other branch is unscripted.
            f"pr list --head foreman/{reconcile.INSTANCE}/{ticket} --state all --json *":
                listing(prs),
        }
        for rid, view in (views or {}).items():
            self.scenario[f"run view {rid} --json jobs"] = answer(view)
        for job_id, text in (logs or {}).items():
            self.scenario[f"api repos/{runs}/jobs/{job_id}/logs"] = answer(text)
        for r in ci_runs or ():
            self.scenario[f"api repos/{runs}/runs/{r['databaseId']} --jq .run_attempt"] = \
                answer(attempt)
        for p in prs or ():
            n = p["number"]
            self.scenario[f"pr diff {n} --name-only"] = exited(diff)
            self.scenario[f"api repos/{{owner}}/{{repo}}/pulls/{n}/files "
                          f"--paginate --jq {FILES_JQ}"] = exited(files)

    def _logged(self) -> list[dict]:
        if not os.path.exists(CALLS):
            return []
        with open(CALLS, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    @property
    def calls(self) -> list[list[str]]:
        """Every gh call this case made, in order, as its full argv."""
        return [["gh", *e["argv"]] for e in self._logged()]

    def settle(self) -> None:
        """Fail the case if gh was asked anything its scenario did not script."""
        if self.settled:
            return
        self.settled = True
        for e in self._logged():
            if e["exit"] == 97:
                what = "gh " + " ".join(e["argv"])
                FAILURES.append(f"unscripted call: {what}")
                print(f"    FAIL: unscripted call: {what}")

    def install(self) -> "World":
        global _installed
        if _installed is not None:
            _installed.settle()
        with open(SCENARIO, "w", encoding="utf-8") as f:
            json.dump(self.scenario, f)
        open(CALLS, "w").close()
        git(reconcile.REPO, "remote", "set-url", "origin",
            ORIGIN if self.origin_reachable else UNREACHABLE)
        _installed = self
        return self


def _settle_last() -> None:
    """Name the unscripted call even when a case crashed on its answer."""
    if _installed is not None:
        _installed.settle()


atexit.register(_settle_last)


def gh_run(rid, head, status="completed", conclusion="success", event="workflow_run"):
    return {"databaseId": rid, "headSha": head, "status": status,
            "conclusion": conclusion, "url": f"https://gh/run/{rid}", "event": event}


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
).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-failed",
      "a failed descendant deploy is terminal", json.dumps(v))
check(B[:12] in v["reason"], "it names the descendant that broke", v["reason"])

print("==> a stale-revision stand-down with a descendant still running is not final")
World(
    deploy_runs=[gh_run(2, B, status="in_progress", conclusion=""), gh_run(1, A)],
    views={1: deploy_job("skipped")},
).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and v["step_conclusion"] == "skipped",
      "a skipped step keeps the wait open", json.dumps(v))

print("==> a run that completed with no deploy step at all is final")
World(deploy_runs=[gh_run(1, A)], views={1: NO_DEPLOY_STEP}).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-never-ran",
      "a missing deploy step is terminal", json.dumps(v))

print("==> a run that never deployed is not final while a descendant's deploy is running")
# The commit's own run completed with no deploy job, which alone is final. But
# B, which carries A, is still deploying, and its deploy verifies A. Ending the
# wait on A's own run reported "no deploy will carry it" while one was running.
World(
    deploy_runs=[gh_run(2, B, status="in_progress", conclusion=""), gh_run(1, A)],
    views={1: NO_DEPLOY_STEP},
).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and not v["verified"],
      "a descendant deploy in flight keeps the wait open", json.dumps(v))
check(B[:12] in v["reason"], "it names the descendant still deploying", v["reason"])

print("==> a run git cannot place is not a run that does not carry the commit")
# `merge-base --is-ancestor` exits 128 for a head this checkout never fetched.
# Read as "not an ancestor", the successful deploy of a descendant was skipped,
# and A's own run -- which completed with no deploy job -- ended the wait as
# final. Here origin cannot be reached, so the head stays one git never saw.
World(
    deploy_runs=[gh_run(2, GHOST), gh_run(1, A)],
    views={2: deploy_job("success"), 1: NO_DEPLOY_STEP},
    origin_reachable=False,
).install()
v = reconcile.deploy_verdict(A)
check(not v["terminal"] and not v["verified"],
      "an unplaceable run keeps the wait open", json.dumps(v))
check("2" in v["reason"] and "git fetch origin failed" in v["reason"],
      "it names the run and the failed fetch", v["reason"])

print("==> a run `gh run view` could not read teaches nothing and stops nothing")
World(deploy_runs=[gh_run(1, A)], views={1: None}).install()
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
).install()
v = reconcile.deploy_verdict(A)
check(v["terminal"] and v["outcome"] == "deploy-failed",
      "an older failure beats a newer stand-down", json.dumps(v))
check("run 1" in v["reason"], "and it is the failing run that is named", v["reason"])

print("==> a successful deploy still wins over a newer failure")
World(
    deploy_runs=[gh_run(3, B), gh_run(2, A)],
    views={3: deploy_job("failure"), 2: deploy_job("success")},
).install()
v = reconcile.deploy_verdict(A)
check(v["verified"] and v["terminal"], "an own successful deploy verifies", json.dumps(v))

print("==> a descendant that does not carry this commit is never consulted")
w = World(deploy_runs=[gh_run(9, SIDE)], views={9: deploy_job("failure")}).install()
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
          logs={77: None}).install()
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
# SIDE is on origin, on a branch of its own, and never reached main.
World(deploy_runs=[]).install()
code, out = wait_once(waitfor.deploy_state(SIDE))
check(code == 3 and out["outcome"] == "not-on-main",
      "not-on-main is its own outcome", json.dumps(out))
# The same world with a commit that IS on main. git answers both, so a stop
# on the first is git's answer and not the absence of a deploy run.
World(deploy_runs=[]).install()
state = waitfor.deploy_state(A)
check(not state.get("done") and not state.get("stop"),
      "a commit on main with no deploy run yet keeps waiting", json.dumps(state))

print("==> a budget that expires is still exit 1")
code, out = wait_once({"done": False})
check(code == 1 and out["satisfied"] is False and out["outcome"] == "budget-expired",
      "the timeout outcome is unchanged", json.dumps(out))

print("==> git failing to answer keeps the wait open rather than stopping it")
# The defect commit_on_main's docstring names: main moved to LATE, the fetch
# failed, and the stale `origin/main` says LATE is not on it. This checkout has
# LATE from origin's `late` branch, so is-ancestor answers 1, not 128. Only the
# fetch's own exit code tells that "no" apart from the truth.
git(AUTHOR, "push", "-q", "origin", f"{LATE}:refs/heads/main")
World(deploy_runs=[], origin_reachable=False).install()
state = waitfor.deploy_state(LATE)
check(not state.get("done") and not state.get("stop"),
      "an unanswerable git keeps waiting", json.dumps(state))
git(AUTHOR, "push", "-q", "--force", "origin", f"{B}:refs/heads/main")

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
# A is on main, so the not-on-main stop cannot be what keeps this from `done`.
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
    prs=[{"number": 5, "state": "OPEN", "isDraft": True, "isCrossRepository": False,
          "mergeStateStatus": "BEHIND", "statusCheckRollup": []}],
    diff=(1, ""),
).install()
pr = reconcile.pr_for(TICKET)
check(pr["risk"] == "unknown", "the diff is unknown", json.dumps(pr.get("risk")))
check(pr["needs_update"] is True and pr["is_draft"] is True,
      "needs_update and is_draft survive the unreadable path", json.dumps(pr))

print("==> a diff GitHub will not render is read from the files API, renames and all")
# `gh pr diff` fails for good on a diff past GitHub's size limit, and the card's
# risk stayed `unknown` on every tick. The files API pages instead, and it names
# where a renamed file came from: moving a migration out of its directory
# changes that directory.
open_pr = {"number": 5, "state": "OPEN", "isCrossRepository": False,
           "statusCheckRollup": []}
World(prs=[dict(open_pr)], diff=(1, ""),
      files=(0, '["README.md", ""]\n["archive/001.sql", "db/migrations/001.sql"]\n')).install()
pr = reconcile.pr_for(TICKET)
check(pr["risk"] == "high" and pr["risk_paths"] == [RISK_PATH],
      "a file renamed out of a risk path is high risk", json.dumps(pr.get("risk_paths")))
check(pr["files_changed"] == 2, "a rename is one changed file",
      json.dumps(pr.get("files_changed")))
World(prs=[dict(open_pr)], diff=(1, ""), files=(0, '["README.md", ""]\n')).install()
pr = reconcile.pr_for(TICKET)
check(pr["risk"] == "low", "the files API alone can clear a card", json.dumps(pr.get("risk")))
World(prs=[dict(open_pr)], diff=(1, ""), files=(1, "")).install()
pr = reconcile.pr_for(TICKET)
check(pr["risk"] == "unknown" and "pulls/5/files" in pr.get("risk_reason", ""),
      "both failing is unknown, and says which reads to try by hand",
      json.dumps(pr.get("risk_reason")))

print("==> a fork's pull request is never the card's, even on the card's exact branch name")
# `--head` matches a branch by NAME -- gh: '"<owner>:<branch>" syntax not
# supported' -- so a fork's pull request on the same name comes back from the
# same call as the board's own. Found on 2026-09-16 before making the
# repository public: `newest()` picked the fork's, because it was opened later,
# and the board would have reviewed and merged a stranger's diff onto the `main`
# every installation pulls. The fork's row is the NEWER number here on purpose:
# that is the ordering an attacker chooses, and the one `newest()` rewards.
World(prs=[
    {"number": 5, "state": "OPEN", "isCrossRepository": False, "statusCheckRollup": []},
    {"number": 9, "state": "OPEN", "isCrossRepository": True, "statusCheckRollup": []},
]).install()
pr = reconcile.pr_for(TICKET)
check(pr is not None and pr.get("number") == 5,
      "the board's own #5 is the card's, not the newer fork #9",
      json.dumps(pr and pr.get("number")))

World(prs=[
    {"number": 9, "state": "OPEN", "isCrossRepository": True, "statusCheckRollup": []},
]).install()
check(reconcile.pr_for(TICKET) is None,
      "a card whose only matching pull request is a fork's has no pull request")

# A row that does not say where it came from is dropped, not trusted: pr_for
# returns the pull request step 4 may merge autonomously.
World(prs=[
    {"number": 5, "state": "OPEN", "statusCheckRollup": []},
]).install()
check(reconcile.pr_for(TICKET) is None,
      "a row with no isCrossRepository is not assumed to be this repository's")

w = World(prs=[]).install()
reconcile.pr_for(TICKET)
asked = [c for c in w.calls if c[:3] == ["gh", "pr", "list"]]
fields = asked[0][asked[0].index("--json") + 1] if asked and "--json" in asked[0] else ""
check("isCrossRepository" in fields.split(","),
      "pr_for asks gh for isCrossRepository, so the filter has something to read", fields)

print("==> pr_for's --head branch carries this instance's namespace, not just the ticket")
# Reverting `return f"{BOARD_NAME_PREFIX}/{ticket}"` back to
# `f"board/{ticket}"` is the most consequential regression in this file: get it
# wrong and reconcile never finds the pull request for any card again. The
# fixture's home has no installation.toml, so its names are legacy and the
# branch is foreman/<board>/<ticket>: the branch an un-migrated machine's open
# pull requests sit on. The World scripts `gh pr list` on that branch alone, so
# any other one is an unscripted call. The check below reads the logged call
# as well, so the failure names the branch that was asked for.
w = World(prs=[], ticket="ACME-7").install()
reconcile.pr_for("ACME-7")
pr_list_calls = [c for c in w.calls if c[:3] == ["gh", "pr", "list"]]
check(len(pr_list_calls) == 1, "exactly one gh pr list call", str(pr_list_calls))
head = None
if pr_list_calls and "--head" in pr_list_calls[0]:
    head = pr_list_calls[0][pr_list_calls[0].index("--head") + 1]
check(head == f"foreman/{reconcile.INSTANCE}/ACME-7",
      "the --head value is the instance-scoped branch, not board/ACME-7", head)

print("==> reconcile()'s worktree field finds the instance-scoped worktree dispatch.sh actually creates")
# `worktree = os.path.join(REPO, ".claude", "worktrees",
#                          f"{BOARD_WORKTREE_PREFIX}-{ticket}")`
# has to match what `worktree_path()` in config.sh actually names, or every
# card's reported worktree reads as absent. Only a directory at the CORRECT
# name is created, so a reversion to the old `board-{ticket}` shape (or any
# other mismatch) reports `None` here instead of the real path.
World(prs=[], ticket="ACME-8").install()
wt_dir = os.path.join(
    reconcile.REPO, ".claude", "worktrees",
    f"foreman-{reconcile.INSTANCE}-ACME-8")
os.makedirs(wt_dir, exist_ok=True)
record = reconcile.reconcile("ACME-8", [])
check(record["worktree"] == wt_dir,
      "the worktree path reconcile() looks for is the one dispatch.sh creates",
      record["worktree"])


_settle_last()

if FAILURES:
    print("\nFAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
print("\nPASS")
