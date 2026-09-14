#!/usr/bin/env python3
"""Read this installation's declaration and print it for shell consumers.

    installation.py                  this home's keys
    installation.py --siblings       every installation under FOREMAN_ROOT
    installation.py --write --harness codex [--default] [--model-tick M] ...
    installation.py [--home <path>] ...   read <path> instead of this home

Emits NUL-separated KEY, VALUE pairs on stdout: INSTALLATION, HARNESS,
IS_DEFAULT, FOREMAN_HOME, FOREMAN_ROOT, TICK_MODEL, PLAN_MODEL, BUILD_MODEL,
REVIEW_MODEL. Consumers count fields to detect a failed load, so EVERY key is
always emitted -- this file follows bin/boards.py in structure, wire format and
refusal style, and boards.py's docstring gives the reasoning behind all three.

One machine runs several installations at once, each on its own harness. The
machine root holds one directory per installation, and this file is what says
which one it is looking at.

PARSED, NEVER SOURCED, for the reason bin/contract.py gives: installations
share a user and a machine root, so a config that can run code runs beside
every installation's Linear credential.

Anything this loader cannot make sense of is refused rather than degraded to a
default. An installation.toml that declares less than its author thought, and
says so with exit code 0, spends the wrong subscription on every card.
"""

from __future__ import annotations

import os
import re
import sys
import tomllib

INSTALLATION_FILE = "installation.toml"

# The three harnesses skills/board/harness/<harness>.sh implements. A fourth
# name is a typo until an adapter exists for it, and the failure would be a
# tick that spawns nothing.
HARNESSES = ("claude", "codex", "opencode")

# Claude is both a harness and the name of the installation a home without an
# installation.toml turns out to be -- see record() for why those are the same
# fact.
CLAUDE = "claude"

MODELS_TABLE = "models"
TOP_KEYS = {"harness", "default", MODELS_TABLE}

# One model per stage, the same four skills/board/config.sh has always carried.
STAGES = ("tick", "plan", "build", "review")
MODEL_FLAGS = {f"--model-{stage}": stage for stage in STAGES}

# What config.sh defaulted to before an installation could say. Claude keeps
# them so an un-migrated home spends exactly what it spent yesterday.
CLAUDE_MODELS = {"tick": "fable", "plan": "fable", "build": "opus", "review": "opus"}

# The board-name rule, and it is here for the board-name failure: an
# installation name is pasted into worktree globs, agent names and a Linear
# label, all of which join their segments with a hyphen or a slash. See
# bin/boards.py's BOARD_NAME for the case that was measured.
INSTALLATION_NAME = re.compile(r"^[A-Za-z0-9_]+$")


def die(message: str) -> None:
    sys.stderr.write(f"installation: {message}\n")
    raise SystemExit(1)


def install_root() -> str:
    """This clone's root -- the parent of bin/, resolved through any symlink."""
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def foreman_home() -> str:
    """This installation's home: $FOREMAN_HOME, else the parent of the clone.

    IDENTITY COMES FROM THE PATH. A clone at ~/.foreman/codex/install belongs
    to the installation `codex` because of where it sits, and nothing inside
    the clone may disagree -- the clone is the same git checkout in every
    installation on the machine, so a name written into it would be the same
    name for all of them.

    Empty counts as unset, matching config.sh's `${FOREMAN_HOME:-...}`. Tests
    point this at a temporary directory; nothing here may touch the real one.
    """
    declared = os.environ.get("FOREMAN_HOME")
    if declared:
        return absolute(declared, "FOREMAN_HOME")
    return os.path.dirname(install_root())


def absolute(path: str, what: str) -> str:
    """Expand ~ and refuse anything still relative.

    A relative home would resolve against the caller's working directory,
    which differs between a tick, a sweep and an operator's shell, so the same
    argument would name three different installations.
    """
    expanded = os.path.expanduser(path)
    if not os.path.isabs(expanded):
        die(f"{what} must be an absolute path (or start with ~): {path}")
    return os.path.normpath(expanded)


def validate_name(home: str, name: str) -> None:
    if not INSTALLATION_NAME.match(name):
        die(f"{home}: installation name {name!r} is invalid; "
            "only letters, digits and underscore are allowed (no hyphen, no slash)")


def declared(home: str) -> bool:
    """Whether <home> holds an installation.toml, which is what makes a
    directory an installation. Asked in one place so a home and a sibling can
    never be judged by two different tests."""
    return os.path.isfile(os.path.join(home, INSTALLATION_FILE))


