#!/usr/bin/env python3
"""Pick the model a board stage runs on while its first choice is rate-limited.

    fallback.py resolve <stage>              one line of JSON: the model, and why
    fallback.py model <stage>                the resolved model name alone, for bash;
                                             says on stderr when it fell back
    fallback.py mark <model> [--minutes N]   record that <model> is limited for N minutes

<stage> is plan, build, review or cleanup. The tick is not a stage here:
skills/board/supervise.sh starts it on TICK_MODEL, and no dispatch resolves it.

WHY THIS EXISTS. On 2026-09-16 the plan stage ran on `PLAN_MODEL=fable` while
fable was rate-limited. Every plan agent died on its first API call. The tick
voided the attempt, and the next pass dispatched the same card onto the same
model. Nothing moved for 11 hours, and opus had capacity the whole time. A stage
whose model is limited now falls one tier down and keeps working.

WHAT IT READS. The environment only. Callers prefix the knobs -- dispatch.sh on
every fresh spawn, and the tick on `mark` and `resolve`. skills/board/config.sh
assigns them in the sourcing shell and does not export them: that file is a
high-risk path, and exporting them is how a previous change parked for an
operator. FOREMAN_HOME is already exported; FALLBACK_TIERS,
FALLBACK_COOLDOWN_MINUTES, each stage's *_MODEL and *_FLOOR, and CLEANUP_MODEL
are not. bin/installation.py is the one reader of the [fallback] table in
installation.toml. A second parser here would be a copy that drifts. The
cleanup stage pairs CLEANUP_MODEL with PLAN_FLOOR, because a cleanup pass is
the plan's work in miniature; config.sh defaults CLEANUP_MODEL for that reason.

AN UNSET VARIABLE IS REFUSED. AN EMPTY ONE IS A VALUE. installation.py always
emits them and config.sh assigns them in the sourcing shell, so an unset one
means this process was not given the knobs. Resolving anyway would answer ""
for the stage model, which the CLI reads as inherit: every stage spawned on
whatever the caller runs on, with exit code 0. dispatch.sh reads a refusal as
"spawn on the first choice and warn", so a broken helper costs the fallback
and never the dispatch. An empty value keeps its meaning: `PLAN_MODEL=` is
inherit, and `FALLBACK_TIERS=` turns fallback off.

THE STATE. One file per limited model, `$FOREMAN_HOME/rate-limits/<model>`,
holding one line: the UTC moment the limit expires, as `%Y-%m-%dT%H:%M:%SZ`.
It is a file because the tick that sees an agent die and the dispatch that picks
the next model are different processes, often in different passes. It lives in
the installation's home and not the machine root: each installation spends its
own subscription, so a limit on one says nothing about a sibling.

A STAMP EXPIRES BY ITSELF. That is the cooldown: once the moment passes, the
stage tries its first choice again, and nobody has to remember to clear
anything. An expired or unreadable stamp is ignored, not refused. The worst it
costs is one spawn on a model that is still limited; that agent dies at once and
the tick marks the model again. A refusal would instead stop the fallback for
every stage over one bad file.

DOWN ONLY, AND NEVER PAST THE FLOOR. The walk starts at the stage's first choice
and moves only toward weaker models. Walking up would spend a stronger model
than the installation chose for that stage. The floor is the weakest model an
installation accepts for a stage: a plan drawn by a model too weak for it costs
every build that follows, so the card waits instead. When every allowed tier is
limited, the answer is the lowest allowed tier with `floor_reached` true. The
dispatch still spawns on it, so the board voids exactly as it did before this
file existed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote

# The format of a stamp's one line. It is the format config.sh:card_log writes
# `at` in, and reconcile.py's CARD_LOG_STAMP reads, so a stamp and a history
# entry can be compared by eye in the same report.
STAMP = "%Y-%m-%dT%H:%M:%SZ"

STAMP_DIR = "rate-limits"

# What `mark` and FALLBACK_COOLDOWN_MINUTES fall back to. installation.py
# emits 60 when installation.toml says nothing, so this only answers for a
# caller that prefixed neither.
DEFAULT_COOLDOWN_MINUTES = 60

# Each stage's first-choice model and floor, by environment variable. Cleanup
# has no floor of its own: see WHAT IT READS above.
STAGE_VARS = {
    "plan": ("PLAN_MODEL", "PLAN_FLOOR"),
    "build": ("BUILD_MODEL", "BUILD_FLOOR"),
    "review": ("REVIEW_MODEL", "REVIEW_FLOOR"),
    "cleanup": ("CLEANUP_MODEL", "PLAN_FLOOR"),
}


def die(message: str) -> NoReturn:
    sys.stderr.write(f"fallback: {message}\n")
    raise SystemExit(1)


def stamp_name(model: str) -> str:
    """The stamp's filename for <model>, safe to open directly.

    Encoded so a model may hold any character -- a tier is `model` or
    `harness:model`, and a Foundry model is `foundry/gpt-5.6-sol` -- without a
    `/` escaping the directory or a leading `.` colliding with the temporary
    file write_stamp() renames into place. quote() with an empty safe set
    leaves only `A-Za-z0-9_.-~`, so the result is always a plain filename. The
    encoding is not reversed: a stamp is only ever looked up by the model that
    names it, never listed.
    """
    return quote(model, safe="")


@dataclass(frozen=True)
class Limit:
    model: str
    until: datetime

    def as_record(self) -> dict:
        return {"model": self.model, "until": self.until.strftime(STAMP)}


@dataclass(frozen=True)
class Stage:
    """One stage's fallback settings, read and checked once, from the environment."""

    name: str
    first_choice: str
    tiers: tuple[str, ...]
    floor: str | None


