#!/usr/bin/env python3
"""Run a command while holding an exclusive advisory lock.

macOS has no `flock(1)`, so this stands in for it. The lock is an `fcntl.flock`
on an open fd, which means the kernel releases it when this process dies — a
crashed tick cannot leave a stale lock wedging the board forever, which is the
failure mode a mkdir-based lock has.

    withlock.py <lockfile> <timeout-seconds> -- <command> [args...]

Exits 75 (EX_TEMPFAIL) if the lock could not be taken within the timeout, so a
caller can tell "someone else holds it" apart from "the command failed".
"""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import time

LOCK_BUSY = 75


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
                    print(
                        f"withlock: {lockfile} still held after {timeout:g}s",
                        file=sys.stderr,
                    )
                    return LOCK_BUSY
                time.sleep(0.2)
        os.write(fd, f"{os.getpid()}\n".encode())
        return subprocess.call(command)
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