def foreman_root(home: str) -> str:
    """The machine root that holds <home>: its parent when the home is a
    declared installation, and the home itself in the un-migrated layout.

    The shared files -- linear.key, mcp.json -- live at the root, and every
    reader of them (bin/boards.py, bin/resolve-ids.py) asks here rather than
    joining against FOREMAN_HOME. On 2026-09-14 both did the latter and a
    migrated installation pointed at a key file migration had deliberately
    left one level up. No test caught it because config.sh never checks the
    key exists; the refusal would have landed in resolve-ids.py on a real
    machine.
    """
    return os.path.dirname(home) if declared(home) else home


def load_toml(path: str) -> dict:
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        die(f"no installation declaration at {path}")
    except IsADirectoryError:
        die(f"{path} is a directory, not an {INSTALLATION_FILE}")
    except tomllib.TOMLDecodeError as exc:
        die(f"{path} is not valid TOML: {exc}")
    except OSError as exc:
        die(f"cannot read {path}: {exc}")
    return {}


def default_flag(where: str, doc: dict) -> bool:
    """What <doc> DECLARES about default, which is not the same as the answer.

    A lone installation is the default whatever its file says -- record() owns
    that rule and explains it. This function reports the declaration only, so
    the sibling count stays the one thing that decides the rest.

    Read on its own, separately from the rest of a declaration, because every
    read of any installation checks every sibling for it. A sibling whose
    models are wrong is that sibling's problem; a sibling whose `default` this
    loader cannot read is everyone's problem, because the answer to "how many
    siblings claim default" is then unknown rather than a number.
    """
    value = doc.get("default", False)
    # `default = 1` loads as an int and would read as deliberate. It is a
    # typo, and a typo that decides which subscription an unlabelled card
    # spends is not one to guess at.
    if not isinstance(value, bool):
        die(f"{where}: default must be true or false")
    return value


def resolve_models(where: str, harness: str, given: dict) -> dict:
    """The four stage models, defaulted for Claude and required for the rest.

    Codex and OpenCode have NO defaults, on purpose. A wrong model name on
    those harnesses is not refused when the agent is spawned: the harness runs
    detached, fails somewhere inside its own log, and the card just never
    moves. Refusing here puts the error in front of the operator who typed it.
    """
    out = {}
    for stage in STAGES:
        value = given.get(stage)
        if value is None:
            if harness != CLAUDE:
                die(f"{where}: harness {harness} declares no {stage} model; "
                    f"{harness} has no default, so name all of "
                    f"{', '.join(STAGES)} explicitly")
            out[stage] = CLAUDE_MODELS[stage]
            continue
        if not isinstance(value, str):
            die(f"{where}: {MODELS_TABLE}.{stage} must be a string")
        if not value.strip():
            die(f"{where}: {MODELS_TABLE}.{stage} may not be empty; "
                "omit the key where the harness has a default")
        # A NUL byte would desynchronize the KEY, VALUE stream below, so every
        # later key a consumer read would be off by one field.
        if "\0" in value:
            die(f"{where}: {MODELS_TABLE}.{stage} may not contain a NUL byte")
        out[stage] = value
    return out


def parse(path: str) -> tuple[str, bool, dict]:
    """One installation.toml as (harness, is_default, models)."""
    doc = load_toml(path)
    unknown = sorted(set(doc) - TOP_KEYS)
    if unknown:
        die(f"{path}: unknown key(s): {', '.join(unknown)}")

    harness = doc.get("harness")
    if harness is None:
        die(f"{path}: declares no harness; expected one of {', '.join(HARNESSES)}")
    if not isinstance(harness, str):
        die(f"{path}: harness must be a string")
    if harness not in HARNESSES:
        die(f"{path}: unknown harness {harness!r}; expected one of {', '.join(HARNESSES)}")

    table = doc.get(MODELS_TABLE, {})
    if not isinstance(table, dict):
        die(f"{path}: {MODELS_TABLE} must be a table")
    unknown = sorted(set(table) - set(STAGES))
    if unknown:
        die(f"{path}: unknown key(s) in {MODELS_TABLE}: {', '.join(unknown)}")

    return harness, default_flag(path, doc), resolve_models(path, harness, table)


