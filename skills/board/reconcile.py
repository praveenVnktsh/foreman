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
# No fallback here, deliberately -- `checks.ci_workflow` is REQUIRED and
# non-empty in bin/contract.py (SCALARS' default of None, refused if blank),
# so an empty CI_WORKFLOW reaching this process means an environment override
# bypassed that requirement (config.sh reads a contract-emitted key with `-`,
# not `:-`, so `CI_WORKFLOW=` set in the environment overrides even a
# board.toml that named a real workflow). This used to substitute the literal
# "CI" for that case, justified by a design doc that described a DIFFERENT
# codebase's decision not to mirror config.sh's values into the running board
# -- a doc that does not exist in this repository, for a distinction that
# does not apply here. Silently checking a workflow board.toml never named
# ("CI") is exactly the failure contract.py's own validation exists to
# prevent: refuse instead, the same way a required scalar refuses everywhere
# else in this codebase.
if not _CFG["CI_WORKFLOW"]:
    raise SystemExit(
        "reconcile: CI_WORKFLOW is empty -- checks.ci_workflow is required in "
        "board.toml and bin/contract.py refuses it blank, so this can only mean "
        "an environment override (CI_WORKFLOW=) blanked it out after the fact"
    )
CI_WORKFLOW = _CFG["CI_WORKFLOW"]
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
    """The command's JSON, or None because the lookup FAILED.

    None is a third answer, and every caller owes it one. "GitHub did not
    answer" is not "GitHub answered nothing", and folding the two is this
    file's characteristic defect: it always fails in the direction of acting,
    because an empty answer is the quiet one every branch below already
    handles. It has cost real damage three times -- a failed `gh pr list` read
    as "no pull request" charged a card a build attempt it never earned, an
    unreadable diff read as "no files" merged a migration with no operator,
    and an unreadable agent registry read as "no agents" started a second
    board. Each of those sites carries its own note; this is the rule they are
    all instances of.

    So a caller that cannot act on an unknown must report it as one --
    `pr_for`'s `lookup_failed`, `risk: unknown`, `load_agents`'s None -- and
    never spend a budget or move a card on evidence nobody gathered.
    """
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


def branch_for(ticket: str) -> str:
    """The branch dispatch.sh cuts for a card.

    One function because the format is one fact. `pr_for` looks the card's pull
    request up by this branch, so a copy of the format string that drifts from
    what dispatch.sh actually cuts finds nothing — and a miss reads as an
    absence: the card has no pull request, on evidence about the wrong branch.
    """
    return f"foreman/{INSTANCE}/{ticket}"


def pr_for(ticket: str) -> dict | None:
    branch = branch_for(ticket)
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
    # the card to `In Review` on a branch nobody is working. Observed on one
    # card the moment its superseded #143 was closed.
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

    A target that declares no `[deploy]` at all (DEPLOY_WORKFLOW == "") has
    nowhere for a commit to deploy TO — board.toml's own comment and the design
    spec both say "merged is done" for exactly this case. Checked before
    anything else, and before the sha guard below: this is a fact about the
    contract, not about this merge, so it answers even a call made with no sha.
    Without this, `gh run list --workflow ""` ran unconditionally against every
    target with no [deploy] -- including foreman's own board.toml -- and no
    card on such a target could ever reach `Done`.
    """
    if not DEPLOY_WORKFLOW:
        return {"verified": True, "terminal": True, "outcome": "no-deploy-configured",
                "reason": "no [deploy] configured for this target; merged is done"}
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

    "Well-formed" means a JSON OBJECT, not merely valid JSON. A line reading
    `[]`, `123` or `"x"` parses and is not a `dict`, and every caller here
    reaches straight for `.get`, so letting one through raises AttributeError
    deep inside a walk over every card of every board on the machine — one
    hand-edited line on one card takes down an answer about all of them. This
    is the parse boundary, so the type this returns stops being a claim and
    starts being true.
    """
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(entry, dict):
                    out.append(entry)
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


CARD_LOG_STAMP = "%Y-%m-%dT%H:%M:%SZ"


