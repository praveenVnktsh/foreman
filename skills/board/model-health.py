#!/usr/bin/env python3
"""Record which models are unavailable, so dispatch can try the next candidate.

    model-health.py healthy <model>      0 if available, 1 if not
    model-health.py fail <model> [reason...]
                                          mark <model> down for the cooldown
    model-health.py clear <model>         mark <model> up again
    model-health.py list                  one "<model> <seconds-left> <reason>" per down model

The cooldown is MODEL_HEALTH_COOLDOWN_SECONDS, default 900. It is not a
positional argument: the reason is what dispatch has to hand, and a mismatched
argument order would read a reason string as a number of seconds.

State lives in $FOREMAN_HOME/model-health.json, keyed by model name:
`{"<model>": {"until": <epoch seconds>, "reason": "<why>"}}`.

HEALTH IS AN OPTIMISATION, NOT A GATE. A missing file, an unreadable one, or
one that is not a JSON object reads as "every model is available". The cost of
being wrong is one wasted spawn that fails loudly and marks the model down -- a
card never fails because this file was lost, which is what the board's "the
sibling history is a cache, never truth" rule already asks of derived state.

Written by dispatch when a spawn reports the provider unavailable, and read
before each spawn. It is deliberately per installation: a provider limit is
usually global, but a shared file is shared state across ticks, and the first
increment keeps the board's "no state between ticks" shape by letting each tick
relearn the limit from its own failed spawn.
"""

from __future__ import annotations

import json
import os
import sys
import time

# How long a failed model stays down before dispatch tries it again. Long
# enough that a per-minute rate limit is not re-probed every pass, short enough
# that a transient 429 does not bench a model for the day. Overridable with
# MODEL_HEALTH_COOLDOWN_SECONDS for a provider with a known longer window.
DEFAULT_COOLDOWN_SECONDS = 900

USAGE = ("usage: model-health.py healthy <model> | fail <model> [seconds] [reason...] "
         "| clear <model> | list")


def die(message: str) -> None:
    sys.stderr.write(f"model-health: {message}\n")
    raise SystemExit(2)


def home() -> str:
    declared = os.environ.get("FOREMAN_HOME")
    if not declared:
        die("FOREMAN_HOME is unset; source skills/board/config.sh first")
    return declared


def path() -> str:
    return os.path.join(home(), "model-health.json")


def load() -> dict:
    try:
        with open(path(), encoding="utf-8") as handle:
            doc = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        # Corrupt state is not a reason to stop dispatching. Say so, and treat
        # every model as available.
        sys.stderr.write(f"model-health: {path()} is unreadable ({exc}); treating every model as available\n")
        return {}
    if not isinstance(doc, dict):
        sys.stderr.write(f"model-health: {path()} is not an object; treating every model as available\n")
        return {}
    return doc


def save(doc: dict) -> None:
    target = path()
    tmp = f"{target}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, target)
    except OSError as exc:
        die(f"cannot write {target}: {exc}")


def cooldown() -> int:
    raw = os.environ.get("MODEL_HEALTH_COOLDOWN_SECONDS")
    if raw is None or raw == "":
        return DEFAULT_COOLDOWN_SECONDS
    try:
        seconds = int(raw)
    except ValueError:
        die(f"MODEL_HEALTH_COOLDOWN_SECONDS is {raw!r}; expected a whole number of seconds")
    if seconds <= 0:
        die(f"MODEL_HEALTH_COOLDOWN_SECONDS is {seconds}; expected a positive number of seconds")
    return seconds


def seconds_left(entry: object, now: float) -> float:
    """Seconds until <entry> expires, or 0 if it is down and already expired."""
    if not isinstance(entry, dict):
        return 0.0
    until = entry.get("until")
    if not isinstance(until, (int, float)) or isinstance(until, bool):
        return 0.0
    return max(0.0, float(until) - now)


def main(argv: list[str]) -> int:
    if not argv:
        die(USAGE)
    command, rest = argv[0], argv[1:]
    if command == "healthy":
        if len(rest) != 1:
            die("healthy takes exactly one model")
        entry = load().get(rest[0])
        return 1 if seconds_left(entry, time.time()) > 0 else 0
    if command == "fail":
        if not rest:
            die("fail needs a model")
        model = rest[0]
        reason = " ".join(rest[1:]) if len(rest) > 1 else "provider unavailable"
        doc = load()
        doc[model] = {"until": time.time() + cooldown(), "reason": reason}
        save(doc)
        return 0
    if command == "clear":
        if len(rest) != 1:
            die("clear takes exactly one model")
        doc = load()
        doc.pop(rest[0], None)
        save(doc)
        return 0
    if command == "list":
        if rest:
            die("list takes nothing")
        now = time.time()
        doc = load()
        for model in sorted(doc):
            left = seconds_left(doc.get(model), now)
            if left > 0:
                print(f"{model} {int(left)} {doc[model].get('reason', '')}".rstrip())
        return 0
    die(USAGE)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
