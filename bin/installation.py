#!/usr/bin/env python3
"""Read foreman's declaration and print it for shell consumers.

    installation.py                  this home's keys
    installation.py --siblings       foreman, and nothing else
    installation.py --write --harness codex [--model-tick M] ...
    installation.py [--home <path>] ...   read <path> instead of this home

Emits NUL-separated KEY, VALUE pairs on stdout: INSTALLATION, HARNESS,
IS_DEFAULT, LEGACY_NAMES, FOREMAN_HOME, FOREMAN_ROOT, TICK_MODEL, PLAN_MODEL,
BUILD_MODEL, REVIEW_MODEL, FALLBACK_TIERS, FALLBACK_COOLDOWN_MINUTES,
PLAN_FLOOR, BUILD_FLOOR, REVIEW_FLOOR. Consumers count fields to detect a
failed load, so
EVERY key is always emitted -- this file follows bin/boards.py in structure,
wire format and refusal style, and boards.py's docstring gives the reasoning
behind all three.

THERE IS ONE FOREMAN. ~/.foreman is the installation: the clone sits at
~/.foreman/install and ~/.foreman/foreman.toml declares the harness, the stage
models and the fallback tiers. The three keys INSTALLATION, IS_DEFAULT and
LEGACY_NAMES are emitted as constants ("foreman", true, true) so a reader that
still asks gets the single, installation-free answer; names carry no
installation segment.

PARSED, NEVER SOURCED, for the reason bin/contract.py gives: foreman shares a
user and a machine with the target repositories, so a config that can run code
runs beside its Linear credential.

Anything this loader cannot make sense of is refused rather than degraded to a
default. A foreman.toml that declares less than its author thought, and says so
with exit code 0, spends the wrong subscription on every card.
"""

from __future__ import annotations

import os
import sys
import tomllib

# ONE FOREMAN. The machine root ~/.foreman IS the installation: the clone sits
# at ~/.foreman/install and ~/.foreman/foreman.toml declares the harness, the
# stage models and the fallback tiers. There is no installation name, no default
# and no siblings -- a card belongs to foreman and its board decides the repo.
CONFIG_FILE = "foreman.toml"
FOREMAN = "foreman"

# The three harnesses skills/board/harness/<harness>.sh implements. A fourth
# name is a typo until an adapter exists for it, and the failure would be a
# tick that spawns nothing.
HARNESSES = ("claude", "codex", "opencode")

# Claude is the harness a home with no foreman.toml runs, and the source of the
# default models and tiers -- see record().
CLAUDE = "claude"

MODELS_TABLE = "models"
FALLBACK_TABLE = "fallback"
TOP_KEYS = {"harness", MODELS_TABLE, FALLBACK_TABLE}

# One model per stage, the same four skills/board/config.sh has always carried.
STAGES = ("tick", "plan", "build", "review")
MODEL_FLAGS = {f"--model-{stage}": stage for stage in STAGES}

# What config.sh defaulted to before foreman.toml could say. A home with no
# foreman.toml spends exactly what it spent yesterday.
CLAUDE_MODELS = {"tick": "fable", "plan": "fable", "build": "opus", "review": "opus"}

# RATE-LIMIT FALLBACK. On 2026-09-16 PLAN_MODEL=fable was rate-limited for 11
# hours, every card needing a plan voided on every pass, and nothing moved.
# skills/board/fallback.py walks a stage DOWN this list, strongest first, while
# a model is rate-limited, and never past the floor the installation declares
# for that stage. This file only declares the list; fallback.py owns the walk.
TIERS_KEY = "tiers"
COOLDOWN_KEY = "cooldown_minutes"
FLOOR_TABLE = "floor"
FALLBACK_KEYS = {TIERS_KEY, COOLDOWN_KEY, FLOOR_TABLE}

# The stages that fall back. Not the tick: skills/board/supervise.sh starts it
# on TICK_MODEL directly and no dispatch ever resolves it, so a tick floor
# would be a declared protection that nothing reads.
FALLBACK_STAGES = ("plan", "build", "review")

# Claude's own models, strongest first. Codex and OpenCode get no list: their
# model names are the operator's to type, and a guessed order would downgrade
# a stage onto a model that installation may not be able to run at all.
CLAUDE_TIERS = ("fable", "opus", "sonnet", "haiku")

# How long a rate-limited model is skipped before a stage tries it again.
DEFAULT_COOLDOWN_MINUTES = 60


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


def foreman_root(home: str) -> str:
    """The root that holds the shared credential.

    There is one foreman and one root: ~/.foreman, which is also its own home.
    The shared files -- linear.key, mcp.json -- live there, and every reader of
    them (bin/boards.py, bin/resolve-ids.py) asks here rather than composing a
    path by hand.
    """
    return home


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


