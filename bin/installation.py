#!/usr/bin/env python3
"""Read this installation's declaration and print it for shell consumers.

    installation.py                  this home's keys
    installation.py --siblings       every installation under FOREMAN_ROOT
    installation.py --write --harness codex [--default] [--legacy-names] [--model-tick M] ...
    installation.py [--home <path>] ...   read <path> instead of this home

Emits NUL-separated KEY, VALUE pairs on stdout: INSTALLATION, HARNESS, ROUTING,
IS_DEFAULT, LEGACY_NAMES, FOREMAN_HOME, FOREMAN_ROOT, TICK_MODEL, TICK_MODELS,
PLAN_MODEL, PLAN_MODELS, BUILD_MODEL, BUILD_MODELS, REVIEW_MODEL, REVIEW_MODELS.
Consumers count fields to detect a failed load, so EVERY key is always emitted --
this file follows bin/boards.py in structure, wire format and refusal style, and
boards.py's docstring gives the reasoning behind all three.

A stage carries an ordered list of candidate models. `<STAGE>_MODEL` is the
first candidate, so the operator override both keys already had keeps working;
`<STAGE>_MODELS` is the whole list, newline-separated, which dispatch walks when
the first candidate is unavailable. See
docs/specs/2026-09-18-project-level-installs-design.md.

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
import subprocess
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
NAMES_KEY = "names"
TOP_KEYS = {"harness", "default", NAMES_KEY, MODELS_TABLE, "routing"}

# How a card reaches this installation. `label` (the default) routes by the
# `foreman:<name>` card label, with the default installation owning unlabelled
# cards -- the model for several installations serving one board.
# `project` routes by the card's project: this installation serves exactly one
# board, so every card in that board's project is its own and labels are
# decoration. See docs/specs/2026-09-18-project-level-installs-design.md.
ROUTING_KEY = "routing"
LABEL_ROUTING = "label"
PROJECT_ROUTING = "project"
ROUTINGS = (LABEL_ROUTING, PROJECT_ROUTING)

# The two shapes an installation's names may take. skills/board/config.sh
# composes both from LEGACY_NAMES and spells each one out.
#
# "legacy" exists for one machine state, not as a style choice. A Claude home
# installed before installations existed has open pull requests on branches
# named foreman/<board>/<ticket>. skills/board/reconcile.py finds a card's pull
# request with `gh pr list --head <branch>`, so renaming the branch shape under
# those cards makes every one of them read "no agent, no PR", and the board
# dispatches a fresh build on top of an open pull request. The installation
# that already exists keeps the old shapes. Every installation created from
# now on is "scoped".
SCOPED_NAMES = "scoped"
LEGACY_NAMES = "legacy"
NAMES = (SCOPED_NAMES, LEGACY_NAMES)

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


def legacy_names_flag(where: str, doc: dict) -> bool:
    """Whether <doc> declares `names = "legacy"`. Omitted means scoped.

    Read on its own, like default_flag(), because every read of any
    installation checks every sibling for it. Two legacy siblings share every
    name, so a sibling whose `names` this loader cannot read makes "is this
    root safe" unknown rather than yes.
    """
    value = doc.get(NAMES_KEY, SCOPED_NAMES)
    # `names = true` is a typo. A typo that decides which branch a card's pull
    # request is looked up by is not one to guess at.
    if not isinstance(value, str):
        die(f"{where}: {NAMES_KEY} must be a string, one of {', '.join(NAMES)}")
    if value not in NAMES:
        die(f"{where}: unknown {NAMES_KEY} {value!r}; expected one of {', '.join(NAMES)}")
    return value == LEGACY_NAMES


def resolve_models(where: str, harness: str, given: dict) -> dict:
    """The four stage models as ordered candidate lists.

    Codex and OpenCode have NO defaults, on purpose. A wrong model name on
    those harnesses is not refused when the agent is spawned: the harness runs
    detached, fails somewhere inside its own log, and the card just never
    moves. Refusing here puts the error in front of the operator who typed it.

    A stage value is a string (one candidate) or a list (ordered candidates,
    first tried first). Claude's defaults are single candidates.
    """
    out = {}
    for stage in STAGES:
        value = given.get(stage)
        if value is None:
            if harness != CLAUDE:
                die(f"{where}: harness {harness} declares no {stage} model; "
                    f"{harness} has no default, so name all of "
                    f"{', '.join(STAGES)} explicitly")
            out[stage] = [CLAUDE_MODELS[stage]]
            continue
        candidates = value if isinstance(value, list) else [value]
        out[stage] = [model_candidate(where, stage, item) for item in candidates]
    return out


def model_candidate(where: str, stage: str, value: object) -> str:
    """One candidate string, or a refusal naming why it cannot be a model."""
    if not isinstance(value, str):
        die(f"{where}: {MODELS_TABLE}.{stage} must be a string or a list of strings")
    if not value.strip():
        die(f"{where}: {MODELS_TABLE}.{stage} may not be empty; "
            "omit the key where the harness has a default")
    # A NUL byte would desynchronize the KEY, VALUE stream below, so every
    # later key a consumer read would be off by one field.
    if "\0" in value:
        die(f"{where}: {MODELS_TABLE}.{stage} may not contain a NUL byte")
    # A newline separates candidates in <STAGE>_MODELS. A candidate holding one
    # would split into two candidates that both look fine downstream.
    if "\n" in value:
        die(f"{where}: {MODELS_TABLE}.{stage} candidate may not contain a newline")
    return value


def parse(path: str) -> tuple[str, str, bool, bool, dict]:
    """One installation.toml as (harness, routing, is_default, legacy, models)."""
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

    routing = doc.get(ROUTING_KEY, LABEL_ROUTING)
    # `routing = 1` loads as an int and would read as deliberate. It is a typo,
    # and a typo that decides which cards this installation takes is not one to
    # guess at.
    if not isinstance(routing, str):
        die(f"{path}: {ROUTING_KEY} must be a string")
    if routing not in ROUTINGS:
        die(f"{path}: unknown {ROUTING_KEY} {routing!r}; "
            f"expected one of {', '.join(ROUTINGS)}")

    table = doc.get(MODELS_TABLE, {})
    if not isinstance(table, dict):
        die(f"{path}: {MODELS_TABLE} must be a table")
    unknown = sorted(set(table) - set(STAGES))
    if unknown:
        die(f"{path}: unknown key(s) in {MODELS_TABLE}: {', '.join(unknown)}")

    return (harness, routing, default_flag(path, doc), legacy_names_flag(path, doc),
            resolve_models(path, harness, table))


def installations(root: str) -> list[tuple[str, str, bool, bool]]:
    """(name, home, is_default, legacy_names) for every installation under
    <root>, by name.

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
        doc = load_toml(path)
        out.append((name, home, default_flag(path, doc), legacy_names_flag(path, doc)))
    return out