@dataclass(frozen=True)
class Resolution:
    stage: Stage
    model: str
    limited: tuple[Limit, ...]
    floor_reached: bool

    def as_record(self) -> dict:
        return {
            "stage": self.stage.name,
            "first_choice": self.stage.first_choice,
            "model": self.model,
            "fell_back": self.model != self.stage.first_choice,
            "limited": [limit.as_record() for limit in self.limited],
            "floor": self.stage.floor,
            "floor_reached": self.floor_reached,
        }


def required(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        die(f"{name} is unset; expected it prefixed by dispatch.sh or the tick "
            "(an empty value is allowed and means something; unset does not)")
    return value


def parse_stamp(text: str, what: str) -> datetime:
    """One STAMP as an aware UTC datetime. Raises ValueError naming <what>."""
    try:
        return datetime.strptime(text, STAMP).replace(tzinfo=timezone.utc)
    except ValueError:
        raise ValueError(f"{what} is {text!r}; expected a UTC stamp like 2026-09-16T06:24:17Z") from None


def now() -> datetime:
    """The current moment, or FALLBACK_NOW when a test pins it."""
    pinned = os.environ.get("FALLBACK_NOW")
    if not pinned:
        return datetime.now(timezone.utc).replace(microsecond=0)
    try:
        return parse_stamp(pinned, "FALLBACK_NOW")
    except ValueError as exc:
        die(str(exc))


def positive_minutes(text: str, what: str) -> int:
    """<text> as a positive whole number of minutes. Raises ValueError naming <what>."""
    if not (text.isascii() and text.isdigit()) or int(text) == 0:
        raise ValueError(f"{what} is {text!r}; expected a positive whole number of minutes")
    return int(text)


def stamp_dir() -> Path:
    home = os.environ.get("FOREMAN_HOME")
    if not home:
        die("FOREMAN_HOME is unset or empty; expected it exported by skills/board/config.sh")
    # A relative home resolves against the caller's working directory, which
    # differs between a tick and a dispatch, so the two would read different
    # stamps and never agree on a limit. bin/installation.py refuses it too.
    if not os.path.isabs(home):
        die(f"FOREMAN_HOME must be an absolute path: {home}")
    return Path(home) / STAMP_DIR


def read_stage(name: str) -> Stage:
    model_var, floor_var = STAGE_VARS[name]
    first_choice = required(model_var)
    tiers = tuple(required("FALLBACK_TIERS").split())
    floor = required(floor_var) or None

    # installation.py refuses both of these in installation.toml. They are
    # checked again here because the environment wins over that file, and a
    # tier list the walk cannot read is a fallback that picks the wrong model.
    duplicated = sorted({tier for tier in tiers if tiers.count(tier) > 1})
    if duplicated:
        die(f"FALLBACK_TIERS names {', '.join(duplicated)} more than once; "
            "expected each model once, strongest first")
    if floor is not None and floor not in tiers:
        die(f"{floor_var} is {floor!r}, which is not in FALLBACK_TIERS "
            f"({' '.join(tiers) or 'empty'}); expected one of the tiers, or empty for no floor")
    return Stage(name, first_choice, tiers, floor)


def allowed_models(stage: Stage) -> tuple[str, ...]:
    """The models this stage may run on, first choice first, weakest allowed last.

    A first choice that is not a tier has nowhere to fall: that covers fallback
    being off (no tiers), an empty model (inherit), and an environment override
    naming a model the tier list does not know. So does a first choice already
    below its stage's floor, which an operator's PLAN_MODEL override can
    produce: falling further would break the floor, and refusing would stop
    that operator's override from dispatching at all.
    """
    if stage.first_choice not in stage.tiers:
        return (stage.first_choice,)
    start = stage.tiers.index(stage.first_choice)
    bottom = stage.tiers.index(stage.floor) if stage.floor else len(stage.tiers) - 1
    return stage.tiers[start:max(start, bottom) + 1]


def resolve(stage: Stage, live_limit: Callable[[str], Limit | None]) -> Resolution:
    """Walk down from the first choice while the current model is limited.

    `floor_reached` means the model returned is itself limited and nothing
    below it is allowed. It is therefore also true for a limited first choice
    that has nowhere to fall, because the card waits in that case too.
    """
    allowed = allowed_models(stage)
    limited: list[Limit] = []
    for model in allowed:
        limit = live_limit(model)
        if limit is None:
            return Resolution(stage, model, tuple(limited), floor_reached=False)
        limited.append(limit)
    return Resolution(stage, allowed[-1], tuple(limited), floor_reached=True)


def live_limit(directory: Path, moment: datetime) -> Callable[[str], Limit | None]:
    """A reader of the live stamp for one model, as of <moment>."""

    def read(model: str) -> Limit | None:
        name = stamp_name(model)
        if not name:
            return None
        try:
            until = parse_stamp((directory / name).read_text().strip(), f"stamp {model}")
        except (OSError, UnicodeDecodeError, ValueError):
            # Missing is the usual case. Unreadable is ignored on purpose; see
            # A STAMP EXPIRES BY ITSELF.
            return None
        return Limit(model, until) if moment < until else None

    return read


def write_stamp(directory: Path, limit: Limit) -> None:
    """Replace <model>'s stamp in one rename.

    A dispatch on another board may read the stamp while the tick writes it.
    A half-written line would read as unreadable, and so as not limited, and
    cost a spawn on the limited model. The temporary file starts with a dot,
    which no model name may, so it can never be read as a stamp.
    """
    directory.mkdir(parents=True, exist_ok=True)
    name = stamp_name(limit.model)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=f".{name}.")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(limit.until.strftime(STAMP) + "\n")
        os.replace(temporary, directory / name)
    except OSError:
        Path(temporary).unlink(missing_ok=True)
        raise