def _entry_stamp(entry: dict) -> datetime | None:
    """`entry["at"]` as an aware datetime, or None if it is missing or unparseable.

    `at` is stamped by `config.sh:card_log` as `date -u +%Y-%m-%dT%H:%M:%SZ`
    -- always this one format, always UTC. Two readers need it: staleness in
    `_entry_age_minutes()` and fairness in `board_last_served()`. One format,
    one parser, per the styleguide's "one fact, one place" -- a second copy of
    a timestamp format is a copy that drifts, and the drift shows up as a
    board that silently never sorts first.
    """
    at = entry.get("at")
    if not isinstance(at, str):
        return None
    return _parse_stamp(at)


def _parse_stamp(text: str) -> datetime | None:
    """One `%Y-%m-%dT%H:%M:%SZ` timestamp as an aware datetime, or None."""
    try:
        return datetime.strptime(text, CARD_LOG_STAMP).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _entry_age_minutes(entry: dict) -> float | None:
    """Minutes since `entry["at"]`, or None if it is missing or unparseable.

    `None` on anything `_entry_stamp()` cannot read (a hand-edited line, a
    future format change) rather than raising, and the caller treats `None` as
    "cannot judge staleness" and falls back to NOT stale -- the safe
    direction, because the failure mode this guards against is a slot that
    never gets released, not one released a little early.
    """
    stamp = _entry_stamp(entry)
    if stamp is None:
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


BOARDS_PY = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "bin", "boards.py",
)


def declared_boards(foreman_home: str) -> list[str]:
    """Board names from `<foreman_home>/boards.toml`, via `bin/boards.py --list`.

    A directory under `instances/` used to BE the roster: `host_slots()` just
    walked whatever was there. Now `boards.toml` is what declares a board, so a
    runtime directory a removed (or never-declared) board left behind must stop
    counting — otherwise removing a board from `boards.toml` silently shrinks
    what this machine will ever dispatch, forever, with nothing saying so.

    Tolerant like the rest of this module: a `boards.toml` that fails to load
    (missing, malformed, refused by `boards.py`) reads as "no boards declared"
    rather than raising. `--host-slots` is advisory input to a ceiling — a
    machine not yet carrying a valid `boards.toml` must not take the tick down
    over it.
    """
    code, out = run([BOARDS_PY, "--file", os.path.join(foreman_home, "boards.toml"), "--list"])
    if code != 0:
        return []
    return [name for name in out.split("\0") if name]


def board_priorities(foreman_home: str) -> dict:
    """Each declared board's priority, from `boards.py`. Absent reads as 1.

    Tolerant for the same reason `declared_boards()` is: this feeds a ceiling,
    and a machine whose `boards.toml` will not load must not take the tick down
    over it. A board whose priority cannot be read is treated as ordinary.
    """
    out = {}
    for name in declared_boards(foreman_home):
        code, blob = run([BOARDS_PY, "--file",
                          os.path.join(foreman_home, "boards.toml"), name])
        priority = 1
        if code == 0:
            fields = [f for f in blob.split("\0")]
            for key, value in zip(fields[0::2], fields[1::2]):
                if key == "PRIORITY":
                    try:
                        priority = int(value)
                    except ValueError:
                        priority = 1
        out[name] = priority
    return out


