#!/usr/bin/env python3
"""Prove this machine can actually run a build, before one is dispatched.

    preflight.py            # JSON verdict on stdout, exit 0 ok / 1 unfit
    preflight.py --quiet    # same exit code, no output unless unfit

The board lost two consecutive PRA-28 build attempts on 2026-08-02 to a `/tmp`
that was over its user quota. Both agents died mid-`just test-all` with no error
in the transcript, no pull request, and no branch. Each death consumed an attempt
budget meant for a bad *ticket*, and the second attempt was dispatched into
exactly the same broken environment as the first — because nothing checked.

WHY A FREE-SPACE CHECK IS NOT ENOUGH. `/tmp` there is a tmpfs mounted `usrquota`.
At the moment of failure `df` reported 1.5G available and `dd` failed instantly
with EDQUOT: the filesystem had room, the *user* did not. `statvfs` reports the
filesystem, so it reports the same lie. The only check that distinguishes "there
is room" from "I may use it" is writing the bytes and seeing whether the write
returns. That is what this does, and it is why the probe is not a token 1MB —
a quota can admit a small write and refuse the gigabytes pytest wants.

Nothing here is cached. A tick that ran ten minutes ago proves nothing about a
disk that filled since.

WHY IT NO LONGER MEASURES STALENESS. It used to report `behind_origin_main`,
after a tick on 2026-08-03 refuted a `blocking` finding by grepping
`ops/deploy-mango.sh` in this checkout, 169 commits behind, and merged a change
that broke the mango deploy. The number never fixed that, and could not: it is
measured against `refs/remotes/origin/main`, which is the very ref the tick was
misreading. `evidence.sh` did fix it, by fetching per read.

What was left was a number with no consumer. `dispatch.sh` reads this script's
exit code and discards the JSON, nothing in the skill parsed the field, and
SKILL.md said in terms that no value of it licensed reading the working tree.
It bought a `git fetch origin` on every heartbeat to compute something nobody
read and the prose forbade acting on, so both are gone.

The FULL gate still fetches, and there the fetch is fatal — `dispatch.sh`
cannot cut a worktree from a ref this machine cannot reach. `--quick` now
touches the network not at all: it is a disk check, which is the fault it was
written for.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

CHUNK = 8 * 1024 * 1024


def _load_config() -> dict[str, str]:
    """Read settings from config.sh, the single source of truth.

    Same reasoning as reconcile.py: a second copy of a threshold in Python is a
    threshold that silently stops matching the one the operator edits.
    """
    keys = ("REPO", "MIN_FREE_TMP_MB", "MIN_FREE_REPO_MB", "PROBE_TMP_MB",
            "PROBE_REPO_MB", "QUICK_PROBE_MB")
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.sh")
    printf = 'printf "%s\\0" ' + " ".join(f'"${k}"' for k in keys)
    out = subprocess.run(
        # Only stdout is silenced; see the same fix in reconcile.py. With `2>&1`
        # a config that refused to load reported an empty reason.
        ["bash", "-c", f". {script!r} >/dev/null; {printf}"],
        capture_output=True, text=True, timeout=15,
    )
    values = out.stdout.split("\0")
    if out.returncode != 0 or len(values) < len(keys):
        raise SystemExit(f"preflight: could not read {script}: {out.stderr.strip()}")
    return dict(zip(keys, values))


def write_probe(directory: str, megabytes: int) -> dict:
    """Actually write `megabytes` into `directory`, then remove it.

    Returns a check dict. The file is written through a NamedTemporaryFile that
    is deleted on close even if the write raises, so a failed probe never leaves
    the very bytes it was testing for behind — which would make the next probe
    fail for a reason this one caused.
    """
    check = {
        "name": f"write {megabytes}MB to {directory}",
        "ok": False,
        "detail": "",
    }
    if not os.path.isdir(directory):
        check["detail"] = "directory does not exist"
        return check
    blob = b"\0" * CHUNK
    written = 0
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".board-preflight-") as fh:
            target = megabytes * 1024 * 1024
            while written < target:
                n = min(CHUNK, target - written)
                fh.write(blob[:n])
                written += n
            fh.flush()
            os.fsync(fh.fileno())
    except OSError as exc:
        # EDQUOT and ENOSPC both land here. Report the errno name: "Disk quota
        # exceeded" and "No space left on device" call for different repairs —
        # one is this user's allowance, the other is the whole filesystem.
        check["detail"] = (
            f"failed after {written // (1024 * 1024)}MB: {exc.strerror or exc} "
            f"(errno {getattr(exc, 'errno', '?')})"
        )
        return check
    check["ok"] = True
    check["detail"] = f"wrote and released {megabytes}MB"
    return check


def free_check(path: str, min_mb: int) -> dict:
    """Filesystem free space. Necessary but NOT sufficient — see module docstring.

    Kept because it is the check that explains a failure: when the write probe
    fails and this one passes, the cause is a quota rather than a full disk.
    """
    check = {"name": f"{min_mb}MB free on {path}", "ok": False, "detail": ""}
    try:
        free_mb = shutil.disk_usage(path).free // (1024 * 1024)
    except OSError as exc:
        check["detail"] = str(exc)
        return check
    check["ok"] = free_mb >= min_mb
    check["detail"] = f"{free_mb}MB free"
    return check


def fetch_check(repo: str) -> dict:
    """The one thing this needs from `origin`, and only the full gate asks for it.

    `dispatch.sh` cannot create a worktree from a ref this machine cannot fetch,
    and a pull request cannot be opened without credentials, so establishing the
    transport here is cheaper than watching an agent die on it. This check gates:
    a full preflight reporting `fit: false` on nothing but a failed fetch is
    correct and expected.

    It is NOT claiming that only git is broken. `origin` is HTTPS with `gh` as
    the credential helper, so a fetch that cannot authenticate is evidence that
    every `gh` call the tick is about to make will fail too.

    `gc.auto=0` because this fetches into a `.git` shared by every live board
    worktree, and an auto-gc there repacks metadata agents are reading. The flag
    does not contain that hazard — this fetch is unlocked, and
    `board-worktree.lock` serialises dispatches against each other rather than
    against running agents. All it does is decline to add a repack trigger. The
    cost is real and worth stating: loose objects accumulate here until some
    other git command collects them.
    """
    return command_check(
        "git fetch origin",
        ["git", "-c", "gc.auto=0", "fetch", "--quiet", "origin"],
        cwd=repo,
    )


def command_check(name: str, args: list[str], cwd: str | None = None) -> dict:
    check = {"name": name, "ok": False, "detail": ""}
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        check["detail"] = str(exc)
        return check
    check["ok"] = p.returncode == 0
    if not check["ok"]:
        tail = (p.stderr or p.stdout or "").strip().splitlines()
        check["detail"] = tail[-1] if tail else f"exit {p.returncode}"
    return check


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument(
        "--quick", action="store_true",
        help="cheap liveness check for a frequent heartbeat tick; dispatch.sh "
             "still runs the full gate before any agent is spawned",
    )
    args = ap.parse_args()

    cfg = _load_config()
    repo = cfg["REPO"]
    tmpdir = os.environ.get("TMPDIR") or "/tmp"

    if args.quick:
        # A heartbeat tick runs every couple of minutes and almost always finds
        # nothing to do. Writing a gigabyte to prove it could have built is
        # absurd at that cadence — it is tens of GB of tmpfs churn per hour for
        # a question nobody asked. The small probe still catches a hard-broken
        # box (a quota already at its limit refuses 16MB as readily as 1GB), and
        # the expensive, authoritative gate has not moved: dispatch.sh runs the
        # FULL preflight before it spawns anything, so nothing can be dispatched
        # into a machine that cannot build.
        #
        # It touches the network not at all. The fetch it used to make existed
        # to compute `behind_origin_main`, which nothing read; with the number
        # gone the fetch has no consumer either, and a heartbeat every couple of
        # minutes should not be buying one. Verification does not depend on it:
        # `evidence.sh` runs its own fetch per read, which is the only thing
        # that stays true for a tick that merges pull requests while it runs.
        checks = [
            write_probe(tmpdir, int(cfg["QUICK_PROBE_MB"])),
            free_check(tmpdir, int(cfg["MIN_FREE_TMP_MB"])),
            free_check(repo, int(cfg["MIN_FREE_REPO_MB"])),
        ]
    else:
        checks = [
            # A build's temp usage is dominated by pytest, which wants gigabytes.
            write_probe(tmpdir, int(cfg["PROBE_TMP_MB"])),
            free_check(tmpdir, int(cfg["MIN_FREE_TMP_MB"])),
            write_probe(repo, int(cfg["PROBE_REPO_MB"])),
            free_check(repo, int(cfg["MIN_FREE_REPO_MB"])),
        ]
        # A worktree cannot be created from a ref this machine cannot fetch, and
        # a pull request cannot be opened without credentials. Both fail late and
        # confusingly inside an agent; cheap to establish here.
        checks += [
            fetch_check(repo),
            command_check("gh auth", ["gh", "auth", "status"]),
            command_check("claude binary", ["claude", "--version"]),
        ]

    # Every check here gates. There is no advisory tier any more: the only thing
    # that ever wore it was the staleness number, which was advisory precisely
    # because nothing consumed it, and a check nothing consumes is a fetch
    # nobody should be paying for.
    failed = [c for c in checks if not c["ok"]]
    verdict = {
        "fit": not failed,
        "tmpdir": tmpdir,
        "repo": repo,
        "checks": checks,
    }
    # `--quiet` suppresses a clean verdict, never a bad reading.
    if not args.quiet or failed:
        json.dump(verdict, sys.stdout, indent=2)
        print()
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
