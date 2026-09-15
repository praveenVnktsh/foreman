#!/usr/bin/env python3
"""Merge one card's pull request, copying the card's fast-track label first.

    merge.py <pr-number> < card.json

Reads one Linear issue as JSON on stdin. Only its labels are read, through
route.py's `label_names()`, so every shape Linear hands labels over in works.
Settings come from config.sh: REPO and FAST_TRACK_LABEL.

    stdout  exactly one JSON object on exit 0, 1 and 3:
            {"pr": <n>, "merged": bool, "fast_tracked": bool,
             "label": "<FAST_TRACK_LABEL or empty>", "reason": "<one sentence>"}
            fast_tracked is true only when the label was added to the PR.
    stderr  one line on exit 2. Nothing otherwise.
    exit 0  merged. fast_tracked says whether the label went on first.
    exit 1  NOT merged: the card carries the label and copying it to the PR
            failed. reason quotes gh's stderr. The tick leaves the card in In
            Review, charges no attempt, reports it, and tries again next tick.
    exit 2  called wrong or unreadable input: a missing or non-integer PR
            number, extra arguments, stdin that is not JSON, labels in a shape
            route.py refuses, or config.sh failing to load. No JSON on stdout.
    exit 3  NOT merged: `gh pr merge` itself failed. The label may or may not
            be on the PR; fast_tracked says. reason quotes gh's stderr.

Why this exists. A target may queue deploys: a merge deploys on a schedule,
unless the merged pull request carries the GitHub label that
`[deploy] fast_track_label` names, which deploys as soon as main is green. The
operator marks urgency with the same-named label on the Linear card.

- **The card is the only source.** foreman never decides a card is urgent.
  With FAST_TRACK_LABEL empty, or the card lacking the label, no label call
  runs at all.
- **A failed copy refuses the merge.** Merging without the label silently
  queues a deploy the operator asked to hurry. The merge waits a tick instead,
  and the failure is reported, so the operator can create the label on the
  repository or fix gh.
- **The label goes on right before the merge.** The operator can add the Linear
  label after the PR opened, so copying it at PR creation would miss it.
- **Never auto-merge.** `--auto` would merge later, after this process has
  reported, and nothing would check the label is still there.
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


def should_copy_label(fast_track_label: str, card_labels: list[str]) -> bool:
    """True when the contract names a label and the card carries exactly it."""
    return bool(fast_track_label) and fast_track_label in card_labels


def _gh(args: list[str], repo: str) -> tuple[bool, str]:
    """Run one gh call in REPO. Returns (succeeded, stderr).

    cwd is REPO because a bare PR number resolves against the working
    directory's repository. A missing gh or a timeout is a failed call.
    """
    try:
        out = subprocess.run(
            ["gh", *args], cwd=repo,
            capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return False, f"gh {' '.join(args)} timed out after {GH_TIMEOUT_SECONDS}s"
    except OSError as exc:
        return False, f"could not run gh {' '.join(args)}: {exc}"
    return out.returncode == 0, out.stderr.strip()


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

    fast_tracked = False
    if should_copy_label(label, card_labels):
        ok, err = _gh(["pr", "edit", str(pr), "--add-label", label], repo)
        if not ok:
            _report(pr, False, False, label,
                    f"Did not merge PR #{pr}: the card carries {label!r} but adding it "
                    f"to the PR failed, and merging without it would queue the deploy: {err}",
                    EXIT_LABEL_FAILED)
        fast_tracked = True

    ok, err = _gh(["pr", "merge", str(pr), "--squash"], repo)
    if not ok:
        _report(pr, False, fast_tracked, label,
                f"gh pr merge failed for PR #{pr}: {err}", EXIT_MERGE_FAILED)

    reason = (f"Merged PR #{pr} with {label!r} on it, so the deploy is fast-tracked."
              if fast_tracked else f"Merged PR #{pr}.")
    _report(pr, True, fast_tracked, label, reason, EXIT_MERGED)


if __name__ == "__main__":
    main(sys.argv[1:])
