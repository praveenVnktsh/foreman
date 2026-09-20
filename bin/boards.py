#!/usr/bin/env python3
"""Read this machine's board declarations and print them for shell consumers.

    boards.py --list                 every board name
    boards.py --names                every board name, checking names only
    boards.py <name>                 one board's REPO and KEY_FILE
    boards.py [--file <path>] ...    read <path> instead of $FOREMAN_HOME/boards.toml

Emits NUL-separated fields on stdout: bare names for --list, KEY, VALUE pairs
for a single board. Consumers count fields to detect a failed load, so EVERY
key is always emitted -- see bin/contract.py's docstring, which this file
follows in structure, wire format and refusal style.

A board is ONE declared fact: the local path of the repository it builds.
Everything else about it -- the Linear team, the project -- is read from that
repository's own board.toml, because the repository declares itself. Duplicating
the team name in a second file on this machine is a copy that drifts.

PARSED, NEVER SOURCED, for the reason contract.py gives: boards share a user
and a home, so a config that can run code runs beside every board's Linear
credential.

Anything this loader cannot make sense of is refused rather than degraded to a
default. A boards.toml that declares less than its author thought, and says so
with exit code 0, sends a tick agent to the wrong repository.
"""

from __future__ import annotations

import os
import re
import sys
import tomllib

# Same bin/ directory. The root that holds the shared credential is a fact
# about the installation, so it is asked of the installation loader rather
# than derived a second time here.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installation  # noqa: E402

# The one top-level table. A stray `[board]` or `[instances]` is a typo that
# would otherwise declare nothing at all, silently.
BOARDS_TABLE = "boards"

# What a board may say about itself. `repo` is required. `key` is optional and
# names a credential for a board that lives in a DIFFERENT Linear workspace;
# every board in the usual single-workspace setup shares
# $FOREMAN_ROOT/linear.key -- foreman's home, which is also the machine root,
# so one key answers for every board -- which is why the per-instance copy of
# that same secret is gone.
BOARD_KEYS = {"repo", "key", "priority"}

# How this MACHINE divides its own capacity between repositories when they
# compete for HOST_MAX_CONCURRENT.
#
# It lives here and NOT in a target's board.toml, for the reason bin/contract.py
# gives about ids: a repository is not trusted to declare how much of somebody
# else's machine it deserves. Every target would declare itself important.
#
# Default 1, so a boards.toml written before this existed divides evenly and
# nothing changes underneath an operator who never asked for priorities.
DEFAULT_PRIORITY = 1

DEFAULT_KEY_FILE = "linear.key"

# No hyphen, no slash. This is the same constraint skills/board/config.sh puts
# on FOREMAN_INSTANCE, and it is here for the same failure: worktree_path and
# every worktree/scratch glob in sweep.sh join the board name and the ticket
# with a HYPHEN (foreman-<board>-<ticket>), which an unconstrained name
# absorbs. A board named alpha-x makes "foreman-alpha-x-PRA-1" match the glob
# "foreman-alpha-*", so alpha's sweep reaps alpha-x's worktrees on a shared
# repository. Any separator can be absorbed by an unconstrained name, so the
# name is what has to be closed. Underscores stay legal so `target_staging` is
# still sayable.
BOARD_NAME = re.compile(r"^[A-Za-z0-9_]+$")


def die(message: str) -> None:
    sys.stderr.write(f"boards: {message}\n")
    raise SystemExit(1)


def foreman_home() -> str:
    """This installation's home, asked of bin/installation.py.

    $FOREMAN_HOME when it is set, else the parent of this clone -- identity
    comes from the path, so a clone at ~/.foreman/codex/install reads the codex
    installation's boards.toml. Deriving it here instead would be a second
    copy: it used to default to ~/.foreman, which is the machine ROOT now and
    holds no boards.toml at all, so every clone but a legacy one read the wrong
    file or none.

    Empty counts as unset, matching config.sh's `${FOREMAN_HOME:-...}`. Tests
    point this at a temporary directory; nothing here may touch the real one.
    """
    return installation.foreman_home()


def absolute(path: str, what: str, board: str) -> str:
    """Expand ~ and refuse anything still relative.

    A relative path would be resolved against the caller's working directory,
    which differs between a tick agent, a sweep and an operator's shell. The
    same boards.toml would then name three different repositories, and the
    directory-exists check below would pass for whichever one happened to be
    under the cwd of the moment.
    """
    expanded = os.path.expanduser(path)
    if not os.path.isabs(expanded):
        die(f"board {board}: {what} must be an absolute path (or start with ~): {path}")
    return os.path.normpath(expanded)


def check_board_shape(path: str, name: str, table: object) -> None:
    """The checks on one board that depend on the file alone: its name, that
    it is a table, and that it says nothing unknown."""
    if not BOARD_NAME.match(name):
        die(f"{path}: board name {name!r} is invalid; "
            "only letters, digits and underscore are allowed (no hyphen, no slash)")
    if not isinstance(table, dict):
        die(f"{path}: board {name} must be a table")
    unknown = sorted(set(table) - BOARD_KEYS)
    if unknown:
        die(f"{path}: unknown key(s) in board {name}: {', '.join(unknown)}")


