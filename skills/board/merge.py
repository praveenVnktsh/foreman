#!/usr/bin/env python3
"""Merge one card's pull request at the reviewed commit, syncing its fast-track label first.

    merge.py <pr-number> --head <sha> < card.json

Reads one Linear issue as JSON on stdin. Only its labels are read, through
route.py's `label_names()`, so every shape Linear hands labels over in works.
Settings come from config.sh: REPO, FAST_TRACK_LABEL and BOARD_DRY_RUN.
--head is the full commit SHA the merge must land: the reviewed head that
reconcile.py reports as `merge_head`.

    stdout  exactly one JSON object on exit 0, 1, 3, 4, 5 and 6:
            {"pr": <n>, "merged": bool, "fast_tracked": bool,
             "label": "<FAST_TRACK_LABEL or empty>", "reason": "<one sentence>"}
            fast_tracked is true exactly when the label is on the PR at the
            moment `gh pr merge` is called.
    stderr  one line on exit 2. Nothing otherwise.
    exit 0  merged. fast_tracked says whether the label was on the PR.
    exit 1  NOT merged: making the PR's label match the card failed -- reading
            the PR's labels failed or gave an unreadable answer, adding the
            label the card carries failed, or removing the label the card lacks
            failed. reason quotes gh's error. The tick leaves the card in In
            Review, charges no attempt, reports it, and tries again next tick.
    exit 2  called wrong or unreadable input: a missing or non-integer PR
            number, a missing --head or one that is not a full commit SHA,
            extra arguments, stdin that is not JSON, labels in a shape
            route.py refuses, or config.sh failing to load. No JSON on stdout.
    exit 3  NOT merged: `gh pr merge` itself failed. fast_tracked says whether
            the label was on the PR when the merge was tried. reason quotes
            gh's stderr. A head that moved between the check below and the
            merge lands here too: --match-head-commit makes GitHub refuse it.
    exit 4  NOT merged, and nothing was done to the PR: its head branch is not
            in this repository -- it comes from a fork -- or where it comes
            from could not be established. No label call runs first, not even
            a read.
    exit 5  NOT merged, and nothing was done to the PR: it is not the pull
            request that was reviewed. It is not OPEN, its base is not the
            repository's default branch, or its head is not --head -- or one
            of those could not be read. reason names which. No label call runs
            first. The tick charges nothing and looks again next tick.
    exit 6  NOT merged: BOARD_DRY_RUN is set. Every check above ran, and no gh
            call that changes anything did: no label edit, no merge. reason
            starts "dry run" and says what a real run would have done.

Why this exists. A target may queue deploys: a merge deploys on a schedule,
unless the merged pull request carries the GitHub label that
`[deploy] fast_track_label` names, which deploys as soon as main is green. The
operator marks urgency with the same-named label on the Linear card.

- **The card is the only source.** foreman never decides a card is urgent. The
  PR's label is synced to the card, not only copied: a label already on the PR
  -- left by a failed earlier tick, a build agent, or a person -- is removed
  when the card lacks it, because it would fast-track the deploy all the same.
  With FAST_TRACK_LABEL empty no label call runs at all, not even a read.
- **A failed sync refuses the merge.** Merging without the label silently
  queues a deploy the operator asked to hurry; merging with a label the card
  lacks hurries one the operator did not. The merge waits a tick instead, and
  the failure is reported, so the operator can create the label on the
  repository or fix gh. A failed read of the PR's labels refuses too.
- **The label is synced right before the merge.** The operator can add or
  remove the Linear label after the PR opened, so syncing it at PR creation
  would miss that.
- **Never auto-merge.** `--auto` would merge later, after this process has
  reported, and nothing would check the label is still right.
- **Merge only the commit that was reviewed.** Found auditing the board on
  2026-09-30: the merge named only a PR number, so a push after the review, a
  closed PR, or a PR retargeted at another branch merged all the same. The PR's
  state, base and head are checked first, and `--match-head-commit` closes the
  window between that check and the merge.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from typing import NoReturn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route  # noqa: E402  (see sys.path.insert above -- sibling module)

EXIT_MERGED = 0
EXIT_LABEL_FAILED = 1
EXIT_USAGE = 2
EXIT_MERGE_FAILED = 3
EXIT_NOT_THIS_REPOSITORY = 4
EXIT_NOT_THE_REVIEWED_PR = 5
EXIT_DRY_RUN = 6

# gh talks to the network. A hung call must end as a failed call the tick can
# report, not as a tick that never finishes.
GH_TIMEOUT_SECONDS = 120

PR_FIELDS = "state,baseRefName,headRefOid,isCrossRepository"

CONFIG_KEYS = ("REPO", "FAST_TRACK_LABEL", "BOARD_DRY_RUN")

# A full SHA-1 or SHA-256 object name. An abbreviated SHA never equals the
# PR's headRefOid, so accepting one would refuse the merge every tick forever.
FULL_SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")

USAGE = "usage: merge.py <pr-number> --head <sha> < card.json"


def _refuse(message: str) -> NoReturn:
    print(f"merge: {message}", file=sys.stderr)
    raise SystemExit(EXIT_USAGE)


def _load_config() -> dict[str, str]:
    """Read REPO and FAST_TRACK_LABEL by sourcing config.sh, as reconcile.py does.

    Contract values are shell variables in config.sh, not exported environment,
    so os.environ does not hold them. Importing reconcile.py instead would load
    many unrelated keys and refuse on any of them.
    """
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.sh")
    printf = 'printf "%s\\0" ' + " ".join(f'"${k}"' for k in CONFIG_KEYS)
    try:
        out = subprocess.run(
            # Only stdout is silenced, so config.sh's own refusal reaches stderr.
            ["bash", "-c", f". {script!r} >/dev/null; {printf}"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _refuse(f"could not read {script}: {exc}")
    values = out.stdout.split("\0")
    # A short field count means the printf never ran in full. Reading the
    # missing keys as empty would turn fast-track off without saying so.
    if out.returncode != 0 or len(values) < len(CONFIG_KEYS):
        _refuse(f"could not read {script}: {out.stderr.strip()}")
    config = dict(zip(CONFIG_KEYS, values))
    if not config["REPO"]:
        _refuse(f"REPO is empty after sourcing {script}; gh needs the repository to run in")
    return config


def _parse_args(argv: list[str]) -> tuple[int, str]:
    """(pr, head) from `<pr-number> --head <sha>`, in either order."""
    head = None
    positional = []
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--head":
            if not rest:
                _refuse(f"--head needs a commit SHA; {USAGE}")
            head = rest.pop(0)
        elif arg.startswith("--head="):
            head = arg[len("--head="):]
        elif arg.startswith("-"):
            _refuse(f"unknown option {arg!r}; {USAGE}")
        else:
            positional.append(arg)
    if len(positional) != 1:
        _refuse(f"{USAGE} (got {len(positional)} PR numbers)")
    raw = positional[0]
    if not raw.isdigit() or int(raw) <= 0:
        _refuse(f"PR number must be a positive integer, not {raw!r}")
    if head is None:
        _refuse(f"--head is required: the merge lands only the reviewed commit; {USAGE}")
    if not FULL_SHA.fullmatch(head.lower()):
        _refuse(f"--head must be a full commit SHA (40 or 64 hex digits), not {head!r}")
    return int(raw), head.lower()


def _read_card_labels(text: str) -> list[str]:
    try:
        card = json.loads(text)
    except json.JSONDecodeError as exc:
        _refuse(f"stdin is not JSON: {exc}")
    try:
        return route.label_names(card)
    except route.LabelShape as exc:
        _refuse(f"cannot read the card's labels: {exc}")


def _gh(args: list[str], repo: str) -> tuple[bool, str, str]:
    """Run one gh call in REPO. Returns (succeeded, stdout, stderr).

    cwd is REPO because a bare PR number resolves against the working
    directory's repository. A missing gh or a timeout is a failed call.
    """
    try:
        out = subprocess.run(
            ["gh", *args], cwd=repo,
            capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return False, "", f"gh {' '.join(args)} timed out after {GH_TIMEOUT_SECONDS}s"
    except OSError as exc:
        return False, "", f"could not run gh {' '.join(args)}: {exc}"
    return out.returncode == 0, out.stdout, out.stderr.strip()


def read_pr(pr: int, repo: str) -> tuple[dict | None, str]:
    """PR #pr's state, base, head and origin, from one call: (fields, "") or (None, why)."""
    ok, stdout, err = _gh(["pr", "view", str(pr), "--json", PR_FIELDS], repo)
    if not ok:
        return None, f"gh pr view failed: {err}"
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        data = None
    if not isinstance(data, dict):
        return None, f"gh pr view --json {PR_FIELDS} answered {stdout.strip()!r}, not an object"
    return data, ""


