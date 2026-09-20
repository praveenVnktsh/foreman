#!/usr/bin/env python3
"""Join everything the board tick needs to know about a set of cards.

    reconcile.py ABC-42 ABC-43 ...

Emits one JSON object per ticket on stdout. The tick reasons over this instead
of running twenty shell commands and eyeballing the output.

Linear is deliberately NOT read here — the tick already has the card's column
from MCP and joins it in. This script covers the three evidence sources that
answer "what actually happened": the harness adapter, git, and `gh`.

Nothing here runs `claude` by name any more. A tick may spawn a stage on a
harness other than foreman's own -- a fallback tier names one -- so liveness
and the transcript path are asked of `$HARNESS_SH`, the registry that merges
every harness config.sh knows about. Every name this file matches on carries
the BOARD, so two boards sharing one repository never read each other's
agents, worktrees or branches as their own.

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
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote

def _load_config() -> dict[str, str]:
    """Read settings from config.sh — the single source of truth.

    Duplicating these as Python defaults is how the merge policy silently fails:
    config.sh is a shell file the tick may never source into this process, so a
    second copy here would keep parking diffs the operator had already opted to
    merge. Sourcing it means there is exactly one place to change a setting.
    """
    keys = (
        "REPO", "BOARD_HOME", "REQUIRED_CHECKS", "HIGH_RISK_PATHS",
        "DEPLOY_WORKFLOW", "DEPLOY_STEP", "DEPLOY_SELECTION_STEP", "CI_WORKFLOW",
        "INSTANCE",
        "FOREMAN_HOME", "HOST_SLOT_STALE_MINUTES", "HARNESS_SH", "TICK_AGENT_NAME",
        "FOREMAN_DEFAULT_HARNESS", "FOREMAN_HARNESSES",
        "BOARD_NAME_PREFIX", "BOARD_WORKTREE_PREFIX",
        "CLEANUP_EVERY_DAYS", "MAX_CONCURRENT", "REVIEWERS_PER_ROUND",
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


# fallback.py owns the rate-limit stamp directory's name and its filename
# encoding. --overview reports those stamps, and a second spelling of either
# here would read an empty directory the day fallback.py moved its own.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fallback  # noqa: E402  (see sys.path.insert above -- sibling module)

_CFG = _load_config()
# registry.sh, which HARNESS_SH points at, reads the harness set from the
# environment. This process was handed only config.sh's keys, so put the two it
# needs into the environment its own subprocesses inherit.
for _key in ("FOREMAN_DEFAULT_HARNESS", "FOREMAN_HARNESSES"):
    if _CFG.get(_key):
        os.environ.setdefault(_key, _CFG[_key])
REPO = _CFG["REPO"]
INSTANCE = _CFG["INSTANCE"]
BOARD_HOME = _CFG["BOARD_HOME"]
REQUIRED_CHECKS = set(c for c in _CFG["REQUIRED_CHECKS"].split("|") if c)
HIGH_RISK_PATHS = _CFG["HIGH_RISK_PATHS"].split()
DEPLOY_WORKFLOW = _CFG["DEPLOY_WORKFLOW"]
DEPLOY_STEP = _CFG["DEPLOY_STEP"]
# The step that decides whether a deploy run deploys at all. Optional: empty
# means the target deploys every carrying run it can, and the old reading of
# DEPLOY_STEP alone applies unchanged. See _not_deployed for what it changes.
DEPLOY_SELECTION_STEP = _CFG["DEPLOY_SELECTION_STEP"]
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
# The two name roots config.sh composes for this board: `foreman/<board>`, and
# the worktree basename `foreman-<board>`. Read, never recomposed here -- a
# copy of the shape that disagreed with config.sh would look a card's branch
# up under a name that does not exist.
BOARD_NAME_PREFIX = _CFG["BOARD_NAME_PREFIX"]
BOARD_WORKTREE_PREFIX = _CFG["BOARD_WORKTREE_PREFIX"]
# The adapter for this installation's harness. config.sh refuses to export a
# path that is not executable, so nothing here re-checks it.
HARNESS_SH = _CFG["HARNESS_SH"]
# The tick's own agent name, READ from config.sh and never respelled here --
# config.sh calls itself "the one place a name's shape is decided", and
# supervise.sh finds the tick by this same string.
TICK_AGENT_NAME = _CFG["TICK_AGENT_NAME"]
# Empty means "disabled" -- see host_slots()'s docstring for why that is a
# real, supported value and not just an unset-variable accident.
HOST_SLOT_STALE_MINUTES = (
    float(_CFG["HOST_SLOT_STALE_MINUTES"]) if _CFG["HOST_SLOT_STALE_MINUTES"] else None
)


def _int_setting(key: str) -> int:
    """One contract integer, refused rather than defaulted when it will not parse.

    `bin/contract.py` already refuses a limit that is not an integer, so a
    value that arrives here unparseable can only be an environment override --
    config.sh reads every contract key with `-`, so `MAX_CONCURRENT=lots` in
    the environment wins over a board.toml that said 2. Defaulting there would
    weigh a ceiling nobody declared, which is the failure the CI_WORKFLOW guard
    above refuses for an emptied required value.
    """
    raw = _CFG[key]
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(
            f"reconcile: {key} is {raw!r}, which is not an integer; "
            f"bin/contract.py refuses that, so this is an environment override"
        ) from None


# How many days apart a board's scheduled cleanups run, 0 meaning off.
CLEANUP_EVERY_DAYS = _int_setting("CLEANUP_EVERY_DAYS")
# This BOARD's own ceiling on cards in flight, from board.toml's `[limits]` --
# not HOST_MAX_CONCURRENT, which bounds the whole machine. `cleanup_verdict()`
# weighs both, because a cleanup agent occupies a slot like any other agent.
MAX_CONCURRENT = _int_setting("MAX_CONCURRENT")
# How many reviewers one round dispatches. `review_verdict()` reads it to tell
# a round that is fully dispatched from one the tick was interrupted part-way
# through; a round short of its reviewers has not been reviewed yet.
REVIEWERS_PER_ROUND = _int_setting("REVIEWERS_PER_ROUND")

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
    """The file whose mtime is this agent's last activity, or "" if unknown.

    Asked of the adapter, `$HARNESS_SH transcript <cwd> <session-id>`. The rule
    that Claude persists a session at `~/.claude/projects/<slug>/<id>.jsonl`,
    with the slug being the cwd with every '/' and '.' replaced by '-', now
    lives in `skills/board/harness/claude.sh` and nowhere else -- Codex and
    OpenCode keep a log instead, and a copy of Claude's slug rule here would be
    the wrong path on two harnesses out of three.

    The name stays because `waitfor.py` imports this module's readers rather
    than restating them.

    "" for an adapter that could not answer, which every caller already handles:
    a path it does not get is a path it does not stat, so the agent reports no
    transcript and no idle time. That is the same answer as an agent whose
    session file has not been written yet, and it is the safe one -- idle time
    is only ever used to judge a stall, never to decide that work may start.
    """
    code, out = run([HARNESS_SH, "transcript", cwd, session_id])
    if code != 0:
        return ""
    return out.strip()


def load_agents() -> list[dict] | None:
    """Every registered agent, or None if the registry could not be read.

    `or []` folded a failed registry read into "no agents are running" — the
    same defect fixed in supervise.sh, where answering it by starting an agent
    produces a second loop agent. Here it is quieter and worse: a card whose
    build agent exists reads as having none, and step 2 treats "no agent, no PR"
    as a tick that died before dispatching and re-dispatches on top of a live one.
    """
    agents = run_json([HARNESS_SH, "list"])
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
    #
    # The BOARD segment closes the same hole one level up. The registry this
    # reads is one flat list for the machine, and two boards may serve one
    # repository -- so without the segment one board would match the other's
    # build agent for the same ticket and read its phase as its own.
    # config.sh:card_agents_prefix is the same BOARD_NAME_PREFIX plus the
    # ticket; this must match it exactly or a card reports no agents at all.
    prefix = f"{BOARD_NAME_PREFIX}/{ticket}/"
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

    That is why the prefix is read from config.sh and not spelled here. When
    config.sh:branch_name gained the installation segment, a copy here would
    have had to gain it in the same commit. The legacy installation then kept
    the old shape for its open pull requests, and a copy here that had gained
    the segment would have found none of them -- and the board would have
    built every one of those cards again.
    """
    return f"{BOARD_NAME_PREFIX}/{ticket}"