def refuse_unless_one_default(root: str, entries: list[tuple[str, str, bool, bool]]) -> None:
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
    claimed = [name for name, _, is_default, _ in entries if is_default]
    if len(claimed) > 1:
        die(f"{root}: {len(claimed)} installations claim default = true "
            f"({', '.join(claimed)}); exactly one may")
    if len(entries) > 1 and not claimed:
        names = ", ".join(name for name, _, _, _ in entries)
        # Naming the fix as a file edit, not a command: --write refuses to
        # overwrite an installation.toml that exists, so there is no command
        # here that could change an existing installation's default.
        die(f"{root}: {len(entries)} installations ({names}) and none claims "
            "default = true, so every card with no foreman:<name> label would "
            "belong to no installation; set default = true in exactly one "
            f"{INSTALLATION_FILE} by hand")


def declared_boards(home: str, path: str) -> list[str]:
    """Every board name the boards.toml at <path> declares for <home>, read
    through bin/boards.py.

    Through boards.py and never a second TOML parse here. boards.py decides
    what a boards.toml declares, and a second reader would agree with it only
    until one of them learned a new rule. A home whose boards.toml does not
    exist yet declares no boards: that is a fresh installation, not an
    unreadable one. Anything boards.py refuses is refused here too, with its
    reason on stderr, because a legacy sibling whose boards cannot be read is
    a root whose names cannot be proven apart.

    `--names`, not `--list`. `--list` also refuses a board whose repo is not a
    directory. Found in review on 2026-09-14: a legacy board on an unmounted
    disk made every installation under the root refuse to load, so a running
    tick failed every command, for a check that is only about names. Names do
    not depend on mounts.
    """
    if not os.path.exists(path):
        return []
    boards_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "boards.py")
    result = subprocess.run(
        [sys.executable, boards_py, "--file", path, "--names"],
        capture_output=True, env={**os.environ, "FOREMAN_HOME": home},
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        die(f"cannot read the boards {path} declares; "
            "refusing to guess whether they collide with a sibling installation's names")
    return [name.decode() for name in result.stdout.split(b"\0") if name]


def refuse_colliding_names(root: str, entries: list[tuple[str, str, bool, bool]],
                           boards_files: dict[str, str]) -> None:
    """Legacy names must stay apart from every sibling's. Checked on EVERY read.

    Checked HERE, beside the one-default check, because this is the one
    reader that already walks every sibling on every read, and every script
    that composes a name reaches it first through skills/board/config.sh. A
    check inside sweep.sh or dispatch.sh would be skipped by every script it
    was not in.

    TWO LEGACY INSTALLATIONS share every name: two ticks named foreman/tick,
    and one branch foreman/<board>/<ticket> for both on a repository they both
    serve. At most one sibling may be legacy.

    A LEGACY BOARD NAMED LIKE A SCOPED SIBLING. The legacy shapes drop the
    installation segment, and that reopens the hole the segment closed. A
    legacy board `codex` sweeps the worktree glob foreman-codex-* and deletes
    branches under foreman/codex/*. A scoped installation `codex` cuts
    foreman-codex-<board>-<ticket> and pushes foreman/codex/<board>/<ticket>.
    On a repository both serve, the legacy sweep reaps the sibling's live
    worktrees. Board names and installation names follow one character rule,
    so nothing but this refusal keeps them apart.

    <boards_files> maps a home to the boards.toml to read for it, for a home
    whose boards are not in place yet -- see write()'s dry run. Every other
    home is read at <home>/boards.toml.
    """
    legacy = [(name, home) for name, home, _, is_legacy in entries if is_legacy]
    if len(legacy) > 1:
        names = ", ".join(name for name, _ in legacy)
        die(f"{root}: {len(legacy)} installations declare {NAMES_KEY} = "
            f"\"{LEGACY_NAMES}\" ({names}); at most one may, because two would "
            "share every agent, worktree and branch name")
    if not legacy:
        return
    legacy_name, legacy_home = legacy[0]
    scoped = {name for name, _, _, is_legacy in entries if not is_legacy}
    boards_path = boards_files.get(legacy_home, os.path.join(legacy_home, "boards.toml"))
    for board in declared_boards(legacy_home, boards_path):
        if board in scoped:
            die(f"{root}: board {board} of the legacy installation {legacy_name} "
                f"has the same name as the installation {board}; its worktree "
                f"glob foreman-{board}-* and branches foreman/{board}/* would "
                f"match installation {board}'s own. Rename the board or the "
                "installation")


def siblings_checked(root: str,
                     pending: tuple[str, str, bool, bool] | None = None,
                     boards_files: dict[str, str] | None = None,
                     ) -> list[tuple[str, str, bool, bool]]:
    """Every installation under <root>, after every rule that spans siblings.

    <pending> is a declaration not yet on disk, checked as if it were: write()'s
    dry run passes the one it would write, so the check it runs is this one and
    not a second copy of it.
    """
    entries = installations(root)
    if pending is not None:
        entries = sorted([e for e in entries if e[1] != pending[1]] + [pending])
    refuse_unless_one_default(root, entries)
    refuse_colliding_names(root, entries, boards_files or {})
    return entries


def refuse_undeclared_beside_siblings(home: str) -> None:
    """A home with no installation.toml is the un-migrated Claude home only
    when nothing beside it is a declared installation.

    Found in review on 2026-09-14. `installation.py --home ~/.foreman/codex2`,
    beside a declared `claude`, printed INSTALLATION claude, IS_DEFAULT 1,
    LEGACY_NAMES 1. A clone whose install.sh was refused, run anyway, would
    take `foreman/tick` and the live installation's branch names, and adopt
    its open pull requests and agents.

    The un-migrated home is ~/.foreman itself, with install/ directly inside.
    Its parent is $HOME, which holds no installation.toml directories, so that
    home still reads as legacy. Only a home UNDER a root of installations is
    refused.
    """
    parent = os.path.dirname(home)
    try:
        entries = sorted(os.listdir(parent))
    except OSError as exc:
        die(f"cannot list {parent} to prove {home} is the un-migrated home: {exc}")
    siblings = [name for name in entries if declared(os.path.join(parent, name))]
    if siblings:
        die(f"{home} has no {INSTALLATION_FILE}, but {parent} holds declared "
            f"installations ({', '.join(siblings)}), so it is not the un-migrated "
            f"Claude home. Run {home}/install/bin/install.sh to declare it, or "
            "`boardctl migrate` from it if migrate left it moved but undeclared")


def record(home: str) -> list[str]:
    """The KEY, VALUE fields for one home."""
    # A HOME WITH NO installation.toml IS A LONE CLAUDE INSTALLATION. That is
    # exactly the layout every machine had before installations existed: the
    # clone sits directly under ~/.foreman beside boards.toml and instances/.
    # Such a home must keep working unmigrated, so this loader answers for it
    # rather than leaving every consumer to guess -- and it has no siblings,
    # because a root that holds one un-migrated home holds no installations.
    #
    # ITS NAMES ARE LEGACY. That is what keeps a machine safe between `git
    # pull` and `boardctl migrate`. The pulled code must go on finding the
    # branches, agents and worktrees the old code named, or every in-flight
    # card reads "no PR" and is built again on top of its open pull request.
    if not declared(home):
        refuse_undeclared_beside_siblings(home)
        defaults = {stage: [CLAUDE_MODELS[stage]] for stage in STAGES}
        return fields(CLAUDE, CLAUDE, LABEL_ROUTING, True, True, home, home, defaults)

    path = os.path.join(home, INSTALLATION_FILE)
    name = os.path.basename(home)
    validate_name(home, name)
    root = foreman_root(home)
    harness, routing, declares_default, legacy_names, models = parse(path)
    entries = siblings_checked(root)
    # AN INSTALLATION WITH NO SIBLING IS THE DEFAULT, whatever its file says.
    # One installation on the machine is the common case, and it must own
    # every card: there is no other installation for an unlabelled card to
    # belong to. On 2026-09-14 it did not. The documented first install --
    # `install.sh --harness claude`, no --default -- wrote `default = false`,
    # so IS_DEFAULT came back empty, skills/board/queue.py dropped every
    # unlabelled card as FOREIGN and exited 0, and a board installed exactly
    # as the README says never dispatched anything and never said why.
    is_default = declares_default or len(entries) == 1
    return fields(name, harness, routing, is_default, legacy_names, home, root, models)


def fields(name: str, harness: str, routing: str, is_default: bool, legacy_names: bool,
           home: str, root: str, models: dict) -> list[str]:
    # IS_DEFAULT and LEGACY_NAMES are the two keys whose empty value is
    # meaningful: config.sh tests them with `-n`, so "" is false and "1" is
    # true. Every other key here refuses to be empty.
    out = [
        "INSTALLATION", name,
        "HARNESS", harness,
        "ROUTING", routing,
        "IS_DEFAULT", "1" if is_default else "",
        "LEGACY_NAMES", "1" if legacy_names else "",
        "FOREMAN_HOME", home,
        "FOREMAN_ROOT", root,
    ]
    for stage in STAGES:
        out += [
            f"{stage.upper()}_MODEL", models[stage][0],
            f"{stage.upper()}_MODELS", "\n".join(models[stage]),
        ]
    return out


def toml_string(value: str) -> str:
    """<value> as a TOML basic string. Escaping backslash and double-quote is
    every case that can occur in a harness or a model name."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def toml_models(candidates: list[str]) -> str:
    """One candidate as a TOML string, several as an array of strings.

    A single candidate stays a plain string so an installation written here is
    byte-identical to one written before candidate lists existed.
    """
    if len(candidates) == 1:
        return toml_string(candidates[0])
    return "[" + ", ".join(toml_string(c) for c in candidates) + "]"


def render(harness: str, routing: str, is_default: bool, legacy_names: bool, models: dict) -> str:
    """installation.toml as text. tomllib reads TOML and cannot write it, and
    a writer is not worth a dependency for eight lines of two-token keys."""
    lines = [
        "# What this installation is: the harness that runs it, and the models",
        "# it spends. A stage lists candidates in order; dispatch runs the first",
        "# that is available. Written by bin/install.sh; bin/installation.py reads it.",
        "",
        f"harness = {toml_string(harness)}",
        f"{ROUTING_KEY} = {toml_string(routing)}",
        f"default = {'true' if is_default else 'false'}",
        f"{NAMES_KEY} = {toml_string(LEGACY_NAMES if legacy_names else SCOPED_NAMES)}",
        "",
        f"[{MODELS_TABLE}]",
    ]
    lines += [f"{stage} = {toml_models(models[stage])}" for stage in STAGES]
    return "\n".join(lines) + "\n"


def write(home: str, harness: str | None, is_default: bool, legacy_names: bool,
          given: dict, dry_run: bool, boards_file: str | None) -> None:
    """Declare <home> an installation, refusing to overwrite one that exists.

    With <dry_run>, write nothing and refuse exactly where the write would.
    bin/boardctl migrate runs it BEFORE it moves a home. Found in review on
    2026-09-14: migrate moved the home first and the write refused after,
    leaving ~/.foreman/claude undeclared, its FOREMAN_ROOT no longer pointing
    at the linear.key left one level up, and a re-run moving it again into
    claude/claude. <boards_file> is where the boards are before the move, so
    the collision check reads the boards the home will have.
    """
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
    if dry_run:
        if os.path.exists(path):
            die(f"{path} already exists; edit or remove it, this never overwrites one")
        # The same sibling checks record() applies to the file once written.
        pending = (os.path.basename(home), home, is_default, legacy_names)
        siblings_checked(os.path.dirname(home), pending,
                         {home: boards_file} if boards_file else None)
        return
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
            fh.write(render(harness, LABEL_ROUTING, is_default, legacy_names, models))
        # Read back what was written, through the real loader. It proves the
        # text this file emitted parses, and it applies the sibling check --
        # so `--write --default` beside an existing default refuses, and so
        # does a second installation written while no sibling claims default,
        # and so does a second `--legacy-names`.
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
        "[--siblings | --write --harness <name> [--default] [--legacy-names] "
        "[--model-<stage> <model>] [--dry-run [--boards-file <path>]]]")


def main(argv: list[str]) -> int:
    home = None
    want_siblings = False
    want_write = False
    harness = None
    is_default = False
    legacy_names = False
    dry_run = False
    boards_file = None
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
            # Repeated for one stage, the values are its ordered candidates:
            # --model-plan A --model-plan B tries A first.
            models.setdefault(MODEL_FLAGS[arg], []).append(value_for(arg))
        elif arg == "--siblings":
            want_siblings = True
        elif arg == "--write":
            want_write = True
        elif arg == "--default":
            is_default = True
        elif arg == "--legacy-names":
            legacy_names = True
        elif arg == "--dry-run":
            dry_run = True
        elif arg == "--boards-file":
            boards_file = absolute(value_for(arg), "--boards-file")
        else:
            usage()
    if want_siblings and want_write:
        usage()
    # --boards-file changes what a dry run reads; on a real write the boards
    # are wherever the home is, and accepting it there would check a file the
    # written installation never reads.
    if boards_file is not None and not dry_run:
        die("--boards-file is only for --write --dry-run")

    if home is None:
        home = os.path.normpath(foreman_home())
    if want_write:
        write(home, harness, is_default, legacy_names, models, dry_run, boards_file)
        return 0
    # A flag that only --write reads, passed to a read, means the operator
    # believes they are writing. Saying nothing would print a record that
    # ignores every model they named.
    if harness is not None or is_default or legacy_names or models or dry_run:
        die("--harness, --default, --legacy-names, --model-<stage> and --dry-run "
            "are only for --write")

    if not want_siblings:
        emit(record(home))
        return 0
    # An un-migrated home is its own only installation: there is no root full
    # of siblings to list, because the root IS the home.
    if not declared(home):
        refuse_undeclared_beside_siblings(home)
        emit([CLAUDE, home])
        return 0
    root = os.path.dirname(home)
    out = []
    for name, sibling_home, _, _ in siblings_checked(root):
        out += [name, sibling_home]
    emit(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
