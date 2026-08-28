#!/usr/bin/env python3
"""Run a command while holding an exclusive advisory lock.

macOS has no `flock(1)`, so this stands in for it. The lock is an `fcntl.flock`
on an open fd, which means the kernel releases it when this process dies — a
crashed tick cannot leave a stale lock wedging the board forever, which is the
failure mode a mkdir-based lock has.

    withlock.py <lockfile> <timeout-seconds> -- <command> [args...]

Exits 75 (EX_TEMPFAIL) if the lock could not be taken within the timeout, so a
caller can tell "someone else holds it" apart from "the command failed".

`held()` below is the same mechanism, importable for a Python caller that wants
the lock around a piece of its OWN process rather than around a subprocess it
spawns. preflight.py uses it that way: the write probe races two instances
that are each proving free disk by writing to it, and the SIGKILL guarantee
only holds when the fd is open in the process that gets killed, not in a
wrapper it shelled out to. Both entry points share this one implementation
rather than two copies of the same flock calls drifting apart.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import subprocess
import sys
import time

LOCK_BUSY = 75


@contextlib.contextmanager
def held(lockfile: str, timeout: float):
    """Hold an exclusive advisory lock on `lockfile` for the block.

    Raises `TimeoutError` if the lock is not free within `timeout` seconds.
    The fd stays open only for the lifetime of the `with` block, held in
    THIS process — so a SIGKILL anywhere inside the block drops the fd and
    the kernel releases the flock immediately, with no cleanup code required
    to run. That is the whole point: a lock that depended on a `finally`
    block to release would be exactly the lock a kill signal defeats.
    """
    os.makedirs(os.path.dirname(os.path.abspath(lockfile)), exist_ok=True)
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"{lockfile} still held after {timeout:g}s")
                time.sleep(0.2)
        os.write(fd, f"{os.getpid()}\n".encode())
        yield
    finally:
        os.close(fd)


def main(argv: list[str]) -> int:
    if "--" not in argv:
        print("usage: withlock.py <lockfile> <timeout> -- <command>", file=sys.stderr)
        return 2
    split = argv.index("--")
    head, command = argv[:split], argv[split + 1 :]
    if len(head) != 2 or not command:
        print("usage: withlock.py <lockfile> <timeout> -- <command>", file=sys.stderr)
        return 2

    lockfile, timeout = head[0], float(head[1])
    try:
        with held(lockfile, timeout):
            return subprocess.call(command)
    except TimeoutError as exc:
        print(f"withlock: {exc}", file=sys.stderr)
        return LOCK_BUSY


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
