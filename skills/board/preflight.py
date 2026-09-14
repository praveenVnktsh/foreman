#!/usr/bin/env python3
"""Prove this machine can actually run a build, before one is dispatched.

    preflight.py            # JSON verdict on stdout, exit 0 ok / 1 unfit
    preflight.py --quiet    # same exit code, no output unless unfit

The board lost two consecutive build attempts on one card on 2026-08-02 to a
`/tmp` that was over its user quota. Both agents died mid-test-run with no error
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

WHY THE WRITE PROBES ARE LOCKED. The check above is correct for one instance
running alone and wrong for several: two instances probing `/tmp` at once both
observe room that only one of them can have, because the probe writes and then
RELEASES -- it is a point-in-time measurement, not a reservation, and "point in
time" stops meaning anything the moment two processes measure the same point at
once. `skills/board/withlock.py` serializes the probes across every instance on
this machine, on `$FOREMAN_HOME/preflight.lock`. Held in-process (see
`withlock.held()`) rather than delegated to a wrapper subprocess, specifically
so that killing THIS process — the one thing a preflight that hangs invites —
drops the fd and releases the lock immediately. A lock that survived a SIGKILL
would wedge every future dispatch on the machine behind a probe that will never
finish, which is worse than the race it exists to prevent.

WHY IT NO LONGER MEASURES STALENESS. It used to report `behind_origin_main`,
after a tick on 2026-08-03 refuted a `blocking` finding by grepping
`deploy/release.sh` in this checkout, 169 commits behind, and merged a change
that broke the deploy on the target host. The number never fixed that, and
could not: it is measured against `refs/remotes/origin/main`, which is the
very ref the tick was misreading. `evidence.sh` did fix it, by fetching per
read.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import withlock  # noqa: E402  (see sys.path.insert above -- sibling module)

CHUNK = 8 * 1024 * 1024

# How long a probe waits for another instance's probe to finish before giving
# up. Generous on purpose: a held lock means a probe is actually IN PROGRESS
# somewhere on this machine (or, worst case, was killed and is about to be
# reclaimed instantly -- see withlock.held()), never a process that will hold
# it forever, so waiting here is always the right call. Bounded anyway so a
# lock that somehow never clears cannot hang a tick past its own budget.
PROBE_LOCK_TIMEOUT_SECONDS = 60


def _load_config() -> dict[str, str]:
    """Read settings from config.sh, the single source of truth.

    Same reasoning as reconcile.py: a second copy of a threshold in Python is a
    threshold that silently stops matching the one the operator edits.
    """
    keys = ("REPO", "FOREMAN_HOME", "MIN_FREE_TMP_MB", "MIN_FREE_REPO_MB",
            "PROBE_TMP_MB", "PROBE_REPO_MB", "QUICK_PROBE_MB",
            "MIN_FREE_MEMORY_MB", "HARNESS", "HARNESS_SH")
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


def locked_write_probe(lockfile: str, directory: str, megabytes: int) -> dict:
    """`write_probe`, serialized against every other instance probing this
    machine at the same moment.

    Two instances writing gigabyte probes concurrently both observe room that
    only one of them can have — the write-and-release check is a point-in-time
    measurement, and "point in time" stops meaning anything once two processes
    measure the same point at once. `withlock.held()` is the same locking
    primitive `withlock.py`'s CLI uses elsewhere in this skill, held here
    in-process rather than around a subprocess, so a SIGKILL of THIS process
    mid-probe drops the fd and releases the lock immediately — see the module
    docstring and `withlock.held()`'s own docstring for why that matters.

    A lock that could not be taken is reported as a failed check rather than
    raised: preflight's whole contract is "every check here gates", and a
    machine so contended that the probe lock itself cannot be acquired within
    `PROBE_LOCK_TIMEOUT_SECONDS` is not fit to dispatch onto either.
    """
    try:
        with withlock.held(lockfile, PROBE_LOCK_TIMEOUT_SECONDS):
            return write_probe(directory, megabytes)
    except TimeoutError as exc:
        return {
            "name": f"write {megabytes}MB to {directory}",
            "ok": False,
            "detail": f"could not take the probe lock: {exc}",
        }


def memory_check(min_mb: int) -> dict:
    """Free memory, which is the resource that actually took a machine down.

    On 2026-08-31 a self-hosted CI runner was OOM-killed at a 5.2GB peak. On
    2026-09-01 four build agents plus that runner drove the same 14GB box to a
    load average of 14 with ssh timing out. This file probed disk in two places
    and never once looked at memory, so it reported that machine fit throughout.

    AVAILABLE, not free. `MemFree` counts only untouched pages and reads as
    almost nothing on any machine that has been up a while -- this host had 99
    days of uptime and a page cache to match. `MemAvailable` is the kernel's own
    estimate of what a new process could actually get, which is the question
    being asked.

    The agents are not the cost: a claude process measures about 0.3GB. What
    peaks is the WORK -- the target's own test suite, run concurrently by every
    build agent -- so this floor is sized for one more suite, not one more agent.

    Linux only, by design. /proc/meminfo is absent on macOS, where this returns
    ok with a detail saying so: a developer machine running one agent by hand is
    not the machine this guards, and refusing to dispatch there would make the
    gate useless where it is needed by making it wrong where it is not.
    """
    check = {"name": f"{min_mb}MB memory available", "ok": True, "detail": "not measurable here"}
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    available_mb = int(line.split()[1]) // 1024
                    break
            else:
                return check
    except OSError:
        return check
    check["ok"] = available_mb >= min_mb
    check["detail"] = f"{available_mb}MB available, floor is {min_mb}MB"
    if not check["ok"]:
        check["detail"] += (
            "; dispatching another build would run its test suite on a machine "
            "already at the edge, which is how the OOM killer picks a victim"
        )
    return check


def runner_check(repo: str) -> dict:
    """Every self-hosted runner this repository has is offline.

    A required check that no runner can ever pick up does not fail. It sits
    `queued` forever, and a board waiting on it is indistinguishable from a board
    watching a job that is still running -- the same "waiting looks identical to
    running" failure SKILL.md names for a check-name mismatch, with a different
    cause.

    Measured on 2026-09-01: a self-hosted runner was OOM-killed at 20:49 the
    previous night and nothing noticed for fifteen hours. Every card on the board
    sat waiting on checks that could not start, and the tick reported the machine
    fit the whole time, because nothing here asked.

    Only fires when the repository actually depends on self-hosted runners. A
    repository with none registered uses GitHub-hosted ones, where there is
    nothing for this machine to be wrong about -- so `total_count == 0` is a pass,
    not a failure. An API call that cannot be made at all is also a pass: the gh
    check above already covers a dead token, and reporting the same fault twice
    tells an operator nothing new.
    """
    check = {"name": "a runner is online", "ok": True, "detail": "no self-hosted runners registered"}
    try:
        p = subprocess.run(
            ["gh", "api", "repos/{owner}/{repo}/actions/runners"],
            cwd=repo, capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        check["detail"] = f"could not ask: {exc}"
        return check
    if p.returncode != 0:
        check["detail"] = "could not ask; see the gh check above"
        return check
    try:
        body = json.loads(p.stdout or "{}")
    except json.JSONDecodeError:
        check["detail"] = "could not ask; unreadable response"
        return check
    runners = body.get("runners") or []
    if not runners:
        return check
    online = [r.get("name") for r in runners if (r.get("status") or "") == "online"]
    if online:
        check["detail"] = "online: " + ", ".join(n for n in online if n)
        return check
    names = ", ".join(str(r.get("name")) for r in runners)
    check["ok"] = False
    check["detail"] = (
        f"every registered runner is offline ({names}). A required check will "
        f"queue and never start, which reads as pending forever."
    )
    return check


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
    lockfile = os.path.join(cfg["FOREMAN_HOME"], "preflight.lock")

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
            locked_write_probe(lockfile, tmpdir, int(cfg["QUICK_PROBE_MB"])),
            free_check(tmpdir, int(cfg["MIN_FREE_TMP_MB"])),
            free_check(repo, int(cfg["MIN_FREE_REPO_MB"])),
            memory_check(int(cfg["MIN_FREE_MEMORY_MB"])),
        ]
    else:
        checks = [
            # A build's temp usage is dominated by the target's own test suite;
            # PROBE_TMP_MB is declared per-target in board.toml's [limits], not
            # assumed here -- see bin/contract.py.
            locked_write_probe(lockfile, tmpdir, int(cfg["PROBE_TMP_MB"])),
            free_check(tmpdir, int(cfg["MIN_FREE_TMP_MB"])),
            locked_write_probe(lockfile, repo, int(cfg["PROBE_REPO_MB"])),
            free_check(repo, int(cfg["MIN_FREE_REPO_MB"])),
        ]
        # A worktree cannot be created from a ref this machine cannot fetch, and
        # a pull request cannot be opened without credentials. Both fail late and
        # confusingly inside an agent; cheap to establish here.
        checks += [
            fetch_check(repo),
            # `gh api user`, NOT `gh auth status`. Measured on a real host on
            # 2026-09-01: with an expired token, `gh auth status` prints "The
            # token ... is invalid" and exits 0, while every actual API call
            # returns HTTP 401. This check read that exit code alone and passed,
            # so the gate reported a machine fit to build on which `gh pr create`
            # could not work at all.
            #
            # That is the precise failure this whole file exists to prevent: an
            # agent dispatched into an unusable environment does the work, dies
            # at the end, and costs the ticket one of its few attempts for a
            # reason that was knowable before it started. A check that asks
            # whether a credential is CONFIGURED rather than whether it WORKS is
            # not a gate.
            command_check("gh auth", ["gh", "api", "user"]),
            runner_check(repo),
            # Named by harness, not by "claude": an operator on a codex
            # installation needs to be told codex is missing, not claude, and
            # `check` is the adapter's own verb -- see harness/*.sh.
            command_check(f"{cfg['HARNESS']} binary", [cfg["HARNESS_SH"], "check"]),
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