def installations(root: str) -> list[tuple[str, str, bool]]:
    """(name, home, is_default) for every installation under <root>, by name.

    Self is one of them, because declared() is the same test record() makes
    about its own home: an installation can never be invisible to the default
    check below by being the one doing the asking.
    """
    try:
        entries = sorted(os.listdir(root))
    except OSError as exc:
        die(f"cannot list the installations under {root}: {exc}")
    out = []
    for name in entries:
        home = os.path.join(root, name)
        if not declared(home):
            continue
        validate_name(home, name)
        path = os.path.join(home, INSTALLATION_FILE)
        out.append((name, home, default_flag(path, load_toml(path))))
    return out


def refuse_unless_one_default(root: str, entries: list[tuple[str, str, bool]]) -> None:
    """Siblings need exactly one default. Checked on EVERY read of any of them.

    TWO DEFAULTS. Two installations that both claim the unlabelled cards
    dispatch the same card twice, against one machine's HOST_MAX_CONCURRENT,
    and neither tick can see the other doing it. Refusing here means the
    second one refuses before it starts rather than after both have
    dispatched.

    ZERO DEFAULTS, once there is more than one installation, is refused the
    same way and for a louder reason. Every card that carries no `foreman:*`
    label belongs to the default, so with no default skills/board/queue.py
    drops all of them as FOREIGN and exits 0: every tick on the machine
    reports a healthy, empty board while the cards sit in Todo forever. A
    silent stop is worse than a refusal, so this is the refusal.

    This never applies to a lone installation: record() makes that one the
    default whatever its file says, and there is no second reader to disagree
    with.
    """
    claimed = [name for name, _, is_default in entries if is_default]
    if len(claimed) > 1:
        die(f"{root}: {len(claimed)} installations claim default = true "
            f"({', '.join(claimed)}); exactly one may")
    if len(entries) > 1 and not claimed:
        names = ", ".join(name for name, _, _ in entries)
        # Naming the fix as a file edit, not a command: --write refuses to
        # overwrite an installation.toml that exists, so there is no command
        # here that could change an existing installation's default.
        die(f"{root}: {len(entries)} installations ({names}) and none claims "
            "default = true, so every card with no foreman:<name> label would "
            "belong to no installation; set default = true in exactly one "
            f"{INSTALLATION_FILE} by hand")


def record(home: str) -> list[str]:
    """The KEY, VALUE fields for one home."""
    # A HOME WITH NO installation.toml IS A LONE CLAUDE INSTALLATION. That is
    # exactly the layout every machine had before installations existed: the
    # clone sits directly under ~/.foreman beside boards.toml and instances/.
    # Such a home must keep working unmigrated, so this loader answers for it
    # rather than leaving every consumer to guess -- and it has no siblings,
    # because a root that holds one un-migrated home holds no installations.
    if not declared(home):
        return fields(CLAUDE, CLAUDE, True, home, home, CLAUDE_MODELS)

    path = os.path.join(home, INSTALLATION_FILE)
    name = os.path.basename(home)
    validate_name(home, name)
    root = foreman_root(home)
    harness, declares_default, models = parse(path)
    entries = installations(root)
    refuse_unless_one_default(root, entries)
    # AN INSTALLATION WITH NO SIBLING IS THE DEFAULT, whatever its file says.
    # One installation on the machine is the common case, and it must own
    # every card: there is no other installation for an unlabelled card to
    # belong to. On 2026-09-14 it did not. The documented first install --
    # `install.sh --harness claude`, no --default -- wrote `default = false`,
    # so IS_DEFAULT came back empty, skills/board/queue.py dropped every
    # unlabelled card as FOREIGN and exited 0, and a board installed exactly
    # as the README says never dispatched anything and never said why.
    is_default = declares_default or len(entries) == 1
    return fields(name, harness, is_default, home, root, models)


def fields(name: str, harness: str, is_default: bool, home: str,
           root: str, models: dict) -> list[str]:
    # IS_DEFAULT is the one key whose empty value is meaningful: config.sh
    # tests it with `-n`, so "" is false and "1" is true. Every other key here
    # refuses to be empty.
    return [
        "INSTALLATION", name,
        "HARNESS", harness,
        "IS_DEFAULT", "1" if is_default else "",
        "FOREMAN_HOME", home,
        "FOREMAN_ROOT", root,
        "TICK_MODEL", models["tick"],
        "PLAN_MODEL", models["plan"],
        "BUILD_MODEL", models["build"],
        "REVIEW_MODEL", models["review"],
    ]