def dispatch_verdict(foreman_home: str, board: str, host_max: int,
                     stale_minutes: float | None = HOST_SLOT_STALE_MINUTES) -> str:
    """"" if `board` may take a slot, else one line saying why not.

    THE PROBLEM. `HOST_MAX_CONCURRENT` bounds cards in flight across every board
    sharing a machine, because RAM and disk are shared. First-come-first-served
    is how one busy board holds every slot and a second board never dispatches
    at all -- and a board that never dispatches looks exactly like a board with
    no work.

    THE RULE. Each board earns a FLOOR: its share of the ceiling, never below 1
    for any declared board, so nothing with a priority is ever starved.

        floor(b)     = max(1, host_max * priority(b) / sum of priorities)
        available(b) = host_max - total_held
                       - sum over other boards j of max(0, floor(j) - held(j))

    A board may dispatch when `available >= 1`. That lets it use capacity
    nobody is using, while reserving what other boards are still owed.

    Worked example, which the test pins: host_max 4, two boards at priorities 3
    and 1, so floors 3 and 1. With nothing held the first may take three and not
    the fourth, because the second's floor is unmet. With the first holding
    three, the second may still take its one.

    Priority 0 means no floor: such a board takes only surplus. That is a way to
    say "run this when nothing else needs the machine", and it is deliberately
    expressible.
    """
    slots = host_slots(foreman_home, stale_minutes)
    held = slots.get("instances") or {}
    total = slots.get("total", 0)
    priorities = board_priorities(foreman_home)
    if board not in priorities:
        # Not declared: `boards.py` refuses it elsewhere, and inventing a floor
        # for a board this machine does not run would reserve capacity forever.
        return ""
    weight = sum(priorities.values())
    floors = {}
    for name, priority in priorities.items():
        if priority <= 0 or weight <= 0:
            floors[name] = 0
        else:
            floors[name] = max(1, (host_max * priority) // weight)
    owed = sum(max(0, floors[j] - held.get(j, 0)) for j in priorities if j != board)
    available = host_max - total - owed
    if available >= 1:
        return ""
    if total >= host_max:
        return f"this machine holds {total} of {host_max} slots across every board"
    reserved = sorted(j for j in priorities
                      if j != board and floors[j] > held.get(j, 0))
    return (f"{board} is at its share: {total} of {host_max} slots are held and "
            f"{owed} more {'is' if owed == 1 else 'are'} reserved for "
            f"{', '.join(reserved)}")


def host_slots(foreman_home: str, stale_minutes: float | None = HOST_SLOT_STALE_MINUTES) -> dict:
    """Cards holding a slot, counted across every DECLARED board on this machine.

    `{"instances": {name: count, ...}, "tickets": {name: [id, ...]}, "total": N}`.
    The counts are the ceiling's input; `tickets` is what lets a caller tell a
    card ENTERING the board from one already on it. `dispatch.sh` needs that
    distinction: a resume or a reviewer for a card that already holds a slot
    must not be refused for consuming a slot it is already counted in, or every
    fix-dispatch blocks itself. This is the host-wide
    ceiling's input: `HOST_MAX_CONCURRENT` bounds the total across every
    board sharing this machine's RAM and disk, the same way a single
    instance's `MAX_CONCURRENT` bounds its own cards — see config.sh.

    The board roster comes from `declared_boards()`, i.e. `boards.toml`, not
    from listing `<foreman_home>/instances/`. Each declared board's runtime
    directory still keeps its name and its `cards/` subdirectory — that part
    of the layout survives — so the read itself is unchanged: no Linear, no
    `gh`, no `claude agents`, cheap enough to check before every dispatch.

    Tolerant by design, per its one caller (a tick deciding whether IT may
    dispatch): a declared board with no runtime directory yet, no `cards/` at
    all, a card with no `history.jsonl`, or a `history.jsonl` holding
    unparseable lines must never raise. This is advisory input to a ceiling,
    not a fact the tick depends on being able to fetch — failing to read one
    board's slots must not take down the tick that asked about all of them.
    """
    instances_dir = os.path.join(foreman_home, "instances")
    result: dict = {"instances": {}, "tickets": {}, "total": 0}
    for name in declared_boards(foreman_home):
        cards_dir = os.path.join(instances_dir, name, "cards")
        try:
            tickets = sorted(os.listdir(cards_dir))
        except OSError:
            # No cards/ at all -- a declared board that has never dispatched
            # anything yet, or has no runtime directory at all. Present in the
            # report at 0, not absent: an absent key would be indistinguishable
            # from a listing failure for `instances_dir` itself.
            result["instances"][name] = 0
            result["tickets"][name] = []
            continue
        holding = []
        for ticket in tickets:
            history_path = os.path.join(cards_dir, ticket, "history.jsonl")
            if card_holds_slot(history_path, stale_minutes):
                holding.append(ticket)
        result["instances"][name] = len(holding)
        result["tickets"][name] = holding
        result["total"] += len(holding)
    return result


SERVED_STAMP = "last-served"


def _served_path(foreman_home: str, board: str) -> str:
    return os.path.join(foreman_home, "instances", board, SERVED_STAMP)


def mark_board_served(foreman_home: str, board: str) -> None:
    """Record that a slice has just taken `board`'s turn. Writes, returns nothing.

    WHY THIS FILE EXISTS. `board_last_served()` used to read history.jsonl
    alone, and history only grows when a card MOVES. A slice that ends at
    "nothing immediately actionable" -- the ordinary state of a board whose
    Todo is empty -- writes nothing at all, so that board stayed `never
    served` and pinned the front of every pass forever, pushing the boards
    that do work to the back. That is the starvation `board_order()` exists to
    remove, made permanent instead of alphabetical. The fix is to record the
    turn, not the outcome: a board that was reached and had nothing to do was
    still served.

    The stamp is a cache and never truth, the same standing `cards/` has.
    Delete it and the board reads as never served, sorts first, and is stamped
    again on its next slice -- one unrotated pass, never a wrong answer. It
    holds no card position, so nothing here contradicts SKILL.md's rule that
    the sidecar can be deleted and the next tick must still reconstruct every
    card's state.

    Written through a temporary file in the same directory and `os.replace`,
    so a reader never sees half a timestamp. A torn stamp would read as never
    served, which is recoverable, but the whole file is 21 bytes and the
    atomic write costs two lines.
    """
    directory = os.path.join(foreman_home, "instances", board)
    os.makedirs(directory, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime(CARD_LOG_STAMP)
    tmp = os.path.join(directory, f".{SERVED_STAMP}.{os.getpid()}")
    with open(tmp, "w") as fh:
        fh.write(stamp + "\n")
    os.replace(tmp, _served_path(foreman_home, board))


def _served_stamp(foreman_home: str, board: str) -> datetime | None:
    """The `last-served` stamp for `board`, or None if it has none to read."""
    try:
        with open(_served_path(foreman_home, board)) as fh:
            text = fh.readline().strip()
    except OSError:
        return None
    return _parse_stamp(text)


def board_last_served(foreman_home: str, board: str) -> datetime | None:
    """When a slice last took `board`'s turn, or None if none ever has.

    TWO WITNESSES, AND THE NEWER ONE WINS.

    - `instances/<board>/last-served`, written by `mark_board_served()` at the
      top of every slice. This is the one that answers the question, because
      it is written whether or not the slice found anything to do.
    - The newest `at` across `instances/<board>/cards/<T>/history.jsonl`.
      `config.sh:card_log` appends there on every spawn, resume, void and
      released, from `dispatch.sh` and `sweep.sh` -- scripts, not prose. So a
      slice that dispatched leaves this trace even if the stamp above was
      never written.

    Neither witness alone is enough. The stamp is written by the tick
    following SKILL.md, and prose is not a gate; history is written
    mechanically but only when a card actually moves. Each covers the other's
    blind spot, and taking the newer of the two can only ever move a board
    later in the order -- towards the back, never towards starving another
    board at the front.

    Read EVERY entry of every card, not each card's last line. A corrupt
    trailing line would otherwise lose the board's real timestamp and report a
    board served a minute ago as never served. Never filter on the event's
    action either: a `released` card was still served at the moment it was
    released, and a board whose only activity this tick was reaping would
    otherwise keep jumping the queue forever.

    Tolerant exactly like `host_slots()`, which walks the same files: a board
    with no runtime directory, no `cards/`, no `history.jsonl`, or nothing but
    unparseable lines returns None and sorts first. Failing to read one
    board's history must not take down the tick that asked about all of them.
    """
    newest = _served_stamp(foreman_home, board)
    cards_dir = os.path.join(foreman_home, "instances", board, "cards")
    try:
        tickets = os.listdir(cards_dir)
    except OSError:
        return newest
    for ticket in tickets:
        for entry in _read_jsonl(os.path.join(cards_dir, ticket, "history.jsonl")):
            stamp = _entry_stamp(entry)
            if stamp is not None and (newest is None or stamp > newest):
                newest = stamp
    return newest


def board_is_halted(foreman_home: str, board: str) -> bool:
    """Whether `bin/boardctl halt` has parked `board`.

    A file check on `instances/<board>/HALT`, in this process. It never sources
    that board's config, which SKILL.md forbids for a halted board -- the same
    access `host_slots()` already makes to every board's `cards/`.
    """
    return os.path.exists(os.path.join(foreman_home, "instances", board, "HALT"))


_BEFORE_ANY_STAMP = datetime.min.replace(tzinfo=timezone.utc)


def _pass_position(entry: tuple[str, datetime | None, bool]) -> tuple:
    """Where one `(board, last_served, halted)` goes in the pass.

    A datetime and None do not compare, so "never served" is its own key rather
    than a sentinel date. A sentinel would be a second place the never-served
    fact lived, and the wrong sentinel sorts a never-served board LAST, which
    is the starvation being fixed.
    """
    name, stamp, halted = entry
    return (halted, stamp is not None, stamp or _BEFORE_ANY_STAMP, name)


def board_order(foreman_home: str) -> dict:
    """The board order for one pass, least recently served first.

    `{"order": [name, ...], "boards": [{"board": name, "last_served": stamp,
    "halted": bool}]}`, both in the same order, `last_served` null for a board
    never served.

    THE PROBLEM. One tick agent works every board on this machine, a slice
    each. It used to take that list from `bin/boards.py --list`, which prints
    boards in NAME order, the same order on every pass of every tick.
    `TICK_BUDGET_MINUTES` and `TICK_MAX_PASSES` bound the whole tick and not
    each board, so a tick that runs out of budget mid-pass stops at whichever
    board it had reached -- always the same tail of the list, tick after tick.
    A board a tick never reached reports exactly what a board with no work
    reports, so nothing says so. SKILL.md already called the loop round-robin,
    but the rotation only held INSIDE a pass, and prose is not a gate.

    THE RULE. A halted board sorts LAST. Among the rest, never served sorts
    FIRST, then oldest served first, then by board name. The name breaks every
    tie, so the order is total and the same machine prints the same lines for
    the same evidence.

    WHY HALTED LAST. `mark_board_served()` is never run for a halted board:
    SKILL.md says a halted board is skipped before anything of its is sourced,
    and `reconcile.py` sources `config.sh`. So a halted board is never served
    by construction, and "never served sorts first" would park it at the head
    of every pass for as long as the operator leaves it halted -- ahead of
    every board that can actually take work. Sorting it last says the same
    thing the tick already does with it, and `halted` in the report is why.
    This does not move the halt check: the tick still tests the file itself,
    because a board can be halted after this ran.

    WHAT "SERVED" MEANS. When a slice took the board's turn -- NOT when it last
    moved a card. Those came apart in the first version of this, which read
    `history.jsonl` alone: a board whose Todo is empty ends its slice having
    written nothing, so it stayed `never served`, sorted first on every pass
    forever, and pushed the boards doing real work to the back. The tick budget then spent itself on the idle boards and never
    reached the busy one. See `board_last_served()` for the two witnesses that now answer it.

    WHY NOT SLOTS HELD. A board holding three cards is the board with the most
    work needing a merge, so sorting it last would starve the boards that most
    need a slice -- the failure this whole mode exists to prevent. Slots held
    is the input to the CEILING (`dispatch_verdict()`), never to the order.

    The roster is `declared_boards()`, the same as `host_slots()`: a board
    exists because `boards.toml` declares it, so a leftover runtime directory
    for an undeclared board must not appear in a pass.
    """
    served = [(name,
               board_last_served(foreman_home, name),
               board_is_halted(foreman_home, name))
              for name in declared_boards(foreman_home)]
    served.sort(key=_pass_position)
    return {
        "order": [name for name, _, _ in served],
        "boards": [{"board": name,
                    "last_served": stamp.strftime(CARD_LOG_STAMP) if stamp else None,
                    "halted": halted}
                   for name, stamp, halted in served],
    }


def _attempts(entries: list[dict], role: str) -> int:
    """How many attempts of one role this card has actually consumed.

    Counts distinct attempt labels rather than spawn lines: a spawn and a later
    resume of the same attempt are one attempt, and re-dispatching the same
    attempt number after an environment repair must not count twice.

    A `void` entry removes an attempt from the count. An attempt budget exists
    to stop a card looping on a ticket that cannot be done; an attempt killed by
    a full disk is evidence about the machine and none at all about the ticket,
    so spending the budget on it retires work that was never tried. Voiding is
    for environment faults only — an attempt that genuinely failed keeps its
    cost.

    One body for both roles because that is one rule, not two. A second copy
    drifts, and a drifted copy is a budget that quietly stops counting on one
    stage while the operator still believes both are capped.
    """
    seen, voided = set(), set()
    for e in entries:
        ev = e.get("event") or {}
        if ev.get("role") != role:
            continue
        if ev.get("action") == "spawn":
            seen.add(str(ev.get("attempt")))
        elif ev.get("action") == "void":
            voided.add(str(ev.get("attempt")))
    return len(seen - voided)


def build_attempts(entries: list[dict]) -> int:
    """Build attempts consumed, which step 2 checks against MAX_BUILD_ATTEMPTS."""
    return _attempts(entries, "build")


def plan_rounds(entries: list[dict]) -> int:
    """How many times a parked card's agent has been resumed to revise its plan.

    Counted from `history.jsonl`, never from agent names -- the same reason
    `build_attempts` gives: `agents_for()` can only ever report the CURRENT
    agent under its deterministic name (`build-<attempt>`), and that name is
    identical whether the agent was resumed for a failing check, a blocking
    review finding, or a plan revision. The name carries a role and an attempt
    number, not a reason a resume happened. History is the only place the
    reason is recorded at all.

    `dispatch.sh --resume` already logs one unconditional line for every
    resume of every kind: `{"action":"resume","name":...,"session":...}`. That
    cannot be what this counts -- it would count a build resumed to fix a
    failing check the same as a build resumed to revise a plan, the same
    conflation `build_attempts` exists to avoid on the build side. A plan
    round therefore needs its own entry, the same way an environmental
    write-off is a second, explicit `card_log` call layered on top of that
    generic line (see `build_attempts`'s `void`):

        card_log <T> '{"action":"resume","role":"plan","round":"<n>"}'

    This is the contract the board's tick (SKILL.md) must follow when it parks
    a `needs-plan` card and resumes it with unconsumed operator comments --
    written here because `reconcile.py` is what has to read it back. One row
    is one round, by construction: the board increments `round` itself before
    logging, so there is nothing here to dedupe the way `build_attempts`
    dedupes a spawn against a later resume of the same attempt number -- a
    round that needs revisiting again waits for the next operator comment
    first, which is a NEW row, not the same one replayed.
    """
    return sum(
        1
        for e in entries
        if (e.get("event") or {}).get("action") == "resume"
        and (e.get("event") or {}).get("role") == "plan"
    )


def plan_attempts(entries: list[dict]) -> int:
    """Plan attempts consumed, which step 2 checks against MAX_PLAN_ATTEMPTS.

    A separate counter from `build_attempts` because it answers a separate
    question. A card whose plan agent keeps dying would otherwise reach the
    build stage with its build budget already spent on a stage that produced no
    plan, and then fail the build almost at once for a reason the build agent
    had nothing to do with. Counted separately, a card that cannot be planned is
    parked for exactly that reason, and the build budget stays whole.

    Counted from `history.jsonl` by ROLE, never from agent names, and this is
    the same ambiguity `plan_rounds` above solves the same way: `agents_for()`
    reports an agent under a deterministic `<role>-<attempt>` name, and nothing
    outside history says which stage a given attempt belonged to. So this counts
    only entries that name their role explicitly -- the `role` field
    `dispatch.sh` writes on every spawn, and the one SKILL.md's `void` line
    carries -- and a generic entry that names no role counts for nothing here.

    Failed plan attempts only, in the sense `_attempts` gives: a plan agent
    resumed at the same attempt number is still one attempt, and an attempt
    voided for an environment fault is none. An operator asking for a revision
    of a plan that WAS posted is not a failure at all; that is `plan_rounds`,
    counted from resume entries, and the two caps are independent.
    """
    return _attempts(entries, "plan")


def death_report(path: str | None) -> dict | None:
    """Why did this agent's transcript stop? Read the tail and say.

    `phase` reports that an agent is terminal; it cannot distinguish an agent
    that finished cleanly from one that was killed mid-command. That difference
    decides whether the failure belongs to the ticket or to the machine, and
    getting it wrong spends a build attempt on an environment fault — which is
    exactly what happened to one card, twice, on 2026-08-02.

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
        "plan_rounds": plan_rounds(entries),
        "plan_attempts": plan_attempts(entries),
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
              "       reconcile.py --host-slots\n"
              "       reconcile.py --board-order\n"
              "       reconcile.py --served <board>\n"
              "       reconcile.py --may-dispatch <board>", file=sys.stderr)
        return 2
    if argv[0] == "--main-ci":
        # No agent registry, no Linear, no cards: this answers one question about
        # one branch, and step 0 asks it before any of that exists.
        json.dump(main_ci_state(argv[1] if len(argv) > 1 else "main"),
                  sys.stdout, indent=2)
        print()
        return 0
    if argv[0] == "--may-dispatch":
        # Prints nothing and exits 0 when the board may take a slot; prints one
        # human line when it may not. The arithmetic lives here rather than in
        # dispatch.sh because logic deciding whether work may start belongs
        # somewhere a test can reach it -- an apostrophe inside that script's
        # inline python once closed the surrounding shell string and disabled
        # the whole gate silently.
        if len(argv) < 2:
            print("usage: reconcile.py --may-dispatch <board>", file=sys.stderr)
            return 2
        try:
            host_max = int(os.environ.get("HOST_MAX_CONCURRENT", "4"))
        except ValueError:
            host_max = 4
        verdict = dispatch_verdict(FOREMAN_HOME, argv[1], host_max)
        if verdict:
            print(verdict)
        return 0
    if argv[0] == "--served":
        # Written at the TOP of a slice, before the slice knows whether it will
        # find anything to do. That is the whole point: a board reached and
        # found idle was still served, and recording only the boards that moved
        # a card is what pinned every quiet board to the front of every pass.
        #
        # Names its board rather than reading INSTANCE from the environment. A
        # stale FOREMAN_INSTANCE from the previous board is this skill's oldest
        # bug shape, and stamping the wrong board sends the right one to the
        # back of the queue with nothing saying so. The name is in the command.
        if len(argv) < 2:
            print("usage: reconcile.py --served <board>", file=sys.stderr)
            return 2
        board = argv[1]
        if board not in declared_boards(FOREMAN_HOME):
            # Refuse rather than create `instances/<typo>/last-served` and
            # report success. A stamp nothing ever reads means the board the
            # operator meant is still never served, and the order still starves
            # it -- silently, which is the failure this whole mode removes.
            print(f"reconcile: no board named {board} in "
                  f"{os.path.join(FOREMAN_HOME, 'boards.toml')}", file=sys.stderr)
            return 2
        mark_board_served(FOREMAN_HOME, board)
        return 0
    if argv[0] == "--board-order":
        # The pass order, not the roster: `boards.py --list` prints boards in
        # name order and the tick used to loop over that, which left the same
        # tail of the list unreached every time a tick ran out of budget
        # mid-pass. Local files only, like --host-slots, so the tick can ask
        # before it has spoken to Linear or gh.
        json.dump(board_order(FOREMAN_HOME), sys.stdout, indent=2)
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