def pr_for(ticket: str) -> dict | None:
    branch = branch_for(ticket)
    prs = run_json(
        [
            "gh", "pr", "list", "--head", branch, "--state", "all",
            "--json", "number,state,headRefOid,mergeStateStatus,mergeCommit,"
                      "url,isDraft,title,statusCheckRollup,isCrossRepository",
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

    # ONLY A PULL REQUEST FROM THIS REPOSITORY IS EVER THE CARD'S.
    #
    # `--head` matches a branch by NAME, and gh says so: '"<owner>:<branch>"
    # syntax not supported'. A fork's pull request whose branch has the same
    # name is therefore returned here exactly like the board's own. On a private
    # repository nobody can open one, so this never mattered. On a public one,
    # anyone can -- and the name is not a secret: the prefix is fixed by
    # config.sh, and the ticket keys in flight are printed in merged pull
    # request titles.
    #
    # Found on 2026-09-16, auditing the repository before making it public. The
    # chain it closes: a stranger forks, names a branch for a card that is being
    # built, and opens a pull request after the board's own. `newest()` below
    # picks theirs. The board then reviews and merges a diff the stranger wrote,
    # and since each installation now fast-forwards to `main` on a timer, that
    # diff is running on the operator's machine minutes later, beside the gh
    # token and every harness session. Adversarial review would be the only
    # thing standing in the way, and it reads the diff the attacker chose.
    #
    # Kept only when `isCrossRepository` is exactly False. A row that omits it
    # has an origin nobody established, and this returns the one pull request
    # step 4 may merge autonomously -- so an unknown origin is dropped, not
    # trusted. merge.py refuses a cross-repository pull request as well: the
    # merge is the irreversible step, and it checks its own precondition rather
    # than relying on this having run.
    prs = [p for p in prs if p.get("isCrossRepository") is False]
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
    newer run. `deploy-queued` and `deploy-selection-failed` are ordinary
    terminal answers: an older run whose deploy broke still beats a newer run
    that only queued, because production is broken whatever the queue says. Preferring a terminal answer can end a wait a tick early when a
    newer stand-down really did have a deploy still coming; that costs a card one
    tick, because nothing is ever marked `Done` on a terminal-but-unverified
    answer and the next tick re-derives all of it. Missing a broken production
    deploy costs the opposite.
    """
    rank = (lambda v: 2 if v.get("outcome") == "deploy-failed"
            else 1 if v.get("terminal") else 0)
    return current is None or rank(candidate) > rank(current)


@dataclass(frozen=True)
class RunSteps:
    """What one `gh run view --json jobs` said about a deploy run's steps.

    `state` is "ok" (DEPLOY_STEP exists; `deploy` is its conclusion, "" while
    unfinished), "absent" (the run completed without DEPLOY_STEP) or
    "unreadable" (`gh run view` failed; nothing else here is known).
    `selection` is DEPLOY_SELECTION_STEP's conclusion, None when that step is
    not configured or not in the run. `selection_job` is the databaseId of the
    job holding it, which is what the job log is fetched by.
    """

    state: str
    deploy: str | None = None
    selection: str | None = None
    selection_job: int | None = None


# One raw job-log line: an ISO-8601 timestamp, one space, then the content.
_LOG_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\S+ ")
_REASON_PREFIX = "reason="


def selection_reason(job_id: int | None) -> str | None:
    """The selection step's `reason=` value, read from the job log, or None.

    None means the reason could not be read: no job id, a failed `gh api`, or a
    log with no `reason=` line. The caller must never read None as "queued".

    The step writes its outputs through `tee -a "$GITHUB_OUTPUT"`, so the log
    holds them and `gh run view --json jobs` does not. The LAST `reason=` line
    wins, because the log also carries anything the script printed before it
    settled. A line without a timestamp is read as bare content.
    """
    if job_id is None:
        return None
    code, log = run(["gh", "api", f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}/logs"],
                    cwd=REPO)
    if code != 0:
        return None
    found = None
    for line in log.splitlines():
        content = _LOG_TIMESTAMP.sub("", line.lstrip("\ufeff").rstrip("\r"), count=1)
        if content.startswith(_REASON_PREFIX):
            found = content[len(_REASON_PREFIX):].strip()
    return found or None


def _not_deployed(r: dict, head: str, sha: str, steps: RunSteps,
                  reason: str | None = None) -> dict:
    """Why one run that carries `sha` did not deploy it, and whether that is final.

    Final means: this answer cannot improve by waiting. Four shapes are final.

      * `failure` — the deploy script ran on the deploy host and broke. Production
        is in whatever state it left behind, and the tick must say so now.
      * no DEPLOY_STEP at all — the deploy job was skipped in its entirety, which
        is what a red CI run on `main` produces (the deploy workflow gates the job
        on the CI run concluding success). That run will never deploy anything.
      * DEPLOY_SELECTION_STEP concluded `failure` (`deploy-selection-failed`) —
        the workflow could not choose a revision, so nothing deploys until a
        person looks. It writes no HALT, so the card is the only place it shows.
      * the selection succeeded and its `reason` (read from the log by the
        caller, passed in) starts with `queued:` (`deploy-queued`) — the target
        holds this commit for its next scheduled deploy. That is the target's
        policy working, so it satisfies the card without verifying it.

    Everything else keeps the wait alive: a `skipped` STEP is the stale-revision
    stand-down with a descendant's deploy still coming, and an unreadable run
    taught us nothing at all. The queue is read, never inferred from `skipped`,
    because a `stand-down:` skip looks identical at the step level. A reason
    that could not be read keeps the wait open too: queued on missing evidence
    would move a card to `Done` for a deploy that may never be scheduled.
    """
    where = "" if head == sha else f" of descendant {head[:12]}"
    state, concl = steps.state, steps.deploy
    if steps.selection == "failure":
        return {
            "verified": False, "terminal": True, "outcome": "deploy-selection-failed",
            "reason": f"deploy run {r['databaseId']}{where}: {DEPLOY_SELECTION_STEP} "
                      f"failed; deploys have stopped until it is fixed",
            "url": r.get("url"),
        }
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
    if not _selection_decided_skip(steps):
        return verdict
    if reason is None:
        verdict["reason"] += f"; could not read the {DEPLOY_SELECTION_STEP} reason"
        return verdict
    verdict["selection_reason"] = reason
    if reason.startswith("queued:"):
        verdict.update(
            terminal=True, outcome="deploy-queued",
            reason=f"deploy run {r['databaseId']}{where} queued this commit: {reason}",
        )
    return verdict


def _selection_decided_skip(steps: RunSteps) -> bool:
    """Did the selection step succeed and the deploy step then skip?

    Only this shape has a reason worth a log fetch. The fetch is a round trip
    per run, so every other shape must not pay it.
    """
    return (steps.selection == "success" and steps.state == "ok"
            and steps.deploy == "skipped")


def deploy_verdict(sha: str) -> dict:
    """Deployment is the DEPLOY_STEP concluding success, never the job.

    A stale-revision stand-down concludes `success` at the job level, which is
    why reading the job would call a non-deploy a deploy.

    Every return carries `terminal`: True when no amount of further waiting can
    change this answer. `verified` says whether the commit is live; `terminal`
    says whether the question is settled. The pair is what lets waitfor.py stop
    on a deploy that ran and BROKE — which is neither satisfied nor still coming
    — instead of polling it for the whole budget on every tick, forever.

    With DEPLOY_SELECTION_STEP set, two more terminal outcomes exist:
    `deploy-queued` (satisfied, not verified) and `deploy-selection-failed`.
    _not_deployed describes both. A successful DEPLOY_STEP on the commit or a
    descendant still verifies first, whatever event started the run.

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
    # No `--event`: a scheduled run deploys queued commits, and it verifies them
    # like any other run.
    #
    # `--limit 20` still reaches far enough. A queuing target adds one run per CI
    # completion on `main` plus six scheduled runs a day: at ~80 merges a week
    # that is ~11 + 6 = ~18 runs a day. The wait starts minutes after the merge,
    # and its answer is the commit's own run or a descendant's, which are the
    # newest runs in the list. Twenty runs cover about a day.
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

    def run_steps(run: dict) -> RunSteps:
        """DEPLOY_STEP and DEPLOY_SELECTION_STEP for one run, from one round trip.

        A bare `None` meant two opposite things and the caller could not tell
        them apart: `gh run view` failed, so nothing was learned; or the run
        completed with no DEPLOY_STEP at all, which is the deploy job being
        skipped outright because CI went red on the squash. The first must never
        stop a wait, and the second always should — that run will never deploy
        anything, however long anyone waits on it. `RunSteps.state` keeps them
        apart.
        """
        detail = run_json(
            ["gh", "run", "view", str(run["databaseId"]), "--json", "jobs"], cwd=REPO
        )
        if detail is None:
            return RunSteps("unreadable")
        deploy = selection = selection_job = None
        found_deploy = False
        for job in detail.get("jobs", []):
            for step in job.get("steps", []):
                name = step.get("name")
                if name == DEPLOY_STEP and not found_deploy:
                    found_deploy, deploy = True, step.get("conclusion")
                elif DEPLOY_SELECTION_STEP and name == DEPLOY_SELECTION_STEP \
                        and selection is None:
                    selection = step.get("conclusion") or ""
                    selection_job = job.get("databaseId")
        return RunSteps("ok" if found_deploy else "absent", deploy,
                        selection, selection_job)

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
        # Ancestry first, steps second. `run_steps` is a `gh run view`
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
        steps = run_steps(r)
        if steps.state != "ok" or steps.deploy != "success":
            # Records why this run did not verify, without letting it contribute
            # an attribution. Which non-success it was decides everything:
            # `skipped` is a stand-down with a descendant still coming, `failure`
            # is the deploy script breaking on the deploy host, and no step at all
            # is the deploy job never having run. deploy_state needs to tell them apart.
            reason = (selection_reason(steps.selection_job)
                      if _selection_decided_skip(steps) else None)
            candidate = _not_deployed(r, head, sha, steps, reason)
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

    `--host-slots` cannot ask Linear or the agent registry for every board on
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


_BIN = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "bin",
)
BOARDS_PY = os.path.join(_BIN, "boards.py")


class BoardsUnreadable(Exception):
    """`boards.toml` could not be read.

    It is an exception and not an empty roster because of what an empty roster
    would mean here: zero cards in flight anywhere on the machine. The ceiling
    would then be computed as though every board's builds did not exist, and
    this board would dispatch on top of them -- the 2026-09-01 over-dispatch
    (five builds against a MAX_CONCURRENT of 1, load average 14), and with
    nothing on any tick's stderr to say so. One unmounted repository path is
    enough to make `boards.py` refuse the file.
    """


def declared_boards(foreman_home: str) -> list[str]:
    """Board names from `<foreman_home>/boards.toml`, via `bin/boards.py --list`.

    A directory under `instances/` used to BE the roster: `host_slots()` just
    walked whatever was there. Now `boards.toml` is what declares a board, so a
    runtime directory a removed (or never-declared) board left behind must stop
    counting — otherwise removing a board from `boards.toml` silently shrinks
    what this machine will ever dispatch, forever, with nothing saying so.

    RAISES `BoardsUnreadable` when that file will not load, rather than reading
    a failed load as "no boards declared". See the exception's own docstring:
    the tolerant version turned a roster nobody could read into a machine with
    nothing in flight, which is the one direction this count must never fail in.
    `boards.py`'s own message is carried through, because it is the only thing
    that says WHICH declaration is wrong.
    """
    boards_toml = os.path.join(foreman_home, "boards.toml")
    try:
        done = subprocess.run([BOARDS_PY, "--file", boards_toml, "--list"],
                              capture_output=True, text=True, timeout=GH_TIMEOUT)
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        raise BoardsUnreadable(f"could not run {BOARDS_PY} on {boards_toml}: {exc}") from exc
    if done.returncode != 0:
        raise BoardsUnreadable(
            f"{boards_toml} did not load (boards.py --list exited "
            f"{done.returncode}): {done.stderr.strip() or 'no message on stderr'}"
        )
    return [name for name in done.stdout.split("\0") if name]


def board_priorities(foreman_home: str) -> dict:
    """Each declared board's priority, from `boards.py`. Absent reads as 1.

    The ROSTER refuses when it cannot be read -- see `declared_boards()` -- but
    one board's unreadable priority still reads as 1. The two are different
    failures: a roster nobody can read hides cards from the ceiling, while a
    priority nobody can read only weights an existing board as ordinary.
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


def dispatch_verdict(board: str, host_max: int,
                     stale_minutes: float | None = HOST_SLOT_STALE_MINUTES) -> str:
    """"" if `board` may take a slot, else one line saying why not.

    `board` is a bare board name, the one an operator and the tick already use.
    The boards being weighed against each other are every board declared in
    `boards.toml`, because they share one machine's RAM and disk.

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
    slots = host_slots(stale_minutes)
    held = slots.get("instances") or {}
    total = slots.get("total", 0)
    priorities = board_priorities(FOREMAN_HOME)
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


def cards_holding_slots(cards_dir: str, stale_minutes: float | None) -> list[str]:
    """The tickets under one board's `cards/` that still occupy a build slot.

    `[]` for a directory that cannot be listed -- a declared board that has
    never dispatched anything, or has no runtime directory at all. That is the
    same "absence is not an error" reading `_read_jsonl()` gives an unreadable
    history, and it is why `host_slots()` never has to know why a read failed.
    """
    try:
        tickets = sorted(os.listdir(cards_dir))
    except OSError:
        return []
    return [t for t in tickets
            if card_holds_slot(os.path.join(cards_dir, t, "history.jsonl"), stale_minutes)]


def host_slots(stale_minutes: float | None = HOST_SLOT_STALE_MINUTES) -> dict:
    """Cards holding a slot, across every DECLARED board of this machine.

    `{"instances": {board: count, ...}, "tickets": {board: [id, ...]}, "total": N}`,
    keyed by the bare board name -- there is one foreman, so a board name is
    already unique on the machine.
    The counts are the ceiling's input; `tickets` is what lets a caller tell a
    card ENTERING the board from one already on it. `dispatch.sh` needs that
    distinction: a resume or a reviewer for a card that already holds a slot
    must not be refused for consuming a slot it is already counted in, or every
    fix-dispatch blocks itself. This is the host-wide
    ceiling's input: `HOST_MAX_CONCURRENT` bounds the total across every
    board sharing this machine's RAM and disk, the same way a single
    board's `MAX_CONCURRENT` bounds its own cards — see config.sh.

    EVERY DECLARED BOARD, not only the one this process serves.
    `HOST_MAX_CONCURRENT` is one number for one machine, and a board that
    counted only its own cards would let the machine carry every board's worth
    of builds against a ceiling written for one -- the same arithmetic the
    per-board ceiling already exists to stop, one level up.

    The roster comes from `declared_boards()`, i.e. `boards.toml`, not from
    listing `<home>/instances/`. Each declared board's runtime directory still
    keeps its name and its `cards/` subdirectory — that part of the layout
    survives — so the read itself is unchanged: no Linear, no `gh`, no agent
    registry, cheap enough to check before every dispatch.

    Tolerant about a board's RUNTIME, per its one caller (a tick deciding
    whether IT may dispatch): a declared board with no runtime directory yet,
    no `cards/` at all, a card with no `history.jsonl`, or a `history.jsonl`
    holding unparseable lines all read as zero cards and never raise. Each of
    those really is a board holding nothing.

    NOT tolerant about the ROSTER. A `boards.toml` that will not load raises
    `BoardsUnreadable` and this whole count refuses, never returning a number
    that is short by the boards it could not see. The two are opposite
    failures: an empty `cards/` is evidence, and an unreadable `boards.toml`
    is the absence of evidence.
    """
    result: dict = {"instances": {}, "tickets": {}, "total": 0}
    for board in declared_boards(FOREMAN_HOME):
        # Present at 0 rather than absent, for a board with no cards/ at
        # all: an absent key would be indistinguishable from a board this
        # process could not reach.
        holding = cards_holding_slots(
            os.path.join(FOREMAN_HOME, "instances", board, "cards"), stale_minutes)
        result["instances"][board] = len(holding)
        result["tickets"][board] = holding
        result["total"] += len(holding)
    return result


SERVED_STAMP = "last-served"
# The scheduled cleanup's stamp, and the SAME literal `bin/boardctl cleanup`
# removes. An operator who clears the stamp expects the next slice to run a
# cleanup, so a second spelling of the name here would leave them deleting a
# file nothing reads and waiting three days for the pass they just asked for.
CLEANUP_STAMP = "last-cleanup"


def _stamp_path(foreman_home: str, board: str, name: str) -> str:
    return os.path.join(foreman_home, "instances", board, name)


def write_stamp(foreman_home: str, board: str, name: str) -> None:
    """Stamp `instances/<board>/<name>` with now. Writes, returns nothing.

    Written through a temporary file in the same directory and `os.replace`,
    so a reader never sees half a timestamp. A torn stamp reads as no stamp at
    all, which is recoverable for both callers -- one unrotated pass for
    `last-served`, one early cleanup for `last-cleanup` -- but the whole file
    is 21 bytes and the atomic write costs two lines.

    The pid is in the temporary name because two boards' slices can run at
    once under one machine root, and a shared temporary path is a reader's
    torn stamp with extra steps.
    """
    directory = os.path.join(foreman_home, "instances", board)
    os.makedirs(directory, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime(CARD_LOG_STAMP)
    tmp = os.path.join(directory, f".{name}.{os.getpid()}")
    with open(tmp, "w") as fh:
        fh.write(stamp + "\n")
    os.replace(tmp, _stamp_path(foreman_home, board, name))


def read_stamp(foreman_home: str, board: str, name: str) -> datetime | None:
    """The `instances/<board>/<name>` stamp, or None if there is none to read.

    None covers every way the file can fail to answer: absent, unreadable, or
    holding something that is not a `CARD_LOG_STAMP` timestamp. Both callers
    read None as "never", and never as the direction that costs a turn rather
    than skips one -- a board sorts first for one pass, or a cleanup runs one
    slice early.
    """
    try:
        with open(_stamp_path(foreman_home, board, name)) as fh:
            text = fh.readline().strip()
    except OSError:
        return None
    return _parse_stamp(text)


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

    `write_stamp()` does the writing, and `last-cleanup` is written the same
    way. One stamp file is one mechanism, so an atomic write fixed for one of
    them is fixed for both.
    """
    write_stamp(foreman_home, board, SERVED_STAMP)


def _served_stamp(foreman_home: str, board: str) -> datetime | None:
    """The `last-served` stamp for `board`, or None if it has none to read."""
    return read_stamp(foreman_home, board, SERVED_STAMP)


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


# A cleanup agent is not a card, so it is dispatched under the ticket
# `cleanup` -- `dispatch.sh --ticket cleanup --role cleanup` names it
# `<BOARD_NAME_PREFIX>/cleanup/cleanup-<attempt>`. That is why the liveness
# check below can be `agents_for()` and not a second name rule.
CLEANUP_TICKET = "cleanup"


def cleanup_verdict(foreman_home: str, board: str, every_days: int,
                    agents: list[dict], host_max: int) -> str:
    """"" if `board` is due a scheduled cleanup, else the first reason it is not.

    WHEN THE TICK ASKS. At the END of a board's slice, after its cards have
    been handled. A cleanup pass takes a slot, and a slot spent on cleanup is
    a slot a card cannot have -- so asking first would let a board's own
    quality work displace the work it exists to do. Asking last means cleanup
    runs on capacity the cards did not need.

    WHEN THE STAMP IS WRITTEN. BEFORE the dispatch, never after. An agent that
    dies in its first minute, or that reads everything and honestly files
    nothing, writes no stamp of its own -- so a stamp written on success would
    leave the board due again on the very next tick, and a cleanup pass reads
    the whole codebase on the strongest model. Stamping first costs at most
    one skipped cycle; stamping last costs a cleanup every tick, forever.

    THE ORDER OF THE REASONS is the order of what they cost to establish, and
    the FIRST one that holds is the answer. `every_days` is a parsed integer,
    the stamp is one small file, the agent registry was already read by the
    caller, and the two slot counts walk every board on the machine.

    `agents` is `load_agents()`'s list, and the caller owes it the same None
    check every other reader here does: an unreadable registry reported as an
    empty list is a cleanup dispatched on top of a live one.

    `board` NAMES THE STAMP, and everything else here -- `CLEANUP_EVERY_DAYS`,
    `MAX_CONCURRENT` and the agent-name prefix `agents_for()`
    matches on -- is the contract config.sh resolved for $FOREMAN_INSTANCE. The
    two must be the same board, so `main()` refuses a call where they are not.
    """
    if every_days <= 0:
        return f"cleanup is off (every_days = {every_days})"
    stamp = read_stamp(foreman_home, board, CLEANUP_STAMP)
    if stamp is not None:
        next_due = stamp + timedelta(days=every_days)
        if datetime.now(timezone.utc) < next_due:
            return (f"last cleanup {stamp.strftime(CARD_LOG_STAMP)}, "
                    f"next due {next_due.strftime(CARD_LOG_STAMP)}")
    # `alive` already excludes a stopped row; `phase` is what separates an
    # agent still working from one that finished its turn and idles at `done`
    # with its pid intact. Both of those are a cleanup pass in progress -- a
    # turn-complete agent's card may still be landing -- and only a terminal
    # one is over.
    live = [a for a in agents_for(agents, CLEANUP_TICKET)
            if a["alive"] and a["phase"] != "terminal"]
    if live:
        return f"{live[-1]['name']} is {live[-1]['phase']}"
    # The TICKETS, not just the count. A cleanup agent is dispatched under the
    # ticket `cleanup`, so a finished pass keeps holding a slot through
    # `cards/cleanup/history.jsonl` until `sweep.sh cleanup` logs `released`
    # or HOST_SLOT_STALE_MINUTES expires. That read identically to a slot held
    # by real card work, so a board stalled on its own last cleanup could not
    # be diagnosed from the reason line -- which is the only line the operator
    # sees. The liveness check above has already answered "no cleanup agent is
    # running", so a `cleanup` slot reaching here is always a finished pass.
    holding = (host_slots().get("tickets") or {}).get(board) or []
    held = len(holding)
    if held >= MAX_CONCURRENT:
        reason = (f"{board} holds {held} of its {MAX_CONCURRENT} card "
                  f"{'slot' if MAX_CONCURRENT == 1 else 'slots'}")
        if CLEANUP_TICKET in holding:
            reason += (f"; cards/{CLEANUP_TICKET} is one of them -- a finished "
                       f"cleanup pass nothing has released, freed by "
                       f"`sweep.sh {CLEANUP_TICKET}`")
        return reason
    # The machine's ceiling last, and asked through the same function every
    # dispatch is weighed by: a cleanup agent eats the same RAM and disk as a
    # build, so it owes the other boards on this machine the same floors.
    return dispatch_verdict(board, host_max)


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


# What a rate-limited or over-capacity spawn leaves in its transcript. Claude
# Code writes the refusal as an assistant row marked `isApiErrorMessage`, with
# `error` naming its kind and text such as `API Error: 429 {... rate_limit_error
# ...}` or `Claude AI usage limit reached|<epoch>`. On 2026-09-16 every plan
# spawn on fable died this way for 11 hours, and each one was read as an
# ordinary failure. One list, so the patterns cannot drift between callers.
# Numbers carry word boundaries: a request id that happens to contain `429` is
# not a rate limit.
RATE_LIMIT_PATTERNS = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        r"rate[_ ]limit",
        r"\b429\b",
        r"overloaded",
        r"\b529\b",
        r"usage limit reached",
    )
)


def _api_error_text(row: dict) -> str | None:
    """The searchable text of an API error row, or None for any other row.

    Only a row the harness marked as an API error is read. An agent that writes
    "429" in its own reasoning, or runs a command that prints "rate limit", did
    not hit a limit itself, and reading its prose would retire a working model.
    """
    if not (row.get("isApiErrorMessage") or row.get("error")):
        return None
    parts = [str(row.get("error") or "")]
    content = (row.get("message") or {}).get("content")
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        parts.extend(str(b.get("text") or "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text")
    return " ".join(p for p in parts if p)


def _is_rate_limit(text: str) -> bool:
    return any(p.search(text) for p in RATE_LIMIT_PATTERNS)


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

    `rate_limited` says the model refused the spawn: an API error of the
    rate-limit or capacity kind, and the agent never ran a single tool.
    That is a fact about the model, not the ticket, and the tick answers it by
    falling back a tier. An agent that ran any tool did real work, before a
    limit or after one it waited out. Retrying it on a weaker model would hide
    a failure that may be the ticket's own, so it is not flagged.
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
    ran_tool = False
    rate_limit_error = None
    for r in rows:
        error_text = _api_error_text(r)
        if (error_text is not None and rate_limit_error is None
                and _is_rate_limit(error_text)):
            rate_limit_error = " ".join(error_text.split())[:400]
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
                ran_tool = True
                desc = (b.get("input") or {}).get("command") or json.dumps(b.get("input"))[:200]
                pending[b.get("id") or ""] = f"{b.get('name')}: {' '.join(str(desc).split())[:200]}"
            elif kind == "tool_result":
                pending.pop(b.get("tool_use_id") or "", None)
            elif kind == "text":
                last_text = b.get("text") or last_text

    unanswered = list(pending.values())
    if ran_tool:
        rate_limit_error = None
    return {
        "killed_mid_tool": bool(unanswered),
        "unanswered_tool": unanswered[-1] if unanswered else None,
        "last_text": " ".join(last_text.split())[-400:] if last_text else None,
        "rows": len(rows),
        "rate_limited": rate_limit_error is not None,
        "rate_limit_error": rate_limit_error,
    }


def spawned_model(entries: list[dict], name: str) -> str | None:
    """The model the newest spawn of agent `name` ran on, from history.

    The registry does not say which model an agent runs on, and after a
    fallback it is no longer the stage's first choice. The tick marks the model
    that was actually refused. Marking the first choice instead would stamp a
    model that was never tried. None for history written before `dispatch.sh`
    recorded the model.
    """
    for e in reversed(entries):
        ev = e.get("event") or {}
        if ev.get("action") == "spawn" and ev.get("name") == name:
            return ev.get("model") or None
    return None


# History entries that sit between two voids of a stage without ending a run of
# them: a void is followed by a fresh spawn or resume, and a rate-limit void is
# preceded by its fallback entry.
_STREAK_TRANSPARENT = {"spawn", "resume", "fallback"}


def environmental_streak(entries: list[dict]) -> dict | None:
    """The run of voids for one role at the tail of history, or None.

    A board that voids once is working as designed. A card that voids pass
    after pass is a machine or a model that needs an operator, and nothing else
    reports it: a void costs no attempt, so no budget ever runs out. On
    2026-09-16 plan voids ran for 11 hours before anyone looked.

    Entries of another role are skipped, and so are spawn, resume and fallback
    entries. Any other entry ends the run: a non-void action for the role, or a
    role-less one such as `released`, means the card moved or was let go.
    """
    role, count, since, last_reason = None, 0, None, None
    for e in reversed(entries):
        ev = e.get("event") or {}
        action = ev.get("action")
        if action in _STREAK_TRANSPARENT:
            continue
        if role is not None and ev.get("role") and ev.get("role") != role:
            continue
        if action != "void":
            break
        if role is None:
            role, last_reason = ev.get("role") or "", ev.get("reason")
        count += 1
        since = e.get("at")
    if not count:
        return None
    return {"role": role, "count": count, "since": since,
            "last_reason": last_reason}


BLOCKING = "blocking"
# `<round><slot>`, as dispatch.sh composes `--attempt <r> --slot <s>` and as
# each reviewer names its file. The leading digits are the round; whatever
# follows is the slot.
_ATTEMPT = re.compile(r"^(\d+)(.*)$")


def review_findings(path: str) -> list[dict] | None:
    """One review file's findings, or None because it could not be READ.

    The same rule `waitfor.reviews_state` waits on: a review has arrived only
    when the file parses AND is an object holding a `findings` list. A
    half-written file is not a review that found nothing, and reading one as
    an empty findings list merges a diff nobody finished reading.

    A findings entry that is not an object is dropped rather than raising --
    every reader below reaches straight for `.get`, and this is the parse
    boundary.
    """
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("findings"), list):
        return None
    return [f for f in doc["findings"] if isinstance(f, dict)]


def review_verdict(ticket: str, entries: list[dict], pr: dict | None,
                   agents: list[dict]) -> dict:
    """Where this card stands in review, as one named verdict.

    WHAT THIS EXISTS TO STOP. The tick used to read "round 1 blocked, the fix
    is pushed" as "dispatch round 2", because the only thing it could see was
    a round whose findings blocked. Review now runs ONCE: a blocking finding
    buys exactly one fix, and that fix merges on its CHECKS rather than on a
    second reviewer. `MAX_REVIEW_ROUNDS` stays in the contract as a ceiling
    and `LIMIT_MINIMUMS` still floors it at 1, so review cannot be disarmed --
    but one round is the design, and nothing here ever answers "review this
    again" once a fix has been pushed.

    The verdicts, and what each one licenses:

      unreviewed       no review agent was ever dispatched. Dispatch one.
      awaiting-review  the round is dispatched and its files are not all
                       readable yet. NOT "found nothing": see review_findings.
      head-moved       no blocking finding, but the head has moved past the sha
                       the round read, so nobody has reviewed what would merge.
                       Dispatch `next_round`, which MAX_REVIEW_ROUNDS bounds.
      needs-fix        a blocking finding, and no build resume after it.
                       Resume the build with the findings.
      fixing           resumed, and the fix is not pushed yet -- the head is
                       still the sha the reviewer read, and the build agent is
                       running. Wait.
      ref-unknown      resumed, and whether the fix was pushed cannot be
                       judged: the round recorded no ref, or the head could not
                       be read. Wait. Never a person's card -- see below.
      fix-unresolved   resumed, the round's ref IS recorded, the head still
                       equals it, and the build agent is no longer running.
                       `Needs Human`: the fix agent stopped without pushing
                       anything.
      awaiting-checks  the fix is pushed and its checks have not concluded.
      checks-failing   the fix is pushed and a required check failed.
      mergeable        no blocking finding at all, or the fix is pushed and
                       green -- the second case carries `merged_after_fix`,
                       which SKILL.md logs before it merges.

    `ref` is what makes "the fix was pushed" observable: `dispatch.sh` records
    the sha each reviewer was dispatched against, and a head that has moved
    past it is a commit that landed after the review. The round's LAST ref is
    the one that counts: a reviewer that died is re-dispatched, and by then the
    head may have moved, so one round carries several shas and the earliest of
    them is one the findings predate.

    A ROUND WITH NO REF, OR A HEAD NOBODY COULD READ, IS `ref-unknown`. Both
    used to read as `fix-unresolved`, which the tick turns into `Needs Human`
    with `board-failed` -- so a fix that was pushed and green was retired
    because no history written before this carried a `ref` at all, and one
    transient `gh pr list` failure (`pr.lookup_failed`, which has no
    headRefOid) retired another. This is the rule the build path already
    states for `pr.lookup_failed`: "I could not read it" and "it never moved"
    are not the same answer. So `fix-unresolved` requires a RECORDED ref that
    the head provably still equals, and everything else waits.

    `ticket` is a parameter because nothing else here names the card: the
    reviews live at `$BOARD_HOME/cards/<ticket>/reviews/<round><slot>.json`.
    """
    head = (pr or {}).get("headRefOid") or ""
    rounds: dict[int, list[tuple[int, str, str]]] = {}
    for index, entry in enumerate(entries):
        event = entry.get("event") or {}
        if event.get("action") != "spawn" or event.get("role") != "review":
            continue
        match = _ATTEMPT.match(str(event.get("attempt") or ""))
        if match:
            rounds.setdefault(int(match.group(1)), []).append(
                (index, match.group(2), str(event.get("ref") or ""))
            )
    state = {"verdict": "unreviewed", "round": 0, "blocking": 0,
             "ref": None, "head": head or None}
    if not rounds:
        state["reason"] = "no review agent has been dispatched for this card"
        return state

    # The highest round, not the last line: a spawn logged out of order still
    # belongs to the round its attempt names.
    rnd = max(rounds)
    spawned = rounds[rnd]
    # The LAST ref the round recorded, in file order. Taking the first one made
    # "the fix was pushed" true at a sha that landed BEFORE the findings were
    # written: a reviewer that died and was re-dispatched after the build pushed
    # carries a newer sha on its second spawn line, and against the first one a
    # fix agent that pushed nothing reached `mergeable`.
    ref = next((r for _, _, r in reversed(spawned) if r), "")
    state.update(round=rnd, ref=ref or None)

    # One reviewer SLOT is one review file, however many spawn lines name it. A
    # re-dispatched slot appears here twice, and reading `reviews/<round><slot>`
    # once per spawn line counted its single blocking finding twice -- and told
    # the reviewer count below that a round short of its reviewers was fully
    # dispatched.
    slots: list[str] = []
    for _, slot, _ in spawned:
        if slot not in slots:
            slots.append(slot)

    reviews = os.path.join(BOARD_HOME, "cards", ticket, "reviews")
    unread, blocking = [], 0
    for slot in slots:
        findings = review_findings(os.path.join(reviews, f"{rnd}{slot}.json"))
        if findings is None:
            unread.append(f"{rnd}{slot}")
            continue
        blocking += sum(1 for f in findings if f.get("severity") == BLOCKING)
    state["blocking"] = blocking
    if unread:
        state.update(verdict="awaiting-review",
                     reason=f"review {', '.join(unread)} has not been written yet")
        return state
    # A round the tick was interrupted part-way through dispatching has been
    # read in full and still not reviewed in full. Merging on it spends one
    # reviewer where the operator asked for REVIEWERS_PER_ROUND.
    if len(slots) < REVIEWERS_PER_ROUND:
        state.update(
            verdict="awaiting-review",
            reason=f"round {rnd} dispatched {len(slots)} of "
                   f"{REVIEWERS_PER_ROUND} reviewers",
        )
        return state

    # Did a commit land after this round was dispatched? Only a RECORDED ref
    # and a READABLE head can answer that. Either one missing is "unknown", and
    # unknown is never "no" -- both paths below turn on this.
    pushed = bool(head and ref and head != ref)

    if not blocking:
        # A clean round licensed a merge on its round number alone, so a head
        # the reviewer never read could merge: round 1 passes at sha A, a
        # required check fails, the build is resumed and pushes B, and B merges
        # unreviewed. Ask for a fresh round instead. This is what keeps
        # MAX_REVIEW_ROUNDS meaningful -- it now bounds the re-reviews a moving
        # head causes, and a card that reaches it with the head still moving is
        # the existing `Needs Human` exit.
        if pushed:
            state.update(
                verdict="head-moved", next_round=rnd + 1,
                reason=f"round {rnd} filed no blocking finding at {ref[:12]}, "
                       f"but the head is now {head[:12]}, which no reviewer has "
                       f"read; round {rnd + 1} has to read it",
            )
            return state
        state.update(verdict="mergeable",
                     reason=f"round {rnd} filed no blocking finding")
        return state

    # A build resumed after the round's last reviewer spawned is the fix. The
    # generic resume line `dispatch.sh` writes carries no role -- only the
    # agent's name, which ends `/build-<attempt>` -- so both spellings count,
    # and position in this append-only file orders them rather than the `at`
    # stamps, which are whole seconds and tie.
    after = max(index for index, _, _ in spawned)
    resumed = any(
        (e.get("event") or {}).get("action") == "resume"
        and ((e.get("event") or {}).get("role") == "build"
             or "/build-" in str((e.get("event") or {}).get("name") or ""))
        for e in entries[after + 1:]
    )
    if not resumed:
        state.update(verdict="needs-fix",
                     reason=f"round {rnd} filed {blocking} blocking "
                            f"{'finding' if blocking == 1 else 'findings'}")
        return state

    # "The fix cannot be judged" is its own answer, and it WAITS. Folding it
    # into `fix-unresolved` sent the card to `Needs Human` with `board-failed`
    # on evidence nobody gathered -- see this function's docstring for the two
    # ways that happens to a card whose fix is pushed and green.
    unknown = []
    if not ref:
        unknown.append(f"round {rnd} recorded no ref")
    if not head:
        unknown.append("the pull request head could not be read")
    if unknown:
        state.update(
            verdict="ref-unknown",
            reason=f"{' and '.join(unknown)}, so whether the fix for round "
                   f"{rnd} was pushed cannot be judged",
        )
        return state

    if not pushed:
        # The ref is recorded and the head still equals it: the fix really was
        # never pushed.
        running = any(a.get("role") == "build" and a.get("alive")
                      and a.get("phase") == "running" for a in agents)
        state.update(
            verdict="fixing" if running else "fix-unresolved",
            reason=f"the build was resumed for round {rnd} and the head is "
                   f"still {head[:12]}, the sha the round was dispatched "
                   f"against; the build agent is "
                   + ("running" if running else "no longer running"),
        )
        return state

    checks = (pr or {}).get("checks") or {}
    if checks.get("passing"):
        state.update(verdict="mergeable", merged_after_fix=True,
                     reason=f"round {rnd} blocked, the fix at {head[:12]} is "
                            f"pushed and every required check passed")
        return state
    if checks.get("failing"):
        state.update(verdict="checks-failing",
                     reason=f"the fix at {head[:12]} failed "
                            f"{', '.join(checks['failing'])}")
        return state
    # Pending, empty, missing a required check, or a rollup that could not be
    # read: none of those is an answer, and only `passing` merges.
    state.update(verdict="awaiting-checks",
                 reason=f"the fix at {head[:12]} is pushed and its checks have "
                        f"not concluded")
    return state


def reconcile(ticket: str, agents: list[dict]) -> dict:
    pr = pr_for(ticket)
    # Composed from config.sh's BOARD_WORKTREE_PREFIX, as config.sh:worktree_path
    # composes it: dispatch.sh cuts the directory and sweep.sh reaps it, and a
    # path of another shape here reports "no worktree" for every live build.
    worktree = os.path.join(
        REPO, ".claude", "worktrees", f"{BOARD_WORKTREE_PREFIX}-{ticket}"
    )
    entries = history(ticket)
    mine = agents_for(agents, ticket)
    # Diagnose only the agents that have stopped. A running agent's transcript
    # always has an outstanding tool call — it is mid-turn — so asking this of
    # one would report every healthy build as killed.
    for a in mine:
        a["death"] = death_report(a["transcript"]) if a["phase"] == "terminal" else None
        a["model"] = spawned_model(entries, a["name"])
    record = {
        "ticket": ticket,
        "history": entries,
        "build_attempts": build_attempts(entries),
        "plan_rounds": plan_rounds(entries),
        "plan_attempts": plan_attempts(entries),
        "environmental_streak": environmental_streak(entries),
        "agents": mine,
        "worktree": worktree if os.path.isdir(worktree) else None,
        "review": review_verdict(ticket, entries, pr, mine),
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


def _host_max() -> int:
    """`HOST_MAX_CONCURRENT` from the environment, 4 when it cannot be read.

    The machine ceiling reaches this process through the environment and not
    through the contract: it is a fact about the machine, and `dispatch.sh`
    passes config.sh's value in on the call. The default is config.sh's own,
    so a caller that forgets to pass it weighs the same number the shell would
    have used.
    """
    try:
        return int(os.environ.get("HOST_MAX_CONCURRENT", "4"))
    except ValueError:
        return 4


def _is_declared(board: str, mode: str) -> bool:
    """Is `board` in this home's `boards.toml`? Says why on stderr when not.

    Every mode that names a board owes this check, for the reason `--served`
    gives: acting on a typo creates `instances/<typo>/`, reports success, and
    leaves the board the operator meant untouched -- never stamped, never
    cleaned -- with nothing saying so.
    """
    if board in declared_boards(FOREMAN_HOME):
        return True
    print(f"reconcile: {mode}: no board named {board} in "
          f"{os.path.join(FOREMAN_HOME, 'boards.toml')}", file=sys.stderr)
    return False


# =============================================================================
# --overview: one JSON picture of this machine, for a reader that is not the
# tick.
#
# WHY IT LIVES HERE. Three questions -- is anything stuck, what is happening
# now, is the machine healthy -- are answered by evidence this file already
# gathers for the tick: the agent registry through $HARNESS_SH, the declared
# roster through bin/boards.py, card position from each card's history.jsonl,
# the slot counts, the stamps, the halt files. A second reader deriving them
# again is the drift this file exists to prevent: bin/dashboard.py used to
# parse boards.toml with its own tomllib and carry its own copy of card state,
# and it kept answering confidently while the layout moved underneath it.
#
# LOCAL FILES ONLY, unless --with-remote. A dashboard polls; `gh` is
# rate-limited and slow, and this file's `gh` paths (pr_for, deploy_verdict,
# main_ci_state) are twelve invocation sites that must not run on a 30-second
# refresh. `--with-remote` adds main's CI for a caller that asks deliberately
# -- the tick sampling once a pass, not a browser.
#
# HARNESS-AGNOSTIC, because the operator watching this does not care which CLI
# is running the tick and may not be the person who chose it. Agents come from
# load_agents(), which is $HARNESS_SH -- the registry that merges every
# harness. Nothing here reads an adapter's own directory.


# THE ROOT EVERY FOREMAN AGENT NAME STARTS WITH, derived from the tick's own
# name rather than spelled again. config.sh composes `foreman/tick` and
# `foreman/<board>/<ticket>/<role>-<attempt>` from one root and calls itself
# "the one place a name's shape is decided"; taking the root off the tick's
# name keeps that true here.
#
# It is needed because THE REGISTRY IS THE MACHINE'S, not foreman's. Measured
# 2026-09-20: --overview on a developer's laptop listed that person's own
# Claude Code sessions as agents, because `$HARNESS_SH list` returns every
# session the harness knows about. A dashboard that shows an operator their
# own editor sessions next to a build agent is worse than one that shows
# nothing: it invites them to stop the wrong thing.
AGENT_ROOT = TICK_AGENT_NAME.split("/", 1)[0] + "/"


def _is_foreman_agent(agent: dict) -> bool:
    return (agent.get("name") or "").startswith(AGENT_ROOT)


def _agent_view(agent: dict) -> dict:
    """One registry row, reduced to what a watcher needs.

    PHASE, not liveness: a background agent idles at `done` with its pid
    intact when its turn ends, so "the process is up" reports finished work as
    still running. The same table the tick reads.
    """
    name = agent.get("name") or ""
    started = agent.get("startedAt")
    return {
        "name": name,
        "board": _board_of_agent(name),
        "ticket": _ticket_of_agent(name),
        "role": _role_of_agent(name),
        "phase": PHASE.get(agent.get("state"), "unknown"),
        "state": agent.get("state"),
        "harness": agent.get("harness") or "",
        "started_at": started,
        "age_seconds": _age_seconds(started),
    }


def _age_seconds(started_ms: object) -> float | None:
    """Seconds since an `startedAt` in epoch MILLIseconds, or None.

    The unit is the registry's, not this file's -- detached.sh's record spec
    names it -- so the conversion is here rather than in every caller.
    """
    try:
        return max(0.0, time.time() - float(started_ms) / 1000.0)
    except (TypeError, ValueError):
        return None


# `foreman/<board>/<ticket>/<role>-<attempt>`, and `foreman/tick`. Split rather
# than matched with a pattern: config.sh composes these names and this file
# already refuses to respell the shape, so it only ever takes them apart.
def _name_parts(name: str) -> list[str]:
    return [part for part in name.split("/") if part]


def _board_of_agent(name: str) -> str:
    parts = _name_parts(name)
    return parts[1] if len(parts) >= 3 else ""


def _ticket_of_agent(name: str) -> str:
    parts = _name_parts(name)
    return parts[2] if len(parts) >= 3 else ""


def _role_of_agent(name: str) -> str:
    """`build` from `.../build-2`, or `tick` for the tick itself."""
    parts = _name_parts(name)
    if len(parts) == 2 and parts[1] == "tick":
        return "tick"
    if len(parts) < 4:
        return ""
    # An attempt suffix is `-<n>`, and a review's is `-1a` / `-2aa`, so the
    # role is everything before the last hyphen.
    role, _, _ = parts[3].rpartition("-")
    return role or parts[3]


def _tick_view(agents: list[dict]) -> dict:
    """The tick's own row: is one running, how old, how long since it moved.

    The NEWEST row of that name, matching supervise.sh's own rule -- a stopped
    corpse with a later startedAt must not masquerade as the live one, so
    liveness is taken from the newest row that is not stopped when there is
    one.
    """
    mine = [a for a in agents if (a.get("name") or "") == TICK_AGENT_NAME]
    live = [a for a in mine if a.get("state") != "stopped"]
    row = max(live or mine, key=lambda a: a.get("startedAt") or 0, default=None)
    if row is None:
        return {"running": False, "name": TICK_AGENT_NAME}
    return {
        "running": row.get("state") != "stopped",
        "name": TICK_AGENT_NAME,
        "id": row.get("id"),
        "state": row.get("state"),
        "phase": PHASE.get(row.get("state"), "unknown"),
        "age_seconds": _age_seconds(row.get("startedAt")),
        "live_count": len(live),
    }


def _rate_limit_view() -> list[dict]:
    """Every rate-limit stamp under `$FOREMAN_HOME/rate-limits/`.

    Read, never judged: skills/board/fallback.py owns the walk and this only
    reports what it wrote. A stamp holds the moment the limit EXPIRES, so one
    in the past is history and `expired` says which.

    The filename is the model, percent-encoded by fallback.py so a name
    holding `/` or `:` cannot escape the directory -- decoded back here rather
    than shown raw, because `claude%3Aopus` is not what the operator called it.
    """
    out = []
    directory = os.path.join(FOREMAN_HOME, fallback.STAMP_DIR)
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    now = datetime.now(timezone.utc)
    for name in names:
        try:
            with open(os.path.join(directory, name)) as fh:
                text = fh.read().strip()
        except OSError:
            continue
        until = _parse_stamp(text)
        out.append({
            "model": unquote(name),
            "until": text,
            "expired": until is None or until <= now,
            "seconds_left": (until - now).total_seconds() if until and until > now else 0,
        })
    return out


def _disk_free_mb(path: str) -> float | None:
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    return st.f_bavail * st.f_frsize / (1024 * 1024)


def _memory_free_mb() -> float | None:
    """Free memory, from /proc/meminfo's MemAvailable.

    None where there is no /proc -- macOS -- rather than a guess. preflight.py
    is what GATES on memory; this only reports, so a platform it cannot read
    is a blank field and never a refusal.
    """
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return float(line.split()[1]) / 1024
    except (OSError, IndexError, ValueError):
        return None
    return None


def _machine_view() -> dict:
    return {
        "foreman_home": FOREMAN_HOME,
        "disk_free_mb": _disk_free_mb(FOREMAN_HOME),
        "memory_free_mb": _memory_free_mb(),
        "host_max_concurrent": _host_max(),
        "rate_limits": _rate_limit_view(),
        "linear_key": os.path.exists(os.path.join(FOREMAN_HOME, "linear.key")),
        "mcp_config": os.path.exists(os.path.join(FOREMAN_HOME, "mcp.json")),
    }


def _card_view(board: str, ticket: str, agents: list[dict], now: datetime) -> dict:
    """One card's position, from its own history.jsonl and the registry.

    The history is a CACHE -- "delete it and the next tick must still
    reconstruct every card's position" -- so nothing here refuses when it
    cannot be read. A card with no readable history and no live agent is a
    card holding nothing, which is what an empty view says.
    """
    home = os.path.join(FOREMAN_HOME, "instances", board, "cards", ticket)
    entries = _read_jsonl(os.path.join(home, "history.jsonl"))
    last = entries[-1] if entries else None
    stamp = _entry_stamp(last) if last else None
    mine = [a for a in _board_agents(agents, board) if _ticket_of_agent(a["name"]) == ticket]
    return {
        "ticket": ticket,
        "board": board,
        "last_action": (last or {}).get("event", {}).get("action"),
        "last_at": last.get("at") if last else None,
        "idle_seconds": (now - stamp).total_seconds() if stamp else None,
        "holds_slot": card_holds_slot(os.path.join(home, "history.jsonl"),
                                      HOST_SLOT_STALE_MINUTES),
        "agents": [a for a in mine],
    }


def _board_agents(agents: list[dict], board: str) -> list[dict]:
    return [a for a in agents if a.get("board") == board]


# How long a card may sit on its last logged action before --overview calls it
# stuck. Not a gate -- nothing refuses on it -- so it is a reporting threshold
# and lives here rather than in a target's board.toml.
#
# Four hours because a build plus a review round is measured in tens of
# minutes and the tick walks every board a slice at a time: a card quiet for
# four hours is not slow, it is waiting for somebody.
STUCK_CARD_SECONDS = 4 * 3600

# How long the tick may go without a new turn before it is called stale.
# supervise.sh already replaces a tick that is dead or wedged; this only
# reports, and it is deliberately looser than TICK_DEAD_MINUTES so a watchdog
# mid-replacement does not read as a problem.
STALE_TICK_SECONDS = 90 * 60


def _problems(tick: dict, boards: list[dict], machine: dict) -> list[dict]:
    """The "is anything stuck" band: everything wrong, worst first.

    EVERY ENTRY NAMES WHAT TO DO. A dashboard that says "something is wrong"
    and stops is a dashboard that gets checked once. The fix is prose, not a
    button: this file reports and the operator acts, the same separation
    supervise.sh keeps between the watchdog and the dispatcher.
    """
    out = []
    if not tick.get("running"):
        out.append({"severity": "critical", "kind": "tick-down",
                    "detail": "no tick is running; no board is being walked",
                    "fix": "skills/board/supervise.sh"})
    elif (tick.get("age_seconds") or 0) > STALE_TICK_SECONDS:
        out.append({"severity": "warning", "kind": "tick-stale",
                    "detail": f"the tick has been up {_ago(tick['age_seconds'])} "
                              "without being recycled",
                    "fix": "skills/board/supervise.sh --restart"})
    if (tick.get("live_count") or 0) > 1:
        out.append({"severity": "critical", "kind": "tick-doubled",
                    "detail": f"{tick['live_count']} ticks are live; two ticks "
                              "dispatch against one machine ceiling",
                    "fix": "skills/board/supervise.sh --restart"})
    if not machine.get("linear_key"):
        out.append({"severity": "critical", "kind": "no-linear-key",
                    "detail": "no linear.key; the tick cannot read or move a card",
                    "fix": "install -m 600 <key> $FOREMAN_HOME/linear.key"})
    if not machine.get("mcp_config"):
        out.append({"severity": "critical", "kind": "no-mcp-config",
                    "detail": "no mcp.json; the tick reads a board and then has "
                              "no way to move a card",
                    "fix": "cp <linear mcp config> $FOREMAN_HOME/mcp.json"})
    for limit in machine.get("rate_limits", []):
        if not limit["expired"]:
            out.append({"severity": "info", "kind": "rate-limited",
                        "detail": f"{limit['model']} is rate-limited for another "
                                  f"{_ago(limit['seconds_left'])}; stages below it "
                                  "carry the work",
                        "fix": ""})
    for board in boards:
        if board.get("halted"):
            out.append({"severity": "warning", "kind": "board-halted",
                        "detail": f"{board['name']} is halted and dispatches nothing",
                        "fix": f"bin/boardctl resume {board['name']}"})
        for card in board.get("cards", []):
            idle = card.get("idle_seconds")
            if card.get("holds_slot") and idle and idle > STUCK_CARD_SECONDS:
                out.append({"severity": "warning", "kind": "card-stuck",
                            "detail": f"{board['name']}/{card['ticket']} has held a "
                                      f"slot for {_ago(idle)} since "
                                      f"{card.get('last_action') or 'nothing'}",
                            "fix": f"skills/board/sweep.sh {card['ticket']}"})
        for agent in board.get("agents", []):
            if agent.get("phase") == "blocked":
                out.append({"severity": "warning", "kind": "agent-blocked",
                            "detail": f"{agent['name']} is blocked, waiting on a "
                                      "prompt nobody will answer",
                            "fix": f"\"$HARNESS_SH\" stop {agent['name']}"})
    rank = {"critical": 0, "warning": 1, "info": 2}
    out.sort(key=lambda p: rank.get(p["severity"], 3))
    return out


def _ago(seconds: float | None) -> str:
    """A duration an operator reads at a glance. Never a bare number of seconds
    past a minute: the dashboard's whole job is to be understood without
    arithmetic."""
    if seconds is None:
        return "?"
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"
    return f"{seconds // 86400}d{(seconds % 86400) // 3600:02d}h"


def overview(with_remote: bool = False) -> dict:
    """The whole machine, as one JSON object.

    Every field is re-derived here and nothing is cached: this file's own rule
    ("Nothing here is authoritative on its own") applies to the picture as
    much as to a card.

    TOLERANT, because a watcher that refuses tells the operator less than one
    that reports what it could reach.

    The roster is caught rather than reported, and the distinction is worth
    stating: a boards.toml that will not parse has ALREADY stopped this
    process, because config.sh loads the same file through the same bin/
    boards.py before main() runs, and boards.py validates every board before
    answering about one. So `roster_error` is not the primary path -- it
    guards the narrow window where the file changes between that load and this
    listing. What it buys is that the window produces a picture saying so
    instead of a traceback, which is the whole contract this function has with
    the page: bin/dashboard.py renders a failed --overview as a problem, and a
    crash would render as nothing at all.
    """
    now = datetime.now(timezone.utc)
    agents_raw = load_agents()
    registry_ok = agents_raw is not None
    mine = [a for a in (agents_raw or []) if _is_foreman_agent(a)]
    agents = [_agent_view(a) for a in mine]
    tick = _tick_view(mine)
    machine = _machine_view()

    boards: list[dict] = []
    roster_error = ""
    try:
        names = declared_boards(FOREMAN_HOME)
    except BoardsUnreadable as exc:
        names, roster_error = [], str(exc)
    slots = {}
    try:
        slots = host_slots().get("instances") or {}
    except BoardsUnreadable:
        pass
    priorities = {}
    try:
        priorities = board_priorities(FOREMAN_HOME)
    except BoardsUnreadable:
        pass

    for name in names:
        cards_dir = os.path.join(FOREMAN_HOME, "instances", name, "cards")
        try:
            tickets = sorted(t for t in os.listdir(cards_dir)
                             if os.path.isdir(os.path.join(cards_dir, t)))
        except OSError:
            tickets = []
        board_agent_rows = _board_agents(agents, name)
        cards = [_card_view(name, t, agents, now) for t in tickets]
        served = read_stamp(FOREMAN_HOME, name, SERVED_STAMP)
        boards.append({
            "name": name,
            "halted": board_is_halted(FOREMAN_HOME, name),
            "priority": priorities.get(name),
            "slots_held": slots.get(name, 0),
            "last_served": served.strftime(CARD_LOG_STAMP) if served else None,
            "last_served_seconds": (now - served).total_seconds() if served else None,
            "agents": board_agent_rows,
            # The cards worth showing: one holding a slot is in flight, and one
            # with a live agent is being worked. Every other directory under
            # cards/ is a finished card's history, which is what the operator
            # said they did not want to read.
            "cards": [c for c in cards
                      if c["holds_slot"] or c["agents"]],
            "cards_total": len(cards),
        })

    picture = {
        "at": now.strftime(CARD_LOG_STAMP),
        "tick": tick,
        "machine": machine,
        "boards": boards,
        "agents": agents,
        "registry_ok": registry_ok,
        "roster_error": roster_error,
        "inbox": _inbox_view(),
    }
    if not registry_ok:
        # NOT an empty agent list. load_agents() returns None when the registry
        # could not be read, and "no agents are running" is the one answer that
        # must never stand in for "I could not look" -- the same distinction
        # load_agents' own docstring defends for the tick.
        picture["problems"] = [{
            "severity": "critical", "kind": "registry-unreadable",
            "detail": "the agent registry could not be read; nothing here knows "
                      "what is running",
            "fix": '"$HARNESS_SH" list',
        }]
        return picture
    problems = _problems(tick, boards, machine)
    if roster_error:
        problems.insert(0, {"severity": "critical", "kind": "roster-unreadable",
                            "detail": roster_error, "fix": "bin/boardctl list"})
    picture["problems"] = problems
    if with_remote:
        # The `gh` half, for a caller that asked for it. Never on the poll path:
        # main_ci_state shells out to gh, which is rate-limited, and a browser
        # refreshing every 30 seconds would spend that budget on nobody.
        picture["main_ci"] = main_ci_state()
    return picture


# THE TICK'S INBOX. One message per file under `$FOREMAN_HOME/inbox/`, written
# by anyone -- bin/dashboard.py's message box today -- and read by the tick at
# the top of each pass.
#
# A FILE AND NOT A SOCKET, for two reasons. The tick has no live process to
# write to for most of its existence: on Codex and OpenCode it is a detached
# wrapper running `<cli> run` in a loop, so between passes there is nothing but
# a sleep, and during a pass stdin is deliberately /dev/null -- harness/
# detached.sh records `codex exec` sitting 180 seconds waiting for an EOF that
# never comes. And a message held in a process dies with it: the tick is
# replaced on a schedule (TICK_MAX_AGE_HOURS) and by every restart, so a
# channel into the process would lose exactly the messages sent while it was
# being recycled. A file survives all of that, which is the same reason every
# other thing foreman remembers is a file.
INBOX_DIR = "inbox"
INBOX_DONE = "done"


def _inbox_view() -> dict:
    """What is waiting for the tick, and what it has already answered.

    Names only, never bodies: the picture is polled every few seconds by a
    browser, and a message is prose an operator typed -- it belongs on the
    page that fetches one, not in every refresh of the summary.
    """
    root = os.path.join(FOREMAN_HOME, INBOX_DIR)
    def _names(path: str) -> list[str]:
        try:
            return sorted(n for n in os.listdir(path)
                          if os.path.isfile(os.path.join(path, n)))
        except OSError:
            return []
    return {
        "waiting": _names(root),
        "done_count": len(_names(os.path.join(root, INBOX_DONE))),
    }


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: reconcile.py <TICKET> [TICKET...]\n"
              "       reconcile.py --main-ci [BRANCH]\n"
              "       reconcile.py --host-slots\n"
              "       reconcile.py --board-order\n"
              "       reconcile.py --overview [--with-remote]\n"
              "       reconcile.py --served <board>\n"
              "       reconcile.py --may-dispatch <board>\n"
              "       reconcile.py --cleanup-due <board>\n"
              "       reconcile.py --cleanup-since <board>\n"
              "       reconcile.py --cleanup-started <board>", file=sys.stderr)
        return 2
    if argv[0] == "--overview":
        # LOCAL FILES ONLY unless asked otherwise -- see overview()'s own note.
        # A browser polls this; `gh` is rate-limited and must not be on that
        # path.
        rest = argv[1:]
        remote = "--with-remote" in rest
        unknown = [a for a in rest if a != "--with-remote"]
        if unknown:
            print(f"reconcile: --overview takes only --with-remote, got "
                  f"{' '.join(unknown)}", file=sys.stderr)
            return 2
        json.dump(overview(with_remote=remote), sys.stdout, indent=2)
        print()
        return 0
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
        host_max = _host_max()
        # The BARE board name, as the tick and the operator say it. There is
        # one foreman, so that name is already what `--host-slots` keys by and
        # there is no second shape for a copy to drift from.
        verdict = dispatch_verdict(argv[1], host_max)
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
        # Refuse an undeclared board rather than create
        # `instances/<typo>/last-served` and report success. A stamp nothing
        # ever reads means the board the operator meant is still never served,
        # and the order still starves it -- silently, which is the failure this
        # whole mode removes.
        if not _is_declared(argv[1], "--served"):
            return 2
        mark_board_served(FOREMAN_HOME, argv[1])
        return 0
    if argv[0] in ("--cleanup-due", "--cleanup-since", "--cleanup-started"):
        # Three questions about one stamp, `instances/<board>/last-cleanup`.
        # They name their board for the same reason `--served` does -- a stale
        # FOREMAN_INSTANCE is this skill's oldest bug shape -- but everything
        # ELSE they read is the contract config.sh resolved for
        # $FOREMAN_INSTANCE: `CLEANUP_EVERY_DAYS`, `MAX_CONCURRENT` and this
        # board's agents. The tick exports `FOREMAN_INSTANCE=<board>` for the
        # whole slice, so the two are the same board; a slice that asks about
        # its neighbour would be weighing its own cadence against another
        # board's stamp.
        mode = argv[0]
        if len(argv) < 2:
            print(f"usage: reconcile.py {mode} <board>", file=sys.stderr)
            return 2
        board = argv[1]
        if not _is_declared(board, mode):
            return 2
        # Declared is not enough: it has to be the board THIS process resolved.
        # Answering about a neighbour weighs one board's stamp against another
        # board's cadence, ceiling and agents, and `--cleanup-started` stamps
        # the neighbour -- skipping the cleanup it was owed, silently, for a
        # whole `every_days`. A stale FOREMAN_INSTANCE is this skill's oldest
        # bug shape, so both names go in the refusal.
        if board != INSTANCE:
            print(f"reconcile: {mode}: this process resolved the contract for "
                  f"board {INSTANCE}, so it cannot answer for {board}; run it "
                  f"with FOREMAN_INSTANCE={board}", file=sys.stderr)
            return 2
        if mode == "--cleanup-started":
            # Written BEFORE the dispatch, never after -- cleanup_verdict()
            # says why. Prints nothing: the tick has nothing to decide on it.
            write_stamp(FOREMAN_HOME, board, CLEANUP_STAMP)
            return 0
        if mode == "--cleanup-since":
            # What `brief.py cleanup --since` hands the agent as the start of
            # the window it reads. `never` for a board that has never run one,
            # which is every board until its first pass: the agent then reads
            # everything, which is the right answer for a first run.
            stamp = read_stamp(FOREMAN_HOME, board, CLEANUP_STAMP)
            print(stamp.strftime(CARD_LOG_STAMP) if stamp else "never")
            return 0
        agents = load_agents()
        if agents is None:
            # The same refusal the card path makes below, for the same reason:
            # an unreadable registry reported as "no agents" dispatches a
            # cleanup pass on top of the one already running.
            print("reconcile: could not read the agent registry; refusing to "
                  "report a cleanup as due", file=sys.stderr)
            return 3
        verdict = cleanup_verdict(FOREMAN_HOME, board, CLEANUP_EVERY_DAYS,
                                  agents, _host_max())
        print(verdict or "due")
        return 1 if verdict else 0
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
        json.dump(host_slots(), sys.stdout, indent=2)
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
    try:
        sys.exit(main(sys.argv[1:]))
    except BoardsUnreadable as exc:
        # Caught here rather than inside each mode, because every mode that
        # reads a roster fails the same way and must exit the same way:
        # non-zero, with the installation and boards.py's own message named,
        # and NO count on stdout. `--host-slots` and `--may-dispatch` are the
        # two that feed the machine ceiling, and dispatch.sh refuses to
        # dispatch when either of them exits non-zero.
        print(f"reconcile: {exc}", file=sys.stderr)
        sys.exit(1)
