#!/usr/bin/env python3
"""Join everything the board tick needs to know about a set of cards.

    reconcile.py MUR-42 MUR-43 ...

Emits one JSON object per ticket on stdout. The tick reasons over this instead
of running twenty shell commands and eyeballing the output.

Linear is deliberately NOT read here — the tick already has the card's column
from MCP and joins it in. This script covers the three evidence sources that
answer "what actually happened": `claude agents`, git, and `gh`.

Nothing here is authoritative on its own. Every field is re-derived on each run
from the outside world, so deleting the sidecar loses history, never position.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

def _load_config() -> dict[str, str]:
    """Read settings from config.sh — the single source of truth.

    Duplicating these as Python defaults is how the merge policy silently fails:
    config.sh is a shell file the tick may never source into this process, so a
    second copy here would keep parking diffs the operator had already opted to
    merge. Sourcing it means there is exactly one place to change a setting.
    """
    keys = (
        "REPO", "BOARD_HOME", "REQUIRED_CHECKS", "HIGH_RISK_PATHS",
        "DEPLOY_WORKFLOW", "DEPLOY_STEP", "CI_WORKFLOW", "INSTANCE",
        "FOREMAN_HOME", "HOST_SLOT_STALE_MINUTES",
    )
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.sh")
    printf = 'printf "%s\\0" ' + " ".join(f'"${k}"' for k in keys)
    out = subprocess.run(
        # Only stdout is silenced. `2>&1` here sent config.sh's own error message
        # to /dev/null too, so a config that refused to load reported
        # "could not read <path>: " with nothing after the colon — the diagnostic
        # discarded by the line that exists to print it.
        ["bash", "-c", f". {script!r} >/dev/null; {printf}"],
        capture_output=True, text=True, timeout=15,
    )
    values = out.stdout.split("\0")
    if out.returncode != 0 or len(values) < len(keys):
        raise SystemExit(f"reconcile: could not read {script}: {out.stderr.strip()}")
    return dict(zip(keys, values))


_CFG = _load_config()
REPO = _CFG["REPO"]
INSTANCE = _CFG["INSTANCE"]
BOARD_HOME = _CFG["BOARD_HOME"]
REQUIRED_CHECKS = set(c for c in _CFG["REQUIRED_CHECKS"].split("|") if c)
HIGH_RISK_PATHS = _CFG["HIGH_RISK_PATHS"].split()
DEPLOY_WORKFLOW = _CFG["DEPLOY_WORKFLOW"]
DEPLOY_STEP = _CFG["DEPLOY_STEP"]
# The one value here with a fallback, and only because config.sh is deliberately
# NOT mirrored to the running board (design/shipping.md). A key added here reads
# as the empty string until that copy is edited by hand, and an empty workflow
# name makes every `main` CI lookup fail — which stands the whole board down on a
# missing string rather than on anything about `main`. config.sh still overrides.
CI_WORKFLOW = _CFG["CI_WORKFLOW"] or "CI"
FOREMAN_HOME = _CFG["FOREMAN_HOME"]
# Empty means "disabled" -- see host_slots()'s docstring for why that is a
# real, supported value and not just an unset-variable accident.
HOST_SLOT_STALE_MINUTES = (
    float(_CFG["HOST_SLOT_STALE_MINUTES"]) if _CFG["HOST_SLOT_STALE_MINUTES"] else None
)

# An unreachable GitHub must not stall the whole tick.
GH_TIMEOUT = 30


def run(args: list[str], cwd: str | None = None) -> tuple[int, str]:
    try:
        p = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=GH_TIMEOUT
        )
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 1, f"{exc}"


def run_json(args: list[str], cwd: str | None = None):
    code, out = run(args, cwd)
    if code != 0:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def transcript_path(cwd: str, session_id: str) -> str:
    """Claude persists a session at ~/.claude/projects/<slug>/<id>.jsonl.

    The slug is the cwd with every '/' and '.' replaced by '-'.
    """
    slug = re.sub(r"[/.]", "-", cwd)
    return os.path.expanduser(f"~/.claude/projects/{slug}/{session_id}.jsonl")


def load_agents() -> list[dict] | None:
    """Every registered agent, or None if the registry could not be read.

    `or []` folded a failed `claude agents` into "no agents are running" — the
    same defect fixed in supervise.sh, where answering it by starting an agent
    produces a second loop agent. Here it is quieter and worse: a card whose
    build agent exists reads as having none, and step 2 treats "no agent, no PR"
    as a tick that died before dispatching and re-dispatches on top of a live one.
    """
    agents = run_json(["claude", "agents", "--json", "--all"])
    if agents is None or not isinstance(agents, list):
        return None
    return [a for a in agents if isinstance(a, dict)]


# `state` is the real signal, and it is not the same as "is the process up".
# A background agent does NOT exit when its turn ends — it idles at `done`
# with its pid intact. Classifying on liveness alone reports finished work as
# still running, forever.
PHASE = {
    "working": "running",     # mid-turn
    "done": "turn-complete",  # turn finished; go look at the PR
    "blocked": "blocked",     # waiting on a prompt nobody will answer — intervene
    "stopped": "terminal",    # stopped, by us or otherwise
}


def agents_for(agents: list[dict], ticket: str) -> list[dict]:
    # The trailing slash is load-bearing: without it "PRA-1" is a PREFIX MATCH
    # for "PRA-10", "PRA-11", "PRA-100"... and one card would reap another's
    # agents.
    prefix = f"foreman/{INSTANCE}/{ticket}/"
    out = []
    for a in agents:
        name = a.get("name") or ""
        if not name.startswith(prefix):
            continue
        role_attempt = name[len(prefix) :]
        role, _, attempt = role_attempt.partition("-")
        session_id = a.get("sessionId") or ""
        cwd = a.get("cwd") or ""
        tpath = transcript_path(cwd, session_id) if session_id and cwd else ""
        idle_minutes = None
        if tpath and os.path.exists(tpath):
            idle_minutes = round((time.time() - os.path.getmtime(tpath)) / 60, 1)
        # A stopped agent keeps its row but loses its pid. That pair is the
        # difference between "still working" and "terminal".
        alive = bool(a.get("pid")) and a.get("state") != "stopped"
        out.append(
            {
                "name": name,
                "role": role,
                "attempt": attempt,
                "id": a.get("id"),
                "sessionId": session_id,
                "startedAt": a.get("startedAt") or 0,
                "cwd": cwd,
                "state": a.get("state"),
                "phase": PHASE.get(a.get("state") or "", "unknown"),
                "status": a.get("status"),
                "pid": a.get("pid"),
                "alive": alive,
                "transcript": tpath if tpath and os.path.exists(tpath) else None,
                "idle_minutes": idle_minutes,
            }
        )

    # `--bg --resume` forks: a new session id inherits the name. Several agents
    # therefore share one name legitimately, and only the newest is live.
    out.sort(key=lambda a: a["startedAt"])
    newest: dict[str, dict] = {}
    for a in out:
        a["current"] = False
        newest[a["name"]] = a
    for a in newest.values():
        a["current"] = True
    return out


def check_rollup(pr: dict) -> dict:
    """Required checks, by exact name, for this head SHA.

    An empty rollup reads as green everywhere else and means the build never
    queued — so it is reported as its own state, not folded into `passing`.
    """
    rollup = pr.get("statusCheckRollup") or []
    seen, pending = {}, []
    for c in rollup:
        name = c.get("name") or c.get("context") or ""
        if name not in REQUIRED_CHECKS:
            continue
        # A running job reports conclusion '' — it has not concluded anything.
        # Folding that into `failing` is how a tick resumes a build agent to fix
        # a job that was merely still running, burning an attempt and sending it
        # to chase a failure that does not exist. "Not yet" is its own answer.
        status = (c.get("status") or "").upper()
        verdict = (c.get("conclusion") or c.get("state") or "").upper()
        if status and status != "COMPLETED" or not verdict:
            pending.append(name)
            seen[name] = verdict or status or "PENDING"
            continue
        seen[name] = verdict
    concluded = {n: v for n, v in seen.items() if n not in pending}
    missing = sorted(REQUIRED_CHECKS - set(seen))
    failing = sorted(
        n for n, v in concluded.items() if v not in ("SUCCESS", "NEUTRAL", "SKIPPED")
    )
    return {
        "observed": seen,
        "missing": missing,
        "failing": failing,
        "pending": sorted(pending),
        "empty": not rollup,
        # Green means every required check has CONCLUDED well. Anything still
        # running means the answer is not in yet, which is not the same as green.
        "passing": not missing and not failing and not pending and bool(rollup),
    }


def pr_for(ticket: str) -> dict | None:
    branch = f"foreman/{INSTANCE}/{ticket}"
    prs = run_json(
        [
            "gh", "pr", "list", "--head", branch, "--state", "all",
            "--json", "number,state,headRefOid,mergeStateStatus,mergeCommit,"
                      "url,isDraft,title,statusCheckRollup",
        ],
        cwd=REPO,
    )
    # `prs is None` means the lookup FAILED; `prs == []` means there is no pull
    # request. Folding them together made step 2 read a transient GitHub error as
    # "the attempt failed", which resumes a build agent and charges the ticket an
    # attempt it did not earn — the same budget that exists to retire a bad
    # ticket, spent on a network blip.
    if prs is None:
        return {"lookup_failed": True,
                "reason": "gh pr list failed; whether a pull request exists is unknown"}
    if not prs:
        return None
    # `--state all` is needed so step 5 can still see a MERGED pull request while
    # verifying its deploy. But taking the highest number regardless of state
    # meant a CLOSED pull request was reported as the card's — and a closed one
    # keeps its green checks, so step 2 would read "PR open and passing" and move
    # the card to `In Review` on a branch nobody is working. Observed on PRA-30
    # the moment its superseded #143 was closed.
    #
    # An OPEN pull request is always the live one. Fall back to the newest of
    # whatever else exists, which is what the merged-and-deployed path wants.
    def newest(rows: list[dict]) -> dict:
        return sorted(rows, key=lambda p: p.get("number", 0))[-1]

    # A card whose only pull requests are CLOSED has no pull request. Reporting
    # one anyway leaves every caller responsible for remembering to check
    # `state`, and the cost of forgetting is moving a card to `In Review` on a
    # branch nobody is working. Only OPEN and MERGED are the card's.
    open_prs = [p for p in prs if p.get("state") == "OPEN"]
    merged = [p for p in prs if p.get("state") == "MERGED"]
    if not open_prs and not merged:
        return None
    pr = newest(open_prs) if open_prs else newest(merged)
    pr["checks"] = check_rollup(pr)
    pr["branch"] = branch

    # A diff that could not be read is NOT a diff that touches nothing.
    #
    # This folded a failed `gh pr diff` into an empty file list, and an empty
    # file list has no high-risk paths, so `risk` came out `low` — which step 4
    # merges autonomously. One transient GitHub error was therefore enough to
    # merge a MIGRATION without the operator, and a migration applied to the
    # deploy host's live database is not undone by reverting the pull request.
    # That is the one place in this file where guessing costs something
    # irreversible.
    #
    # `risk: unknown` is deliberately neither value: step 4 merges only `low`
    # and parks only `high`, so an unknown risk stops the card until the diff
    # can actually be read.
    code, out = run(
        ["gh", "pr", "diff", str(pr["number"]), "--name-only"], cwd=REPO
    )
    if code != 0:
        pr["files_changed"] = None
        pr["risk"] = "unknown"
        pr["risk_paths"] = []
        pr["risk_reason"] = "gh pr diff failed; the diff was never read"
    else:
        files = [f for f in out.splitlines() if f.strip()]
        touched = sorted({p for f in files for p in HIGH_RISK_PATHS if f.startswith(p)})
        pr["files_changed"] = len(files)
        pr["risk"] = "high" if touched else "low"
        pr["risk_paths"] = touched

    # Everything below is about the pull request, not about its diff, so it holds
    # whether or not the diff could be read. The unreadable-diff path used to
    # return early with its own copy of these two lines, which meant the next
    # field added here would simply be missing on that path — and missing reads
    # as false for both of them, which is the direction that merges.
    #
    # A branch that cannot see main's tip will not merge under `strict: true`,
    # no matter how green it looks.
    pr["needs_update"] = pr.get("mergeStateStatus") == "BEHIND"
    # A draft cannot be merged either. `gh pr merge` fails with "Pull Request is
    # still a draft" — which the board used to discover at the merge call, having
    # already run two adversarial reviewers and declared the card ready to ship.
    # Surfaced here so step 4 sees it while reconciling, alongside needs_update.
    pr["is_draft"] = bool(pr.get("isDraft"))
    return pr


def commit_on_main(sha: str) -> bool | None:
    """Is this commit on `origin/main`? None when git could not answer.

    The fetch's exit code used to be ignored, so a fetch that timed out or hit a
    momentary auth failure left `origin/main` stale and `is-ancestor` reported
    False for a commit that IS on main. That was survivable while this was only
    reported; waitfor.deploy_state now STOPS on a False, so folding a git failure
    into one ends the wait with "no deploy will carry it" for a merge whose
    deploy is still in flight. Same None-vs-empty distinction as load_agents().
    """
    if not sha:
        return False
    code, _ = run(["git", "fetch", "--quiet", "origin", "main"], cwd=REPO)
    if code != 0:
        return None
    # is-ancestor exits 1 for "no" and something else entirely (128) for a sha
    # this checkout has never heard of. Only 0 and 1 are answers.
    code, _ = run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], cwd=REPO)
    if code not in (0, 1):
        return None
    return code == 0


def _explains_better(candidate: dict, current: dict | None) -> bool:
    """Does `candidate` beat `current` as the reason this commit is not deployed?

    List order alone is not enough. `gh run list` is newest-first and the first
    carrying run that did not deploy is usually the best word on the subject —
    but two merges two minutes apart can still have their CI runs COMPLETE out
    of order -- `ci.yml` groups pull-request runs only and gives every push a
    group of its own, and one self-hosted runner serves them all, so they queue
    rather than finish in order -- and the deploy workflow is `workflow_run`-triggered.
    That puts an older run that ran the deploy and BROKE it behind a newer one
    that merely stood down, and first-writer-wins
    then discards the failure and waits the full budget every tick forever —
    which is the exact defect this was written to remove, surviving by ordering.

    So rank the answers instead: a deploy that broke beats any other terminal
    answer, any terminal answer beats one that keeps waiting, and ties go to the
    newer run. Preferring a terminal answer can end a wait a tick early when a
    newer stand-down really did have a deploy still coming; that costs a card one
    tick, because nothing is ever marked `Done` on a terminal-but-unverified
    answer and the next tick re-derives all of it. Missing a broken production
    deploy costs the opposite.
    """
    rank = (lambda v: 2 if v.get("outcome") == "deploy-failed"
            else 1 if v.get("terminal") else 0)
    return current is None or rank(candidate) > rank(current)


def _not_deployed(r: dict, head: str, sha: str, state: str, concl: str | None) -> dict:
    """Why one run that carries `sha` did not deploy it, and whether that is final.

    Final means: this answer cannot improve by waiting. Two shapes are final and
    they are different things.

      * `failure` — the deploy script ran on the deploy host and broke. Production
        is in whatever state it left behind, and the tick must say so now.
      * no DEPLOY_STEP at all — the deploy job was skipped in its entirety, which
        is what a red CI run on `main` produces (the deploy workflow gates the job
        on the CI run concluding success). That run will never deploy anything.

    Everything else keeps the wait alive: a `skipped` STEP is the stale-revision
    stand-down with a descendant's deploy still coming, and an unreadable run
    taught us nothing at all.
    """
    where = "" if head == sha else f" of descendant {head[:12]}"
    if state == "unreadable":
        return {
            "verified": False, "terminal": False,
            "reason": f"could not read deploy run {r['databaseId']}{where}",
            "url": r.get("url"),
        }
    if state == "absent":
        return {
            "verified": False, "terminal": True, "outcome": "deploy-never-ran",
            "reason": f"deploy run {r['databaseId']}{where} completed with no "
                      f"{DEPLOY_STEP} step; the deploy job never ran",
            "url": r.get("url"),
        }
    verdict = {
        "verified": False,
        "terminal": concl == "failure",
        "step_conclusion": concl,
        "reason": f"deploy run {r['databaseId']}{where} did not deploy "
                  f"({DEPLOY_STEP} concluded {concl})",
        "url": r.get("url"),
    }
    if concl == "failure":
        verdict["outcome"] = "deploy-failed"
    return verdict


def deploy_verdict(sha: str) -> dict:
    """Deployment is the DEPLOY_STEP concluding success, never the job.

    A stale-revision stand-down concludes `success` at the job level, which is
    why reading the job would call a non-deploy a deploy.

    Every return carries `terminal`: True when no amount of further waiting can
    change this answer. `verified` says whether the commit is live; `terminal`
    says whether the question is settled. The pair is what lets waitfor.py stop
    on a deploy that ran and BROKE — which is neither satisfied nor still coming
    — instead of polling it for the whole budget on every tick, forever.
    """
    if not sha:
        return {"verified": False, "terminal": True, "outcome": "no-merge-commit",
                "reason": "no merge commit"}
    runs = run_json(
        ["gh", "run", "list", "--workflow", DEPLOY_WORKFLOW, "--limit", "20",
         "--json", "databaseId,headSha,conclusion,status,url"],
        cwd=REPO,
    )
    # `or []` folded a FAILED lookup into "there are no runs", which this
    # function then reported as "no deploy run for <sha> yet". Safe direction —
    # nothing reaches `Done` on it — but the wrong cause named, so a rate-limited
    # or offline `gh` reads as a deploy that has not started, and the tick reports
    # a machine problem as a slow deploy.
    if runs is None:
        return {"verified": False, "terminal": False,
                "reason": f"could not list {DEPLOY_WORKFLOW} runs; gh failed"}

    def step_conclusion(run: dict) -> tuple[str, str | None]:
        """`(state, conclusion)` for one run's DEPLOY_STEP.

        A bare `None` meant two opposite things and the caller could not tell
        them apart: `gh run view` failed, so nothing was learned; or the run
        completed with no DEPLOY_STEP at all, which is the deploy job being
        skipped outright because CI went red on the squash. The first must never
        stop a wait, and the second always should — that run will never deploy
        anything, however long anyone waits on it.

        - `("ok", <conclusion>)`  — the step exists and concluded (or is "" when
          it has not concluded yet).
        - `("absent", None)`      — the run completed without the step existing.
        - `("unreadable", None)`  — `gh run view` failed; we learned nothing.
        """
        detail = run_json(
            ["gh", "run", "view", str(run["databaseId"]), "--json", "jobs"], cwd=REPO
        )
        if detail is None:
            return ("unreadable", None)
        for job in detail.get("jobs", []):
            for step in job.get("steps", []):
                if step.get("name") == DEPLOY_STEP:
                    return ("ok", step.get("conclusion"))
        return ("absent", None)

    # WHICH REVISION DID A RUN ACTUALLY DEPLOY?
    #
    # Not `headSha`. For a `workflow_run`-triggered workflow GitHub sets that to
    # the branch tip at dispatch, while the deploy workflow checks out DEPLOY_REVISION =
    # `github.event.workflow_run.head_sha`. Measured 2026-08-03: run 30764121331
    # reported headSha acd6917a and deployed dc17565 — unrelated commits. Reading
    # headSha as the deployed revision can therefore mark a card `Done` with code
    # that is not running, which is the one failure `Done` exists to prevent.
    #
    # But the two agree in exactly the case that matters. The deploy step is
    # gated on `steps.freshness.outputs.deploy == 'true'`, so it runs ONLY while
    # the checked-out revision is still main's tip — and main's tip is what
    # headSha reports. Across every recorded run, head and deployed ref were
    # identical whenever the step SUCCEEDED, and differed only on a stand-down.
    #
    # So: learn nothing from a run whose step did not succeed. A stand-down is
    # exactly where headSha lies, and refusing to read it there removes the
    # dangerous direction entirely. This costs nothing, because a stand-down
    # never proved a deployment anyway.
    run(["git", "fetch", "--quiet", "origin"], cwd=REPO)
    # The best explanation so far for why this commit is not deployed, ranked by
    # `_explains_better` rather than taken from list order — see there for why
    # newest-first is not sufficient.
    #
    # This used to be recorded only for the commit's OWN run, which is the one
    # case where nothing useful is ever recorded: a merge overtaken minutes later
    # always stands down as `skipped`, and the run that actually deployed — or
    # actually broke — is a DESCENDANT's. So when A merged, B merged two minutes
    # later and B's deploy failed, A saw `skipped`, was on `main`, and waited the
    # full budget every tick forever while production was broken.
    unverified = None
    for r in runs:
        head = r.get("headSha") or ""
        if not head:
            continue
        if r.get("status") != "completed":
            if head == sha:
                running = {
                    "verified": False, "terminal": False,
                    "reason": f"deploy run {r['databaseId']} still {r.get('status')}",
                }
                if _explains_better(running, unverified):
                    unverified = running
            continue
        # Ancestry first, steps second. `step_conclusion` is a `gh run view`
        # round trip per run; this is a local merge-base. Asking the network
        # about runs that could not carry this commit whatever they concluded
        # turned a 1-2 call verdict into 20 — and waitfor polls this every 10s
        # for the whole deploy budget, so it multiplied into thousands. Both
        # orders return the same verdict, because a run that fails this test
        # contributes nothing either way.
        if head != sha:
            code, _ = run(["git", "merge-base", "--is-ancestor", sha, head], cwd=REPO)
            if code != 0:
                continue
        state, concl = step_conclusion(r)
        if state != "ok" or concl != "success":
            # Records why this run did not verify, without letting it contribute
            # an attribution. Which non-success it was decides everything:
            # `skipped` is a stand-down with a descendant still coming, `failure`
            # is the deploy script breaking on the deploy host, and no step at all
            # is the deploy job never having run. deploy_state needs to tell them apart.
            candidate = _not_deployed(r, head, sha, state, concl)
            if _explains_better(candidate, unverified):
                unverified = candidate
            continue
        # This run demonstrably deployed `head`. The commit is live if it IS that
        # revision, or is an ancestor of it — a merge superseded minutes later is
        # carried into production by the deploy of its descendant.
        if head == sha:
            return {"verified": True, "terminal": True,
                    "reason": f"{DEPLOY_STEP} concluded success",
                    "url": r.get("url")}
        return {
            "verified": True,
            "terminal": True,
            "reason": f"carried in by the deploy of descendant {head[:12]} "
                      f"({DEPLOY_STEP} concluded success)",
            "url": r.get("url"),
        }

    if unverified:
        return unverified
    return {"verified": False, "terminal": False,
            "reason": f"no {DEPLOY_WORKFLOW} run for {sha[:12]} yet"}


# A CI run on `main` that concluded one of these was never actually a test of
# `main`. A runner dropped, someone hit cancel, GitHub cancelled it during an
# incident, the job never started, or GitHub killed it on its own time limit —
# none of which is evidence that any commit is broken. Folding them into "`main`
# is red" halts merging and dispatching AND names an innocent commit as the
# breakage, which is how tickets collect `board-failed` for somebody else's
# infrastructure. An empty conclusion on a COMPLETED run belongs here for the
# same reason: it is an answer nobody can read, not an accusation.
CI_UNTESTED = {"cancelled", "startup_failure", "stale", "skipped",
               "action_required", "timed_out"}
# `neutral` is GitHub's "concluded, nothing wrong" — check_rollup already treats
# it as passing for a required check, and this is the same claim about a run.
CI_GREEN = {"success", "neutral"}


def run_attempt(run_id) -> int | None:
    """GitHub's own re-run counter for a run, or None if it could not be read.

    Not available from `gh run list --json` at any version this has run against,
    so it is a second round trip and is only ever asked when it decides
    something.
    """
    attempt = run_json(
        ["gh", "api", f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}",
         "--jq", ".run_attempt"],
        cwd=REPO,
    )
    return attempt if isinstance(attempt, int) else None


def main_ci_state(branch: str = "main") -> dict:
    """What the newest CI run on `branch` actually says, as a named verdict.

    Seven answers, because branching on a formatted `gh` line in prose gave four
    and two of them were wrong. `verdict` is one of:

      green      — proceed.
      running    — a FIRST attempt is in flight. Not merging, not a breakage.
      rerunning  — a re-run is in flight. See below; this one is not `running`.
      untested   — concluded without testing anything (see CI_UNTESTED).
      red        — concluded badly. A commit really did break `main`.
      none       — `gh` answered, and there has never been a CI run on `branch`.
      unknown    — the lookup FAILED, so whether `branch` is safe is not known.

    `none` and `unknown` are split because `gh` prints an empty list for both,
    and an empty answer reads as green everywhere it is not given its own name —
    the same distinction `pr.lookup_failed` and `check_rollup`'s `empty` make.

    `rerunnable` answers the other half: a `main` the board stood down on cannot
    recover on its own, because standing down stops the merges and dispatches
    that are the only things that would ever push `main` again and produce a new
    CI run. Re-running the existing run is a new verdict with nobody pushing
    anything, and `run_attempt` bounds it to one re-run per run without the board
    having to remember anything — the count lives in GitHub.

    WHY `rerunning` IS NOT `running`. That recovery defeated the stand-down it
    recovers from. `running` licenses dispatch, and its whole justification is
    "the branch point is a commit that already passed" — true when `main` was
    green and somebody pushed. A re-run makes GitHub reset the SAME run to
    `in_progress` with a null conclusion, so the tick after a board-initiated
    re-run of a RED `main` read `running` and resumed dispatching onto a `main`
    it had judged broken minutes earlier, for the whole re-run window. The
    attempt count is the only thing in the payload that separates the two, so it
    is read on this path too, and an in-flight attempt past the first stands the
    board down exactly like the verdict that caused it.

    An attempt that cannot be read is `unknown` rather than `running`: an
    unreadable counter cannot rule out that this is a recovery, and the invariant
    is that the board never dispatches into a `main` whose last CONCLUDED verdict
    was red. Standing down for one tick on a failed API call is the cheap side of
    that trade.
    """
    runs = run_json(
        ["gh", "run", "list", "--workflow", CI_WORKFLOW, "--branch", branch,
         "--limit", "1", "--json", "databaseId,headSha,status,conclusion,url"],
        cwd=REPO,
    )
    if runs is None:
        return {"verdict": "unknown", "branch": branch, "rerunnable": False,
                "reason": f"gh run list for {CI_WORKFLOW} on {branch} failed; "
                          f"nothing is known about {branch}"}
    if not runs:
        return {"verdict": "none", "branch": branch, "rerunnable": False,
                "reason": f"gh reports no {CI_WORKFLOW} run on {branch} at all"}

    r = runs[0]
    status = (r.get("status") or "").lower()
    concl = (r.get("conclusion") or "").lower()
    state = {
        "branch": branch,
        "run_id": r.get("databaseId"),
        "headSha": r.get("headSha"),
        "status": status,
        "conclusion": concl,
        "url": r.get("url"),
        "rerunnable": False,
    }
    if status != "completed":
        # Read status before conclusion: a run still going reports `conclusion:
        # ""`, and reading the conclusion alone calls a healthy `main` red.
        # But WHICH attempt is in flight decides whether this licenses dispatch,
        # so the counter is read here as well as below.
        state["attempt"] = run_attempt(r.get("databaseId"))
        if state["attempt"] == 1:
            state["verdict"] = "running"
            state["reason"] = f"{CI_WORKFLOW} on {branch} is {status or 'not completed'}"
        elif state["attempt"] is None:
            state["verdict"] = "unknown"
            state["reason"] = (
                f"{CI_WORKFLOW} on {branch} is {status or 'not completed'}, and its "
                f"attempt count could not be read; whether this is a first run or a "
                f"re-run of a {branch} that already concluded badly is not known"
            )
        else:
            state["verdict"] = "rerunning"
            state["reason"] = (
                f"{CI_WORKFLOW} on {branch} is {status or 'not completed'} on attempt "
                f"{state['attempt']}; a re-run is in flight, so the last thing "
                f"{branch} actually concluded was not success"
            )
        return state
    if concl in CI_GREEN:
        state["verdict"] = "green"
        state["reason"] = f"{CI_WORKFLOW} on {branch} concluded {concl}"
        return state

    state["verdict"] = "untested" if (not concl or concl in CI_UNTESTED) else "red"
    state["reason"] = (
        f"{CI_WORKFLOW} on {branch} concluded {concl or 'nothing'}; "
        + ("it never tested the commit"
           if state["verdict"] == "untested" else
           f"{(r.get('headSha') or '')[:12]} broke it")
    )
    # Only asked when it decides something. A green `main` needs no re-run, and
    # this is a second network round trip on every tick.
    state["attempt"] = run_attempt(r.get("databaseId"))
    # Unknown attempt means do NOT re-run: an unbounded re-run every tick is a
    # worse failure than a board that waits for a human.
    state["rerunnable"] = state["attempt"] == 1
    state["rerun"] = f"gh run rerun {r.get('databaseId')}"
    return state


def _read_jsonl(path: str) -> list[dict]:
    """Every well-formed line of a `history.jsonl`-shaped file, or `[]`.

    Shared by `history()` (this instance's own cards) and `host_slots()`
    (every instance's). An unreadable file (missing, a directory, permission
    denied — `cards/<T>/` is a `mkdir -p`, not a guarantee `history.jsonl`
    exists inside it) and a corrupt line are both silently absorbed: this is
    a cache derived from `config.sh:card_log`, so a read that finds nothing
    means there is nothing to report, not a system failure to raise on.
    """
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return out


def history(ticket: str) -> list[dict]:
    """The card's append-only transition log, as written by config.sh:card_log.

    This used to read a `state.json` that nothing in the skill has ever written,
    so it returned null on every card and the tick fell back to guessing attempt
    numbers from agent names. history.jsonl is the file that actually exists.

    Still not authoritative: it is the record of what this skill DID, which is
    why position is always re-derived from Linear, git and gh. It answers the one
    question those cannot — how many times we have already tried.
    """
    return _read_jsonl(os.path.join(BOARD_HOME, "cards", ticket, "history.jsonl"))


def _entry_age_minutes(entry: dict) -> float | None:
    """Minutes since `entry["at"]`, or None if it is missing or unparseable.

    `at` is stamped by `config.sh:card_log` as `date -u +%Y-%m-%dT%H:%M:%SZ`
    -- always this one format, always UTC. `None` on anything else (a hand-
    edited line, a future format change) rather than raising, and the caller
    treats `None` as "cannot judge staleness" and falls back to NOT stale --
    the safe direction, because the failure mode this guards against is a
    slot that never gets released, not one released a little early.
    """
    at = entry.get("at")
    if not isinstance(at, str):
        return None
    try:
        stamp = datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - stamp).total_seconds() / 60


def card_holds_slot(history_path: str, stale_minutes: float | None) -> bool:
    """Does this card's own record say it is still occupying a build slot?

    `--host-slots` cannot ask Linear or `claude agents` for every instance on
    the machine the way a single tick asks about its own cards — that would be
    a network or registry round trip per instance, on every dispatch, for a
    ceiling that exists specifically to be cheap enough to check before every
    one. `history.jsonl` is therefore the only signal, read two ways:

    1. THE MARKER. `config.sh:card_log` appends `{"action":"released", ...}`
       as the last event for a card that has left the board and no longer
       occupies a slot — `Done`, `board-failed` from either exhausted
       attempts or exhausted review rounds — the same way it already appends
       `{"action":"void", ...}` for an attempt that didn't count. Named
       `released` and not `finished`: the meaning is "this card no longer
       holds a slot", which is true of a `board-failed` card too, and a name
       that reads as "succeeded" is the name most likely to be typo'd into
       only the happy path. Append-only means the LAST line is the most
       recent word on the card's own status.

    2. THE BACKSTOP. SKILL.md documents the sidecar as "a cache, never truth
       — delete it and the next tick must still reconstruct every card's
       position." A slot releasable ONLY by an LLM remembering to append one
       specific line violates that -- the marker is written by hand-followed
       prose, not enforced by any type checker, and a THIRD terminal exit
       someone adds later and forgets to wire produces the exact permanent
       deadlock this function exists to prevent: every instance on the
       machine wedged behind `HOST_MAX_CONCURRENT` by cards nobody is
       working on, unrecoverable without hand-editing `history.jsonl`. So a
       card whose last entry is older than `stale_minutes` also stops
       counting, regardless of what it says: no activity for that long means
       nothing is actually using the slot, marker or not. `stale_minutes` of
       `None` disables this (see `HOST_SLOT_STALE_MINUTES=` in config.sh).

    A card with no history at all — a `cards/<T>/` directory that exists for
    some other reason, or was created but never logged to — holds no slot:
    nothing was ever dispatched for it. That is the same "absence is not an
    error, but it is also not evidence of anything in flight" reading
    `_read_jsonl` already gives an unreadable file.
    """
    entries = _read_jsonl(history_path)
    if not entries:
        return False
    last = entries[-1]
    event = last.get("event") or {}
    if event.get("action") == "released":
        return False
    if stale_minutes is not None:
        age = _entry_age_minutes(last)
        if age is not None and age >= stale_minutes:
            return False
    return True


def host_slots(foreman_home: str, stale_minutes: float | None = HOST_SLOT_STALE_MINUTES) -> dict:
    """Cards holding a slot, counted across every instance on this machine.

    `{"instances": {name: count, ...}, "total": N}`. This is the host-wide
    ceiling's input: `HOST_MAX_CONCURRENT` bounds the total across every
    instance sharing this machine's RAM and disk, the same way a single
    instance's `MAX_CONCURRENT` bounds its own cards — see config.sh.

    Reads only the local sidecar under `<foreman_home>/instances/*/cards/`.
    No Linear, no `gh`, no `claude agents`: this has to be cheap enough to
    check before every dispatch, for every instance, and none of those three
    are namespaced by instance in a way that would make asking them once
    cover the whole machine cheaply.

    Tolerant by design, per its one caller (a tick deciding whether IT may
    dispatch): an instance directory with no `cards/` at all, a `cards/` with
    no entries, a card with no `history.jsonl`, or a `history.jsonl` holding
    unparseable lines must never raise. This is advisory input to a ceiling,
    not a fact the tick depends on being able to fetch — failing to read one
    instance's slots must not take down the tick that asked about all of them.
    """
    instances_dir = os.path.join(foreman_home, "instances")
    result: dict = {"instances": {}, "total": 0}
    try:
        names = sorted(os.listdir(instances_dir))
    except OSError:
        return result
    for name in names:
        cards_dir = os.path.join(instances_dir, name, "cards")
        try:
            tickets = sorted(os.listdir(cards_dir))
        except OSError:
            # No cards/ at all -- a freshly-created instance that has never
            # dispatched anything. Present in the report at 0, not absent:
            # an absent key would be indistinguishable from a listing failure
            # for `instances_dir` itself.
            result["instances"][name] = 0
            continue
        count = 0
        for ticket in tickets:
            history_path = os.path.join(cards_dir, ticket, "history.jsonl")
            if card_holds_slot(history_path, stale_minutes):
                count += 1
        result["instances"][name] = count
        result["total"] += count
    return result


def build_attempts(entries: list[dict]) -> int:
    """How many build attempts this card has actually consumed.

    Counts distinct attempt labels rather than spawn lines: a spawn and a later
    resume of the same attempt are one attempt, and re-dispatching the same
    attempt number after an environment repair must not count twice.

    A `void` entry removes an attempt from the count. The attempt budget exists
    to stop a card looping on a ticket that cannot be built; an attempt killed by
    a full disk is evidence about the machine and none at all about the ticket,
    so spending the budget on it retires work that was never tried. Voiding is
    for environment faults only — a build that genuinely failed keeps its cost.
    """
    seen, voided = set(), set()
    for e in entries:
        ev = e.get("event") or {}
        if ev.get("role") != "build":
            continue
        if ev.get("action") == "spawn":
            seen.add(str(ev.get("attempt")))
        elif ev.get("action") == "void":
            voided.add(str(ev.get("attempt")))
    return len(seen - voided)


def death_report(path: str | None) -> dict | None:
    """Why did this agent's transcript stop? Read the tail and say.

    `phase` reports that an agent is terminal; it cannot distinguish an agent
    that finished cleanly from one that was killed mid-command. That difference
    decides whether the failure belongs to the ticket or to the machine, and
    getting it wrong spends a build attempt on an environment fault — which is
    exactly what happened to PRA-28 twice on 2026-08-02.

    The signal is a trailing tool_use with no matching tool_result: the agent
    asked for a command and no answer was ever recorded, so it did not stop of
    its own accord.
    """
    if not path or not os.path.exists(path):
        return None
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return None
    if not rows:
        return None

    pending: dict[str, str] = {}   # tool_use_id -> short description
    last_text = ""
    for r in rows:
        msg = r.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            last_text = content
            continue
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            kind = b.get("type")
            if kind == "tool_use":
                desc = (b.get("input") or {}).get("command") or json.dumps(b.get("input"))[:200]
                pending[b.get("id") or ""] = f"{b.get('name')}: {' '.join(str(desc).split())[:200]}"
            elif kind == "tool_result":
                pending.pop(b.get("tool_use_id") or "", None)
            elif kind == "text":
                last_text = b.get("text") or last_text

    unanswered = list(pending.values())
    return {
        "killed_mid_tool": bool(unanswered),
        "unanswered_tool": unanswered[-1] if unanswered else None,
        "last_text": " ".join(last_text.split())[-400:] if last_text else None,
        "rows": len(rows),
    }


def reconcile(ticket: str, agents: list[dict]) -> dict:
    pr = pr_for(ticket)
    worktree = os.path.join(REPO, ".claude", "worktrees", f"foreman-{INSTANCE}-{ticket}")
    entries = history(ticket)
    mine = agents_for(agents, ticket)
    # Diagnose only the agents that have stopped. A running agent's transcript
    # always has an outstanding tool call — it is mid-turn — so asking this of
    # one would report every healthy build as killed.
    for a in mine:
        a["death"] = death_report(a["transcript"]) if a["phase"] == "terminal" else None
    record = {
        "ticket": ticket,
        "history": entries,
        "build_attempts": build_attempts(entries),
        "agents": mine,
        "worktree": worktree if os.path.isdir(worktree) else None,
        "pr": pr,
        "merged": bool(pr and pr.get("state") == "MERGED"),
        "deploy": {"verified": False, "reason": "not merged"},
    }
    if record["merged"]:
        sha = (pr.get("mergeCommit") or {}).get("oid") or ""
        record["merge_commit"] = sha
        record["commit_on_main"] = commit_on_main(sha)
        record["deploy"] = deploy_verdict(sha)
    return record


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: reconcile.py <TICKET> [TICKET...]\n"
              "       reconcile.py --main-ci [BRANCH]\n"
              "       reconcile.py --host-slots", file=sys.stderr)
        return 2
    if argv[0] == "--main-ci":
        # No agent registry, no Linear, no cards: this answers one question about
        # one branch, and step 0 asks it before any of that exists.
        json.dump(main_ci_state(argv[1] if len(argv) > 1 else "main"),
                  sys.stdout, indent=2)
        print()
        return 0
    if argv[0] == "--host-slots":
        # Same reasoning as --main-ci: this answers one question about the
        # whole machine, over local files only, and must not require the
        # agent registry (which is per-process, not per-instance) to answer it.
        json.dump(host_slots(FOREMAN_HOME), sys.stdout, indent=2)
        print()
        return 0
    agents = load_agents()
    if agents is None:
        # Refuse rather than report every card as having no agents. A tick that
        # believed that would re-dispatch on top of live builds.
        print("reconcile: could not read the agent registry; refusing to report "
              "cards as agentless", file=sys.stderr)
        return 3
    json.dump([reconcile(t, agents) for t in argv], sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