def resolve_tiers(where: str, harness: str, given: object) -> list[str]:
    """The fallback tiers, defaulted per harness. An empty list turns fallback
    off, and declaring `tiers = []` is how a Claude installation says so.

    A tier is a model, or `<harness>:<model>` to name the harness as well, so
    one tick can fall back across CLIs and not only across models."""
    if given is None:
        return list(CLAUDE_TIERS) if harness == CLAUDE else []
    key = f"{FALLBACK_TABLE}.{TIERS_KEY}"
    if not isinstance(given, list):
        die(f"{where}: {key} must be a list of model names, strongest first")
    for tier in given:
        if not isinstance(tier, str) or not tier.strip():
            die(f"{where}: {key} must hold non-empty model names; got {tier!r}")
        # The list reaches bash as ONE space-separated value, so a name holding
        # whitespace would read back as two tiers. A NUL would desynchronize
        # the KEY, VALUE stream.
        if any(ch.isspace() or ch == "\0" for ch in tier):
            die(f"{where}: {key} entry {tier!r} may not contain whitespace or a NUL byte")
        # A tier is `<model>` or `<harness>:<model>`, so it may carry '/' and
        # ':' (a Foundry model is `foundry/gpt-5.6-sol`). fallback.py encodes
        # the stamp's filename, so no character here can escape its directory.
    duplicated = sorted({tier for tier in given if given.count(tier) > 1})
    if duplicated:
        die(f"{where}: {key} names {', '.join(duplicated)} more than once; "
            "the list is an order, and a repeat makes the order ambiguous")
    return list(given)


def resolve_cooldown(where: str, given: object) -> int:
    if given is None:
        return DEFAULT_COOLDOWN_MINUTES
    # `cooldown_minutes = true` loads as an int in Python's eyes. It is a typo.
    if isinstance(given, bool) or not isinstance(given, int) or given <= 0:
        die(f"{where}: {FALLBACK_TABLE}.{COOLDOWN_KEY} must be a positive "
            f"integer number of minutes; got {given!r}")
    return given


def resolve_floors(where: str, tiers: list[str], models: dict, given: object) -> dict:
    """Each stage's floor, or "" where the stage may fall to the list's end.

    A floor outside the tiers is refused: fallback.py stops at the floor, so a
    floor it can never reach is a floor that does not exist, and the operator
    who wrote it believes the stage is protected. A floor ABOVE the stage's own
    model is refused for the same reason -- the walk only goes down, so it
    would never meet it.
    """
    key = f"{FALLBACK_TABLE}.{FLOOR_TABLE}"
    if given is None:
        given = {}
    if not isinstance(given, dict):
        die(f"{where}: {key} must be a table")
    unknown = sorted(set(given) - set(FALLBACK_STAGES))
    if unknown:
        die(f"{where}: unknown key(s) in {key}: {', '.join(unknown)}; "
            f"expected any of {', '.join(FALLBACK_STAGES)}")
    out = {}
    for stage in FALLBACK_STAGES:
        floor = given.get(stage)
        if floor is None:
            out[stage] = ""
            continue
        if not isinstance(floor, str):
            die(f"{where}: {key}.{stage} must be a string")
        if floor not in tiers:
            listed = ", ".join(tiers) if tiers else "none, so fallback is off"
            die(f"{where}: {key}.{stage} is {floor!r}, which is not one of "
                f"{FALLBACK_TABLE}.{TIERS_KEY} ({listed})")
        first = models[stage]
        if first in tiers and tiers.index(floor) < tiers.index(first):
            die(f"{where}: {key}.{stage} is {floor!r}, above the {stage} model "
                f"{first!r}; a stage only falls back down, so it would never reach it")
        out[stage] = floor
    return out


def resolve_fallback(where: str, harness: str, models: dict, table: object) -> dict:
    """The [fallback] table, defaulted: {"tiers", "cooldown", "floors"}."""
    if table is None:
        table = {}
    if not isinstance(table, dict):
        die(f"{where}: {FALLBACK_TABLE} must be a table")
    unknown = sorted(set(table) - FALLBACK_KEYS)
    if unknown:
        die(f"{where}: unknown key(s) in {FALLBACK_TABLE}: {', '.join(unknown)}")
    tiers = resolve_tiers(where, harness, table.get(TIERS_KEY))
    return {
        "tiers": tiers,
        "cooldown": resolve_cooldown(where, table.get(COOLDOWN_KEY)),
        "floors": resolve_floors(where, tiers, models, table.get(FLOOR_TABLE)),
    }


def record(home: str) -> list[str]:
    """The KEY, VALUE fields for the one foreman home.

    The harness, models and fallback tiers come from `<home>/foreman.toml` when
    it exists, and from Claude's defaults when it does not -- so a bare
    `~/.foreman/install` clone still answers. Nothing here names a second
    installation, checks a default, or lists a sibling.
    """
    path = os.path.join(home, CONFIG_FILE)
    if os.path.isfile(path):
        harness, models, fallback = parse_config(path)
    else:
        harness = CLAUDE
        models = dict(CLAUDE_MODELS)
        fallback = resolve_fallback(path, CLAUDE, models, None)
    return fields(FOREMAN, harness, home, models, fallback)