def head_origin(fields: dict) -> tuple[str, str]:
    """Where the PR's head branch lives: ("this", ""), ("fork", ""), or ("unknown", why).

    THE MERGE CHECKS THIS ITSELF, and does not trust its caller to have. Found on
    2026-09-16, auditing the repository before making it public: reconcile.py
    found a card's pull request by branch NAME, and a fork's pull request whose
    branch has the same name matched exactly like the board's own. The board
    would then have reviewed and merged a stranger's diff -- and every
    installation fast-forwards to `main` on a timer, so that diff would run on
    the operator's machine minutes later. reconcile.py now drops those rows. This
    is the second lock, on the step that cannot be undone: a merge is reached
    with a PR number, and a number carries no record of where it came from.

    Only an explicit `false` from GitHub is "this". Anything else -- `true`, a
    failed call, an answer that is neither -- refuses, because the cost of
    guessing wrong is a stranger's code on `main`.
    """
    answer = fields.get("isCrossRepository")
    if answer is False:
        return "this", ""
    if answer is True:
        return "fork", ""
    return "unknown", f"gh pr view answered {answer!r} for isCrossRepository, not true or false"


def default_branch(repo: str) -> tuple[str | None, str]:
    """The repository's default branch: (name, "") or (None, why)."""
    ok, stdout, err = _gh(
        ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], repo)
    if not ok:
        return None, f"gh repo view failed: {err}"
    name = stdout.strip()
    if not name:
        return None, "gh repo view answered no default branch"
    return name, ""


