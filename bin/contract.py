#!/usr/bin/env python3
"""Read a target repository's contract and print it for shell consumers.

    contract.py path/to/board.toml

Emits NUL-separated KEY, VALUE pairs on stdout. Consumers count fields to
detect a failed load, so EVERY key is always emitted -- an optional entry that
is absent is emitted empty, never omitted.

PARSED, NEVER SOURCED. The obvious port of `config.sh` would be a shell file in
the target repository, and every knob there is already an environment variable.
It is refused: instances share a user and a home, so a config that can run code
runs beside every other instance's board credential, before anything has decided
whether that repository is trusted. TOML is stdlib from 3.11, which keeps the
"no install step before the config can be read" property that shell had.
"""

from __future__ import annotations

import sys
import tomllib

# (key, toml path, default). A default of None marks the entry REQUIRED.
#
# `checks.required` is required because merging with nothing required merges a
# diff that nothing tested. `test.command` is required because a build agent
# with no test command reports success from having written code.
SCALARS = [
    ("LINEAR_TEAM_NAME", ("linear", "team"), None),
    ("LINEAR_PROJECT_NAME", ("linear", "project"), None),
    ("CI_WORKFLOW", ("checks", "ci_workflow"), None),
    ("TEST_COMMAND", ("test", "command"), None),
    ("BOOTSTRAP_COMMAND", ("bootstrap", "command"), ""),
    ("DEPLOY_WORKFLOW", ("deploy", "workflow"), ""),
    ("DEPLOY_STEP", ("deploy", "step"), ""),
]

# (key, toml path, joiner, default). A default of None marks it REQUIRED.
#
# REQUIRED_CHECKS joins on "|" and the path lists join on " " because that is
# what the copied config.sh already splits on; changing the separator here
# without changing every splitter is a silent empty list.
LISTS = [
    ("REQUIRED_CHECKS", ("checks", "required"), "|", None),
    ("HIGH_RISK_PATHS", ("risk", "paths"), " ", []),
    ("REQUIRED_DOCS", ("docs", "required"), " ", []),
]

# Defaults live here rather than in config.sh so a target that says nothing
# still produces a full record. They are a CEILING per instance; the
# installation's own ceiling is separate and lives in instance state.
LIMITS = {
    "MAX_CONCURRENT": 1,
    "MAX_BUILD_ATTEMPTS": 2,
    "MAX_REVIEW_ROUNDS": 2,
    "REVIEWERS_PER_ROUND": 2,
    "STALL_MINUTES": 30,
    "MAX_FOLLOWUPS": 3,
}


def die(message: str) -> None:
    sys.stderr.write(f"contract: {message}\n")
    raise SystemExit(1)


def dig(doc: dict, path: tuple[str, ...]):
    """Return doc[a][b] or None. Absent and null are the same thing here."""
    node = doc
    for part in path:
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def load(path: str) -> list[tuple[str, str]]:
    try:
        with open(path, "rb") as fh:
            doc = tomllib.load(fh)
    except FileNotFoundError:
        die(f"no contract at {path}")
    except tomllib.TOMLDecodeError as exc:
        die(f"{path} is not valid TOML: {exc}")

    out: list[tuple[str, str]] = []

    for key, path_, default in SCALARS:
        value = dig(doc, path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, str):
            die(f"{path}: {'.'.join(path_)} must be a string")
        out.append((key, value))

    for key, path_, joiner, default in LISTS:
        value = dig(doc, path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
            die(f"{path}: {'.'.join(path_)} must be a list of strings")
        # An EMPTY list is a statement, not an absence: "nothing is high risk".
        # It must survive as an empty string rather than reinstating a default.
        if key == "REQUIRED_CHECKS" and not value:
            die(f"{path}: checks.required must name at least one check")
        if any(joiner in v for v in value):
            die(f"{path}: {'.'.join(path_)} entries may not contain {joiner!r}")
        out.append((key, joiner.join(value)))

    limits = dig(doc, ("limits",)) or {}
    if not isinstance(limits, dict):
        die(f"{path}: limits must be a table")
    unknown = sorted(set(limits) - {k.lower() for k in LIMITS})
    if unknown:
        die(f"{path}: unknown limits: {', '.join(unknown)}")
    for key, fallback in LIMITS.items():
        value = limits.get(key.lower(), fallback)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            die(f"{path}: limits.{key.lower()} must be a non-negative integer")
        out.append((key, str(value)))

    return out


def main() -> int:
    if len(sys.argv) != 2:
        die("usage: contract.py <path-to-board.toml>")
    pairs = load(sys.argv[1])
    blob = b"\0".join(part.encode() for pair in pairs for part in pair)
    sys.stdout.buffer.write(blob + b"\0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