def board_record(path: str, home: str, name: str, table: object) -> tuple[str, str]:
    """Validate one board and return its (REPO, KEY_FILE)."""
    check_board_shape(path, name, table)

    repo = table.get("repo")
    if repo is None:
        die(f"{path}: board {name} declares no repo")
    if not isinstance(repo, str):
        die(f"{path}: board {name}: repo must be a string")
    if not repo.strip():
        die(f"{path}: board {name}: repo may not be empty")
    if "\0" in repo:
        die(f"{path}: board {name}: repo may not contain a NUL byte")
    repo = absolute(repo, "repo", name)
    # A board whose repository is gone is not a board with a stale path to
    # tolerate: every worktree, every dispatch and every sweep starts here.
    if not os.path.isdir(repo):
        die(f"{path}: board {name}: repo is not a directory: {repo}")

    priority = table.get("priority", DEFAULT_PRIORITY)
    # `True` is an int in Python, and `priority = true` in TOML would otherwise
    # load as 1 and read as deliberate. It is a typo, and this loader refuses
    # what it cannot make sense of rather than guessing.
    if isinstance(priority, bool) or not isinstance(priority, int):
        die(f"{path}: board {name}: priority must be a non-negative integer")
    if priority < 0:
        die(f"{path}: board {name}: priority may not be negative")

    key = table.get("key")
    if key is None:
        return repo, os.path.join(installation.foreman_root(home), DEFAULT_KEY_FILE), priority
    if not isinstance(key, str):
        die(f"{path}: board {name}: key must be a string")
    # `key = ""` reads as "this board declares its own credential" and would
    # then silently fall back to the shared one -- the degrade this loader
    # exists to prevent. Omit the line to get the default.
    if not key.strip():
        die(f"{path}: board {name}: key may not be empty; omit it to use the default")
    if "\0" in key:
        die(f"{path}: board {name}: key may not contain a NUL byte")
    return repo, absolute(key, "key", name), priority


def load(path: str, home: str) -> list[tuple[str, str, str, int]]:
    """(name, REPO, KEY_FILE, PRIORITY) for every declared board, sorted by name."""
    boards = boards_table(path)
    out = []
    for name in sorted(boards):
        repo, key_file, priority = board_record(path, home, name, boards[name])
        out.append((name, repo, key_file, priority))
    return out


def names_only(path: str) -> list[str]:
    """Every declared board name, sorted, with no repo or key check.

    For bin/installation.py's collision check, which compares names with
    sibling installation names. A repo on an unmounted disk does not change a
    board's name, and refusing it there made every installation under the
    root refuse to load.
    """
    boards = boards_table(path)
    for name in sorted(boards):
        check_board_shape(path, name, boards[name])
    return sorted(boards)


def boards_table(path: str) -> dict:
    """The [boards] table of the file at <path>, refusing a file that is not one."""
    try:
        with open(path, "rb") as fh:
            doc = tomllib.load(fh)
    except FileNotFoundError:
        die(f"no board declarations at {path}")
    except IsADirectoryError:
        die(f"{path} is a directory, not a boards.toml")
    except tomllib.TOMLDecodeError as exc:
        die(f"{path} is not valid TOML: {exc}")

    unknown = sorted(set(doc) - {BOARDS_TABLE})
    if unknown:
        die(f"{path}: unknown section(s): {', '.join(unknown)}")
    # An absent or empty [boards] is a truthful "this machine runs no boards
    # yet", not a degrade: it is what a fresh installation holds before the
    # first board is added. --list then prints nothing, and the single-board
    # form still refuses by name.
    boards = doc.get(BOARDS_TABLE, {})
    if not isinstance(boards, dict):
        die(f"{path}: {BOARDS_TABLE} must be a table")
    return boards


def emit(fields: list[str]) -> None:
    if not fields:
        return
    sys.stdout.buffer.write(b"\0".join(field.encode() for field in fields) + b"\0")


def main(argv: list[str]) -> int:
    home = foreman_home()
    path = os.path.join(home, "boards.toml")
    args = []
    rest = argv[1:]
    while rest:
        arg = rest.pop(0)
        if arg == "--file":
            if not rest:
                die("--file needs a path")
            path = rest.pop(0)
            continue
        args.append(arg)
    if len(args) != 1:
        die("usage: boards.py [--file <path>] --list | --names | <board-name>")

    if args[0] == "--names":
        emit(names_only(path))
        return 0

    boards = load(path, home)
    if args[0] == "--list":
        emit([name for name, _, _, _ in boards])
        return 0

    for name, repo, key_file, priority in boards:
        if name == args[0]:
            emit(["REPO", repo, "KEY_FILE", key_file, "PRIORITY", str(priority)])
            return 0
    die(f"{path}: no board named {args[0]}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