def not_the_reviewed_pr(fields: dict, head: str, repo: str) -> str:
    """Why the PR is not the one to merge at `head`, or "" when it is.

    A value that cannot be read is a reason too: merging on a guess is how a
    closed or retargeted PR would merge.
    """
    state = fields.get("state")
    if state != "OPEN":
        return f"it is {state!r}, not 'OPEN'"
    actual_head = fields.get("headRefOid")
    if not isinstance(actual_head, str) or actual_head.lower() != head:
        return f"its head is {actual_head!r}, not the reviewed commit {head!r}"
    base = fields.get("baseRefName")
    default, why = default_branch(repo)
    if default is None:
        return f"its base {base!r} could not be compared with the default branch: {why}"
    if base != default:
        return f"its base is {base!r}, not the default branch {default!r}"
    return ""


def pr_labels(pr: int, repo: str) -> tuple[list[str] | None, str]:
    """The names of the labels on PR #pr: (names, "") or (None, why).

    A failed call, or an answer that is not {"labels": [{"name": str}, ...]},
    is a failed read: guessing the label is absent could merge a PR that still
    fast-tracks the deploy.
    """
    ok, stdout, err = _gh(["pr", "view", str(pr), "--json", "labels"], repo)
    if not ok:
        return None, f"gh pr view --json labels failed: {err}"
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        data = None
    labels = data.get("labels") if isinstance(data, dict) else None
    if not isinstance(labels, list) or not all(
            isinstance(item, dict) and isinstance(item.get("name"), str) for item in labels):
        return None, f"gh pr view --json labels answered {stdout.strip()!r}, not a label list"
    return [item["name"] for item in labels], ""