def cooldown_minutes(override: int | None) -> int:
    if override is not None:
        return override
    declared = os.environ.get("FALLBACK_COOLDOWN_MINUTES")
    if not declared:
        return DEFAULT_COOLDOWN_MINUTES
    try:
        return positive_minutes(declared, "FALLBACK_COOLDOWN_MINUTES")
    except ValueError as exc:
        die(str(exc))


def minutes_argument(text: str) -> int:
    try:
        return positive_minutes(text, "--minutes")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def print_json(value: object) -> None:
    # One compact line. config.sh:card_log pastes an event into history.jsonl
    # verbatim, one entry per line, and a pretty-printed value would split it.
    print(json.dumps(value, separators=(",", ":")))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="fallback.py")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("resolve", "model"):
        commands.add_parser(command).add_argument("stage", choices=STAGE_VARS)
    mark = commands.add_parser("mark")
    mark.add_argument("model")
    mark.add_argument("--minutes", type=minutes_argument)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv[1:])
    moment = now()

    if args.command in ("resolve", "model"):
        stage = read_stage(args.stage)
        resolution = resolve(stage, live_limit(stamp_dir(), moment))
        if args.command == "model":
            # Said here, by the one component that knows why the model changed,
            # so dispatch.sh reads a name and never the JSON's shape.
            if resolution.limited:
                until = resolution.limited[0].as_record()["until"]
                outcome = ("no tier below it is allowed, so running on "
                           f"{resolution.model} anyway" if resolution.floor_reached
                           else f"running on {resolution.model}")
                sys.stderr.write(f"foreman: {stage.name} model {stage.first_choice} "
                                 f"is rate-limited until {until}; {outcome}\n")
            print(resolution.model)
        else:
            print_json(resolution.as_record())
        return 0

    if not args.model:
        die("cannot mark an empty model")
    limit = Limit(args.model, moment + timedelta(minutes=cooldown_minutes(args.minutes)))
    write_stamp(stamp_dir(), limit)
    print_json(limit.as_record())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
