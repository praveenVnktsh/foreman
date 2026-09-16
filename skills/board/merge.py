#!/usr/bin/env python3
"""Merge one card's pull request, making its fast-track label match the card's first.

    merge.py <pr-number> < card.json

Reads one Linear issue as JSON on stdin. Only its labels are read, through
route.py's `label_names()`, so every shape Linear hands labels over in works.
Settings come from config.sh: REPO and FAST_TRACK_LABEL.

    stdout  exactly one JSON object on exit 0, 1 and 3:
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
            number, extra arguments, stdin that is not JSON, labels in a shape
            route.py refuses, or config.sh failing to load. No JSON on stdout.
    exit 3  NOT merged: `gh pr merge` itself failed. fast_tracked says whether
            the label was on the PR when the merge was tried. reason quotes
            gh's stderr.
    exit 4  NOT merged, and nothing was done to the PR: its head branch is not
            in this repository -- it comes from a fork -- or where it comes
            from could not be established. No label call runs first, not even
            a read.

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
"""

from __future__ import annotations

import json
import os
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

# gh talks to the network. A hung call must end as a failed call the tick can
# report, not as a tick that never finishes.
GH_TIMEOUT_SECONDS = 120

CONFIG_KEYS = ("REPO", "FAST_TRACK_LABEL")


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


def _parse_pr_number(argv: list[str]) -> int:
    if len(argv) != 1:
        _refuse(f"usage: merge.py <pr-number> < card.json (got {len(argv)} arguments)")
    raw = argv[0]
    if not raw.isdigit() or int(raw) <= 0:
        _refuse(f"PR number must be a positive integer, not {raw!r}")
    return int(raw)


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


def head_origin(pr: int, repo: str) -> tuple[str, str]:
    """Where PR #pr's head branch lives: ("this", ""), ("fork", ""), or ("unknown", why).

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
    try:
        out = subprocess.run(
            ["gh", "pr", "view", str(pr), "--json", "isCrossRepository",
             "--jq", ".isCrossRepository"],
            cwd=repo, capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return "unknown", f"gh pr view timed out after {GH_TIMEOUT_SECONDS}s"
    except OSError as exc:
        return "unknown", f"could not run gh pr view: {exc}"
    if out.returncode != 0:
        return "unknown", f"gh pr view failed: {out.stderr.strip()}"
    answer = out.stdout.strip()
    if answer == "false":
        return "this", ""
    if answer == "true":
        return "fork", ""
    return "unknown", f"gh pr view answered {answer!r} for isCrossRepository, not true or false"


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
    pr = _parse_pr_number(argv)
    card_labels = _read_card_labels(sys.stdin.read())
    config = _load_config()
    repo, label = config["REPO"], config["FAST_TRACK_LABEL"]

    # Before the label, not only before the merge: copying the operator's
    # fast-track label onto a stranger's pull request is a change to it too.
    origin, why = head_origin(pr, repo)
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
        wanted = label in card_labels
        if wanted != (label in on_pr):
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

    ok, _, err = _gh(["pr", "merge", str(pr), "--squash"], repo)
    if not ok:
        _report(pr, False, fast_tracked, label,
                f"gh pr merge failed for PR #{pr}: {err}", EXIT_MERGE_FAILED)

    reason = (f"Merged PR #{pr} with {label!r} on it, so the deploy is fast-tracked."
              if fast_tracked else f"Merged PR #{pr}.")
    _report(pr, True, fast_tracked, label, reason, EXIT_MERGED)


if __name__ == "__main__":
    main(sys.argv[1:])
