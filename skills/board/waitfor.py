#!/usr/bin/env python3
"""Block until work the tick just started has finished, or a timeout expires.

    waitfor.py reviews --ticket PRA-28 --round 1 --slots a,b [--timeout 300]
    waitfor.py checks  --pr 136                              [--timeout 900]
    waitfor.py deploy  --sha <merge-sha>                     [--timeout 600]
    waitfor.py agents  --ticket PRA-28 --role review --attempt 1 [--timeout 300]

Exit 0 when the condition holds, 1 on timeout, 3 when the condition is settled
and did NOT hold. Progress goes to stderr so a long wait is visible; the final
JSON verdict goes to stdout.

THREE OUTCOMES, NOT TWO. `satisfied` used to be every `done`, so a deploy that
ran and FAILED came back `{"satisfied": true}` with a verdict of
`verified: false` — exit 0, the condition reported as holding, and the one state
that means production is broken indistinguishable from the one that means it is
live. A condition that can never hold now ends the wait as its own outcome, with
a name the caller can report: `{"satisfied": false, "outcome": "deploy-failed"}`.

WHY 3 AND NOT 2. Exit 2 is argparse's own code for a usage error, and this file
returns it for an unusable invocation too. Both of those print NOTHING on
stdout, so a settled-and-failed code of 2 would let a mistyped command — an
empty shell variable that got word-split away is enough — read as "the deploy
failed", reported to the operator as a broken production with a run URL that
does not exist. Every exit this file owns is: 0 satisfied, 1 budget expired, 3 settled
and unsatisfied, 2 you called it wrong. Only 0, 1 and 3 print a verdict.

WHY THIS EXISTS. A tick used to end the instant it dispatched something, so a
review that finished ninety seconds later sat untouched until the next fire, and
a card walking from build to deployed cost five ticks that were almost entirely
idle. Waiting inside the tick collapses that into one.

Waiting is only ever an optimisation. A tick killed mid-wait loses nothing: the
next one re-derives the same picture from Linear, gh and git and carries on. So
every timeout here is a *budget*, not a deadline that must be met — on expiry the
caller reports what it saw and ends the tick normally.

Conditions are re-derived from the outside world on every poll, never cached.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Reuse reconcile's readers rather than restating them. A second copy of
# "which checks are required" or "what counts as a deploy" is a copy that
# eventually disagrees with the one the tick actually reasons over.
import reconcile  # noqa: E402

POLL_SECONDS = 10


def note(msg: str) -> None:
    print(f"waitfor: {msg}", file=sys.stderr, flush=True)


def review_paths(ticket: str, rnd: str, slots: list[str]) -> list[str]:
    base = os.path.join(reconcile.BOARD_HOME, "cards", ticket, "reviews")
    return [os.path.join(base, f"{rnd}{s}.json") for s in slots]


def reviews_state(paths: list[str]) -> dict:
    """A review counts as arrived only when it parses and has a findings list.

    A half-written file is not a finished review, and treating one as "found
    nothing" would merge a diff nobody actually finished reading.
    """
    ready, waiting, malformed = [], [], []
    for p in paths:
        if not os.path.exists(p):
            waiting.append(p)
            continue
        try:
            with open(p) as fh:
                doc = json.load(fh)
            # `doc.get` raises AttributeError when the file parses as valid JSON
            # that is not an object — `[]`, a bare string, `null`. That crashed
            # the wait instead of reporting a malformed review.
            if isinstance(doc, dict) and isinstance(doc.get("findings"), list):
                ready.append(p)
            else:
                malformed.append(p)
        except (OSError, json.JSONDecodeError):
            # Could still be mid-write; keep waiting rather than judging it.
            waiting.append(p)
    return {"ready": ready, "waiting": waiting, "malformed": malformed,
            "done": not waiting}


def checks_state(pr: int) -> dict:
    prs = reconcile.run_json(
        ["gh", "pr", "view", str(pr), "--json",
         "state,headRefOid,mergeStateStatus,statusCheckRollup"],
        cwd=reconcile.REPO,
    )
    if not prs:
        return {"done": False, "reason": "could not read the pull request"}
    checks = reconcile.check_rollup(prs)
    # "Concluded" is the condition, not "green". A failing check is an answer,
    # and the tick must act on it now rather than keep waiting for it to improve.
    return {
        "done": not checks["pending"] and not checks["empty"],
        "checks": checks,
        "head": prs.get("headRefOid"),
        "mergeStateStatus": prs.get("mergeStateStatus"),
    }


def deploy_state(sha: str) -> dict:
    """Wait until this commit is deployed, or until it provably cannot be.

    This used to stop as soon as the commit's OWN run concluded without
    deploying — which is exactly the superseded-merge case reconcile's
    descendant fallback exists for. A merge overtaken minutes later always
    stands down, so waiting quit at the moment the answer was still coming.
    reconcile.deploy_verdict already knows how to see a descendant's deploy;
    the only reason to stop early was a reason string that predated it.

    So: keep waiting whenever the commit is on main and unverified. If it is on
    main, a later deploy of a descendant will verify it, and the caller's budget
    is what bounds the wait — not a guess about which reason strings are final.

    What stops the wait is `terminal` on the verdict, and `done` is reserved for
    the one outcome that means the commit is live. A deploy that ran and BROKE is
    neither: `skipped` is the stand-down this waits through, `failure` is
    the deploy script failing on the deploy host, and reporting the second as satisfied
    said "deployed" about a production that is broken. reconcile now sees that on
    a DESCENDANT's run too, which is where it always actually appears — the
    overtaken merge's own run stands down, and the failure belongs to whoever
    overtook it.
    """
    verdict = reconcile.deploy_verdict(sha)
    if verdict.get("verified"):
        return {"done": True, "verdict": verdict}
    if verdict.get("terminal"):
        return {"stop": True, "outcome": verdict.get("outcome") or "not-deployed",
                "verdict": verdict,
                "note": f"{verdict.get('reason')}; waiting will not change it"}
    on_main = reconcile.commit_on_main(sha)
    if on_main is None:
        # git could not answer. Not the same as "not on main", and stopping on
        # it would report a merge whose deploy is in flight as one nothing will
        # ever carry.
        return {"done": False, "verdict": verdict,
                "note": "could not tell whether the commit is on main"}
    if not on_main:
        # Not on main and not deployed: nothing is coming. Stop — but not as
        # `done`, because the commit is not deployed and never was.
        return {"stop": True, "outcome": "not-on-main", "verdict": verdict,
                "note": "commit is not on main; no deploy will carry it"}
    return {"done": False, "verdict": verdict}


def agents_state(ticket: str, role: str, attempt: str) -> dict:
    registry = reconcile.load_agents()
    if registry is None:
        # load_agents returns None when the registry could not be READ — a
        # `claude agents` that exited non-zero, timed out, or emitted non-JSON.
        # Passing that to agents_for iterates None and kills the wait with a
        # traceback: no JSON on stdout, and the tick parsing `{"satisfied": …}`
        # gets a stack trace instead. "I could not tell" is not "the agent
        # finished", so keep polling and let the caller's budget bound it.
        return {"done": False, "reason": "could not read the agent registry"}
    agents = reconcile.agents_for(registry, ticket)
    want = [a for a in agents
            if a["role"] == role and str(a["attempt"]).startswith(str(attempt))
            and a["current"]]
    if not want:
        return {"done": False, "reason": f"no current {role} agent for {ticket}"}
    running = [a["name"] for a in want if a["phase"] == "running"]
    return {"done": not running, "running": running,
            "phases": {a["name"]: a["phase"] for a in want}}


def emit(satisfied: bool, outcome: str, label: str, state: dict, code: int) -> int:
    json.dump({"satisfied": satisfied, "outcome": outcome,
               "label": label, "state": state}, sys.stdout, indent=2)
    print()
    return code


def wait(fn, timeout: int, label: str) -> int:
    deadline = time.monotonic() + timeout
    last = None
    while True:
        state = fn()
        if state.get("done"):
            return emit(True, "satisfied", label, state, 0)
        # Settled, and the condition did not hold. Not a timeout — waiting longer
        # is exactly what will not help — and emphatically not `satisfied`, which
        # every caller reads as "the thing I was waiting for happened".
        if state.get("stop"):
            outcome = state.get("outcome") or "stopped"
            note(f"{label}: {outcome} — {state.get('note') or 'will never hold'}")
            return emit(False, outcome, label, state, 3)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            note(f"{label}: budget of {timeout}s spent; ending the wait")
            return emit(False, "budget-expired", label, state, 1)
        summary = json.dumps({k: v for k, v in state.items() if k != "checks"})[:160]
        if summary != last:
            note(f"{label}: waiting, {int(remaining)}s left — {summary}")
            last = summary
        time.sleep(min(POLL_SECONDS, max(1, remaining)))


def main() -> int:
    # --timeout hangs off every subcommand, not the top-level parser, so that
    # `waitfor.py reviews … --timeout 300` works. On the parent it is only legal
    # BEFORE the subcommand, which is not how anyone writes it.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--timeout", type=int, default=300)

    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("reviews", parents=[common])
    r.add_argument("--ticket", required=True)
    r.add_argument("--round", required=True)
    r.add_argument("--slots", required=True, help="comma or bare list, e.g. a,b")

    c = sub.add_parser("checks", parents=[common])
    c.add_argument("--pr", required=True, type=int)

    d = sub.add_parser("deploy", parents=[common])
    d.add_argument("--sha", required=True)

    a = sub.add_parser("agents", parents=[common])
    a.add_argument("--ticket", required=True)
    a.add_argument("--role", required=True)
    a.add_argument("--attempt", required=True)

    args = p.parse_args()

    if args.cmd == "reviews":
        slots = [s for s in args.slots.replace(",", " ").split() if s]
        paths = review_paths(args.ticket, args.round, slots)
        return wait(lambda: reviews_state(paths), args.timeout,
                    f"reviews {args.ticket} round {args.round}")
    if args.cmd == "checks":
        return wait(lambda: checks_state(args.pr), args.timeout,
                    f"checks on #{args.pr}")
    if args.cmd == "deploy":
        # An EMPTY sha is a bad invocation, not a settled outcome. `gh pr view
        # --json mergeCommit` answers null for the first seconds after a squash,
        # so the tick that just merged can reconcile with `merge_commit: ""` and
        # pass it straight through here — and `deploy_verdict("")` is terminal,
        # which would have exited "settled and not deployed" and had the tick
        # report a perfectly healthy deploy to the operator as a broken production.
        # Refused as a usage error: reconcile again next pass, by which time the
        # merge commit exists.
        if not args.sha.strip():
            print("waitfor: deploy --sha is empty; the merge commit is not known "
                  "yet (gh reports mergeCommit as null for a few seconds after a "
                  "squash). Reconcile again rather than waiting on nothing.",
                  file=sys.stderr)
            return 2
        return wait(lambda: deploy_state(args.sha), args.timeout,
                    f"deploy of {args.sha[:12]}")
    if args.cmd == "agents":
        return wait(lambda: agents_state(args.ticket, args.role, args.attempt),
                    args.timeout, f"{args.role} agents for {args.ticket}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