def _report(pr: int, merged: bool, fast_tracked: bool, label: str, reason: str, code: int) -> NoReturn:
    print(json.dumps({
        "pr": pr, "merged": merged, "fast_tracked": fast_tracked,
        "label": label, "reason": reason,
    }))
    raise SystemExit(code)


def main(argv: list[str]) -> NoReturn:
    pr, head = _parse_args(argv)
    card_labels = _read_card_labels(sys.stdin.read())
    config = _load_config()
    repo, label = config["REPO"], config["FAST_TRACK_LABEL"]

    # Before the label, not only before the merge: copying the operator's
    # fast-track label onto a stranger's pull request is a change to it too.
    fields, why = read_pr(pr, repo)
    origin, why = ("unknown", why) if fields is None else head_origin(fields)
    if origin == "fork":
        _report(pr, False, False, label,
                f"Did not merge PR #{pr}: its head branch is in another repository, "
                f"not this one. Only a pull request from this repository is ever a card's.",
                EXIT_NOT_THIS_REPOSITORY)
    if origin != "this":
        _report(pr, False, False, label,
                f"Did not merge PR #{pr}: could not establish that its head branch is in "
                f"this repository, and merging on a guess could put a fork's code on main: {why}",
                EXIT_NOT_THIS_REPOSITORY)
    mismatch = not_the_reviewed_pr(fields, head, repo)
    if mismatch:
        _report(pr, False, False, label,
                f"Did not merge PR #{pr}: {mismatch}. Nothing was changed on it.",
                EXIT_NOT_THE_REVIEWED_PR)
    if config["BOARD_DRY_RUN"]:
        _report(pr, False, False, label,
                f"dry run: would sync {label!r} to the card and merge PR #{pr} at {head}"
                if label else f"dry run: would merge PR #{pr} at {head}",
                EXIT_DRY_RUN)

    # After a sync that succeeds, the PR carries the label exactly when the card
    # does, so fast_tracked is true exactly when the deploy will be fast-tracked.
    fast_tracked = False
    if label:
        on_pr, err = pr_labels(pr, repo)
        if on_pr is None:
            _report(pr, False, False, label,
                    f"Did not merge PR #{pr}: could not read its labels, so whether "
                    f"{label!r} on it matches the card is unknown: {err}",
                    EXIT_LABEL_FAILED)
        # GitHub label names are case-insensitive. Exact membership misses a
        # PR label stored as Fast-Track when FAST_TRACK_LABEL is fast-track,
        # so the stale label stays on and the merge still fast-tracks.
        folded = label.casefold()
        wanted = folded in {name.casefold() for name in card_labels}
        if wanted != (folded in {name.casefold() for name in on_pr}):
            flag = "--add-label" if wanted else "--remove-label"
            ok, _, err = _gh(["pr", "edit", str(pr), flag, label], repo)
            if not ok:
                why = (f"the card carries {label!r} but adding it to the PR failed, "
                       f"and merging without it would queue the deploy"
                       if wanted else
                       f"the card lacks {label!r} but the PR carries it and removing it "
                       f"failed, and merging with it would fast-track the deploy")
                _report(pr, False, False, label, f"Did not merge PR #{pr}: {why}: {err}",
                        EXIT_LABEL_FAILED)
        fast_tracked = wanted

    # --match-head-commit: a push after the check above makes GitHub refuse.
    ok, _, err = _gh(["pr", "merge", str(pr), "--squash", "--match-head-commit", head], repo)
    if not ok:
        _report(pr, False, fast_tracked, label,
                f"gh pr merge failed for PR #{pr}: {err}", EXIT_MERGE_FAILED)

    reason = (f"Merged PR #{pr} at {head} with {label!r} on it, so the deploy is fast-tracked."
              if fast_tracked else f"Merged PR #{pr} at {head}.")
    _report(pr, True, fast_tracked, label, reason, EXIT_MERGED)


if __name__ == "__main__":
    main(sys.argv[1:])