def parse_config(path: str) -> tuple[str, dict, dict]:
    """foreman.toml as (harness, models, fallback), refusing rather than degrading."""
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

    models = resolve_models(path, harness, table)
    fallback = resolve_fallback(path, harness, models, doc.get(FALLBACK_TABLE))
    return harness, models, fallback


def fields(name: str, harness: str, home: str, models: dict, fallback: dict) -> list[str]:
    # INSTALLATION is always "foreman", IS_DEFAULT always true and LEGACY_NAMES
    # always set, so names carry no installation segment. They stay in the wire
    # format for readers that still ask; there is nothing else they could be.
    # FALLBACK_TIERS "" means fallback is off; a *_FLOOR "" means the stage may
    # fall to the bottom of the tiers.
    return [
        "INSTALLATION", name,
        "HARNESS", harness,
        "IS_DEFAULT", "1",
        "LEGACY_NAMES", "1",
        "FOREMAN_HOME", home,
        "FOREMAN_ROOT", home,
        "TICK_MODEL", models["tick"],
        "PLAN_MODEL", models["plan"],
        "BUILD_MODEL", models["build"],
        "REVIEW_MODEL", models["review"],
        "FALLBACK_TIERS", " ".join(fallback["tiers"]),
        "FALLBACK_COOLDOWN_MINUTES", str(fallback["cooldown"]),
        "PLAN_FLOOR", fallback["floors"]["plan"],
        "BUILD_FLOOR", fallback["floors"]["build"],
        "REVIEW_FLOOR", fallback["floors"]["review"],
    ]


def toml_string(value: str) -> str:
    """<value> as a TOML basic string. Escaping backslash and double-quote is
    every case that can occur in a harness or a model name."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render(harness: str, models: dict, fallback: dict) -> str:
    """foreman.toml as text. tomllib reads TOML and cannot write it, and a
    writer is not worth a dependency for a handful of two-token keys."""
    lines = [
        "# What foreman is: the harness it runs on, the models it spends, and the",
        "# tiers it falls back through. Written by bin/install.sh;",
        "# bin/installation.py reads it.",
        "",
        f"harness = {toml_string(harness)}",
        "",
        f"[{MODELS_TABLE}]",
    ]
    lines += [f"{stage} = {toml_string(models[stage])}" for stage in STAGES]
    lines += [
        "",
        f"[{FALLBACK_TABLE}]",
        f"{TIERS_KEY} = [{', '.join(toml_string(tier) for tier in fallback['tiers'])}]",
        f"{COOLDOWN_KEY} = {fallback['cooldown']}",
    ]
    return "\n".join(lines) + "\n"


def write(home: str, harness: str | None, given: dict, dry_run: bool) -> None:
    """Write <home>/foreman.toml, refusing to overwrite one that exists."""
    if harness is None:
        die(f"--write needs --harness (one of {', '.join(HARNESSES)})")
    if harness not in HARNESSES:
        die(f"--write: unknown harness {harness!r}; "
            f"expected one of {', '.join(HARNESSES)}")
    if not os.path.isdir(home):
        die(f"no home at {home}; clone into {home}/install first")
    # Validated BEFORE the file exists, so a codex write with a model missing
    # refuses instead of writing something no reader will accept.
    models = resolve_models("--write", harness, given)
    fallback = resolve_fallback("--write", harness, models, None)

    path = os.path.join(home, CONFIG_FILE)
    if dry_run:
        if os.path.exists(path):
            die(f"{path} already exists; edit or remove it, this never overwrites one")
        return
    # O_EXCL, not a stat and then a write: the refusal to overwrite is the whole
    # safety of this command, and a check separate from the write is a window in
    # which a second write lands.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        die(f"{path} already exists; edit or remove it, this never overwrites one")
    except OSError as exc:
        die(f"cannot write {path}: {exc}")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(render(harness, models, fallback))
        # Read back what was written, through the real loader. It proves the
        # text this file emitted parses. A refused read leaves the home as it
        # was found, which is why the file goes away again.
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
        "[--siblings | --write --harness <name> [--model-<stage> <model>] [--dry-run]]")


def main(argv: list[str]) -> int:
    home = None
    want_siblings = False
    want_write = False
    harness = None
    dry_run = False
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
        elif arg == "--dry-run":
            dry_run = True
        else:
            usage()
    if want_siblings and want_write:
        usage()

    if home is None:
        home = os.path.normpath(foreman_home())
    if want_write:
        write(home, harness, models, dry_run)
        return 0
    # A flag that only --write reads, passed to a read, means the operator
    # believes they are writing. Saying nothing would print a record that
    # ignores every model they named.
    if harness is not None or models or dry_run:
        die("--harness, --model-<stage> and --dry-run are only for --write")

    if not want_siblings:
        emit(record(home))
        return 0
    # There is one foreman. `--siblings` answers with it and nothing else, so a
    # caller that still asks -- the tick composing queue.py's arguments -- gets
    # the single, installation-free answer.
    emit([FOREMAN, home])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
