#!/usr/bin/env python3
"""Run a command while holding an exclusive advisory lock.

macOS has no `flock(1)`, so this stands in for it. The lock is an `fcntl.flock`
on an open fd, which means the kernel releases it when this process dies — a
crashed tick cannot leave a stale lock wedging the board forever, which is the
failure mode a mkdir-based lock has.

    withlock.py <lockfile> <timeout-seconds> -- <command> [args...]
    withlock.py --fd <n> <lockfile> <timeout-seconds>

Exits 75 (EX_TEMPFAIL) if the lock could not be taken within the timeout, so a
caller can tell "someone else holds it" apart from "the command failed". A lock
that fails for any OTHER reason -- a filesystem that does not support flock, a
bad fd -- exits 71 (EX_OSERR) and says so. Reading those as "busy" made a broken
lock look like a contended one, and a caller that stands down on "busy" then
stood down forever on a lock nobody held.

THE `--fd` FORM IS `flock -w <timeout> <n>`. It locks fd <n>, which the calling
shell opened (`exec 9>>lockfile`) and this process inherited, and exits 0 with
the lock taken. An flock belongs to the open file description, not to the
process that asked, so the lock outlives this process for as long as the
caller keeps fd <n> open. That is what lets a bash script hold a lock around a
stretch of its own code -- its variables and functions intact -- rather than
around a subprocess. The caller must close fd <n> in any child that outlives
it (`9>&-`), or the child holds the lock too. `<lockfile>` only names the lock
in messages.

`held()` below is the same mechanism, importable for a Python caller that wants
the lock around a piece of its OWN process rather than around a subprocess it
spawns. preflight.py uses it that way: the write probe races two instances
that are each proving free disk by writing to it, and the SIGKILL guarantee
only holds when the fd is open in the process that gets killed, not in a
wrapper it shelled out to. Every entry point shares `_acquire` rather than
three copies of the same flock calls drifting apart.
"""

from __future__ import annotations

import contextlib
import errno
import fcntl
import os
import signal
import subprocess
import sys
import time

LOCK_BUSY = 75
LOCK_BROKEN = 71

# What `flock(LOCK_NB)` answers when another holder has the lock. EACCES is on
# the list because some platforms report a conflicting lock that way. Anything
# else is the lock failing, not the lock being taken.
_BUSY_ERRNOS = frozenset({errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES})

_POLL_SECONDS = 0.2
_USAGE = ("usage: withlock.py <lockfile> <timeout> -- <command>\n"
          "       withlock.py --fd <n> <lockfile> <timeout>")


def _acquire(fd: int, lockfile: str, timeout: float) -> None:
    """Take an exclusive flock on `fd`, polling until `timeout` runs out.

    Raises `TimeoutError` when another holder keeps it past the timeout, and
    lets every other `OSError` through: a lock that cannot work must not be
    reported as a lock somebody else has.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError as exc:
            if exc.errno not in _BUSY_ERRNOS:
                raise
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{lockfile} still held after {timeout:g}s") from None
            time.sleep(_POLL_SECONDS)


@contextlib.contextmanager
def held(lockfile: str, timeout: float):
    """Hold an exclusive advisory lock on `lockfile` for the block.

    Raises `TimeoutError` if the lock is not free within `timeout` seconds,
    and `OSError` if the lock cannot be taken at all.
    The fd stays open only for the lifetime of the `with` block, held in
    THIS process — so a SIGKILL anywhere inside the block drops the fd and
    the kernel releases the flock immediately, with no cleanup code required
    to run. That is the whole point: a lock that depended on a `finally`
    block to release would be exactly the lock a kill signal defeats.
    """
    os.makedirs(os.path.dirname(os.path.abspath(lockfile)), exist_ok=True)
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        _acquire(fd, lockfile, timeout)
        os.write(fd, f"{os.getpid()}\n".encode())
        yield
    finally:
        os.close(fd)


def _run_forwarding_signals(command: list[str]) -> int:
    """Run `command`, handing it SIGTERM and SIGINT, and wait for it to exit.

    Without this a SIGTERM to this wrapper killed it at once: the kernel
    released the lock while the command it guarded was still running, and the
    next caller took the lock beside it. The lock is released only once the
    command has gone.
    """
    try:
        child = subprocess.Popen(command)
    except OSError as exc:
        print(f"withlock: cannot run {command[0]}: {exc}", file=sys.stderr)
        return 127

    def forward(signum, _frame):
        with contextlib.suppress(ProcessLookupError):
            child.send_signal(signum)

    previous = {s: signal.signal(s, forward) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        code = child.wait()
        # A child killed by signal N reads as 128+N, the way a shell reports it.
        return 128 - code if code < 0 else code
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)


def _lock_inherited_fd(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[0].isdigit():
        print(_USAGE, file=sys.stderr)
        return 2
    fd, lockfile, timeout = int(argv[0]), argv[1], float(argv[2])
    try:
        _acquire(fd, lockfile, timeout)
    except TimeoutError as exc:
        print(f"withlock: {exc}", file=sys.stderr)
        return LOCK_BUSY
    except OSError as exc:
        print(f"withlock: cannot lock {lockfile} on fd {fd}: {exc}", file=sys.stderr)
        return LOCK_BROKEN
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["--fd"]:
        return _lock_inherited_fd(argv[1:])
    if "--" not in argv:
        print(_USAGE, file=sys.stderr)
        return 2
    split = argv.index("--")
    head, command = argv[:split], argv[split + 1 :]
    if len(head) != 2 or not command:
        print(_USAGE, file=sys.stderr)
        return 2

    lockfile, timeout = head[0], float(head[1])
    try:
        with held(lockfile, timeout):
            return _run_forwarding_signals(command)
    except TimeoutError as exc:
        print(f"withlock: {exc}", file=sys.stderr)
        return LOCK_BUSY
    except OSError as exc:
        print(f"withlock: cannot lock {lockfile}: {exc}", file=sys.stderr)
        return LOCK_BROKEN


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