def toml_string(value: str) -> str:
    """<value> as a TOML basic string. Escaping backslash and double-quote is
    every case that can occur in a harness or a model name."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render(harness: str, is_default: bool, models: dict) -> str:
    """installation.toml as text. tomllib reads TOML and cannot write it, and
    a writer is not worth a dependency for eight lines of two-token keys."""
    lines = [
        "# What this installation is: the harness that runs it, and the models",
        "# it spends. Written by bin/install.sh; bin/installation.py reads it.",
        "",
        f"harness = {toml_string(harness)}",
        f"default = {'true' if is_default else 'false'}",
        "",
        f"[{MODELS_TABLE}]",
    ]
    lines += [f"{stage} = {toml_string(models[stage])}" for stage in STAGES]
    return "\n".join(lines) + "\n"


def write(home: str, harness: str | None, is_default: bool, given: dict) -> None:
    """Declare <home> an installation, refusing to overwrite one that exists."""
    if harness is None:
        die(f"--write needs --harness (one of {', '.join(HARNESSES)})")
    if harness not in HARNESSES:
        die(f"--write: unknown harness {harness!r}; "
            f"expected one of {', '.join(HARNESSES)}")
    if not os.path.isdir(home):
        die(f"no installation directory at {home}; "
            "clone into <root>/<name>/install first")
    validate_name(home, os.path.basename(home))
    # Validated BEFORE the file exists, by the same function that validates a
    # file being read, so a codex write with a model missing refuses instead
    # of writing something no reader will accept.
    models = resolve_models("--write", harness, given)

    path = os.path.join(home, INSTALLATION_FILE)
    # O_EXCL, not a stat and then a write: the refusal to overwrite is the
    # whole safety of this command, and a check separate from the write is a
    # window in which a second operator's install lands.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        die(f"{path} already exists; edit or remove it, this never overwrites one")
    except OSError as exc:
        die(f"cannot write {path}: {exc}")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(render(harness, is_default, models))
        # Read back what was written, through the real loader. It proves the
        # text this file emitted parses, and it applies the sibling check --
        # so `--write --default` beside an existing default refuses, and so
        # does a second installation written while no sibling claims default.
        # A refused write leaves the home exactly as it was found, which is
        # why the file goes away again before the exit propagates.
        record(home)
    except (OSError, SystemExit):
        os.unlink(path)
        raise


def emit(out: list[str]) -> None:
    if not out:
        return
    sys.stdout.buffer.write(b"\0".join(field.encode() for field in out) + b"\0")


def usage() -> None:
    die("usage: installation.py [--home <path>] "
        "[--siblings | --write --harness <name> [--default] [--model-<stage> <model>]]")


def main(argv: list[str]) -> int:
    home = None
    want_siblings = False
    want_write = False
    harness = None
    is_default = False
    models = {}

    rest = argv[1:]

    def value_for(flag: str) -> str:
        if not rest:
            die(f"{flag} needs a value")
        return rest.pop(0)

    while rest:
        arg = rest.pop(0)
        if arg == "--home":
            home = absolute(value_for(arg), "--home")
        elif arg == "--harness":
            harness = value_for(arg)
        elif arg in MODEL_FLAGS:
            models[MODEL_FLAGS[arg]] = value_for(arg)
        elif arg == "--siblings":
            want_siblings = True
        elif arg == "--write":
            want_write = True
        elif arg == "--default":
            is_default = True
        else:
            usage()
    if want_siblings and want_write:
        usage()

    if home is None:
        home = os.path.normpath(foreman_home())
    if want_write:
        write(home, harness, is_default, models)
        return 0
    # A flag that only --write reads, passed to a read, means the operator
    # believes they are writing. Saying nothing would print a record that
    # ignores every model they named.
    if harness is not None or is_default or models:
        die("--harness, --default and --model-<stage> are only for --write")

    if not want_siblings:
        emit(record(home))
        return 0
    # An un-migrated home is its own only installation: there is no root full
    # of siblings to list, because the root IS the home.
    if not declared(home):
        emit([CLAUDE, home])
        return 0
    root = os.path.dirname(home)
    entries = installations(root)
    refuse_unless_one_default(root, entries)
    out = []
    for name, sibling_home, _ in entries:
        out += [name, sibling_home]
    emit(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
