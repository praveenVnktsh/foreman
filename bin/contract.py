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

Because the repository is untrusted, anything the loader cannot make sense of
is refused rather than silently degraded to a default: a wrong-typed ancestor,
an unrecognised key, a required value that is empty, and a value that would
desynchronize the wire format below are all die()s, not None.
"""

from __future__ import annotations

import sys
import tomllib

# (key, toml path, default). A default of None marks the entry REQUIRED.
#
# `checks.required` is required because merging with nothing required merges a
# diff that nothing tested. `test.command` is required because a build agent
# with no test command reports success from having written code.
#
# LINEAR_TEAM_NAME and LINEAR_PROJECT_NAME are what the target repository
# declares about itself -- names, not IDs, because a target is not trusted to
# hand config.sh the ID it is later allowed to write state transitions into.
# bin/resolve-ids.py resolves these to ids once, at instance-creation time,
# and pins them in ids.env; see that file for why ids and never names past
# this point.
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
#
# risk.paths (HIGH_RISK_PATHS): paths whose presence in a diff park the PR for
# the operator instead of merging it, read from the diff, never from the
# ticket text. The distinction that decides what belongs in this list is
# reversibility: a bad change in an ordinary path is a revert and a redeploy,
# but a migration runs against live state and mutates it in place --
# reverting the PR does not undo it. An empty list is a statement ("nothing is
# high risk"), not an absence; see the empty-list handling below.
LISTS = [
    ("REQUIRED_CHECKS", ("checks", "required"), "|", None),
    ("HIGH_RISK_PATHS", ("risk", "paths"), " ", []),
    ("REQUIRED_DOCS", ("docs", "required"), " ", []),
]

# Defaults live here rather than in config.sh so a target that says nothing
# still produces a full record. They are a CEILING per instance; the
# installation's own ceiling is separate and lives in instance state.
#
# MIN_FREE_*/PROBE_*/QUICK_PROBE_MB used to be config.sh's own defaults --
# constants shared by every target regardless of what it actually costs to
# build. That is precisely the drift this table exists to prevent for every
# other limit here: an operator raises `MAX_CONCURRENT` in board.toml and the
# board keeps using config.sh's number, silently. preflight.py's probe sizes
# had the identical bug, just never named it, so they move here with
# everything else a target may need to declare about itself.
#
# The defaults below are sized for THIS repository's own suite -- a handful of
# bash scripts that touch no meaningful disk -- not for the heavy Python test
# suite they were originally calibrated against. A target whose build needs
# gigabytes of scratch (pytest, a large `node_modules`, ...) raises its own
# `[limits]` in board.toml; a cheap suite should never be required to reserve
# a gigabyte before it is allowed to dispatch.
#
# THAT IS ALSO THE DANGER: a target that declares no `[limits]` at all --
# which is every target until its operator has reason to think otherwise --
# silently inherits foreman's own tiny numbers instead of failing to load. A
# heavy build that would have exhausted a 1024MB/64MB probe or a 2048MB/5120MB
# free-space floor now instead PASSES this cheap preflight and dies mid-build
# on the real thing: the exact EDQUOT failure that cost one card two attempts
# on 2026-08-02, reintroduced by under-provisioning rather than by no check
# existing at all. If your target's build writes real gigabytes of scratch --
# a Python test suite, a large `node_modules`, a media pipeline -- say so in
# `board.toml`'s `[limits]`; this table cannot tell a cheap repo from an
# unconfigured expensive one.
# A limit whose own zero disarms a safety gate rather than merely idling it.
# `reviewers_per_round = 0` dispatches zero reviewers and SKILL.md then reads
# "no blocking findings" and merges; `max_review_rounds = 0` never even asks
# for a first round. Both load cleanly under the plain `value < 0` check below
# -- a target can disable the adversarial review gate with one integer. Every
# OTHER limit here may still be zero: MAX_CONCURRENT=0 only starves dispatch,
# MAX_BUILD_ATTEMPTS=0 only parks every card unbuilt, and the free-space/probe
# sizes are floors preflight.py adds to, not gates that skip a check outright
# -- none of those merge something unreviewed.
LIMIT_MINIMUMS = {
    "MAX_REVIEW_ROUNDS": 1,
    "REVIEWERS_PER_ROUND": 1,
}

LIMITS = {
    "MAX_CONCURRENT": 1,
    "MAX_BUILD_ATTEMPTS": 2,
    "MAX_REVIEW_ROUNDS": 2,
    "REVIEWERS_PER_ROUND": 2,
    "STALL_MINUTES": 30,
    "MAX_FOLLOWUPS": 3,
    # statvfs free-space floors. Necessary but not sufficient -- see
    # preflight.py's module docstring for why the write probes below exist at
    # all -- but still worth keeping comfortably above zero so a nearly-full
    # disk is caught even when nothing gets as far as a probe.
    "MIN_FREE_TMP_MB": 128,
    "MIN_FREE_REPO_MB": 128,
    # Written for real and then released. Large enough to actually exercise a
    # quota (a 1-byte write can succeed where a real build's writes cannot),
    # small enough that a cheap suite never waits on disk I/O to dispatch.
    "PROBE_TMP_MB": 16,
    "PROBE_REPO_MB": 8,
    # `preflight.py --quick`'s probe, run on every heartbeat tick. Smaller
    # again than the full-gate probes for the same reason QUICK_PROBE_MB was
    # smaller than PROBE_TMP_MB before this table existed: a tick firing every
    # couple of minutes must not pay a full probe's cost merely to prove a
    # machine it is not about to build on is still healthy.
    "QUICK_PROBE_MB": 4,
}

# Every top-level table this loader reads, and the keys it recognises inside
# each one. A key or table outside this map is refused rather than ignored:
# the identical typo (`commnad` for `command`) that `[limits]` already caught
# was, before this map existed, silently swallowed to the empty default under
# every other table -- a contract that says less than its author thought it
# said, and says it with an exit code of 0.
KNOWN_TABLES = {
    "linear": {"team", "project"},
    "checks": {"required", "ci_workflow"},
    "deploy": {"workflow", "step"},
    "risk": {"paths"},
    "test": {"command"},
    "bootstrap": {"command"},
    "docs": {"required"},
    "limits": {key.lower() for key in LIMITS},
}


def die(message: str) -> None:
    sys.stderr.write(f"contract: {message}\n")
    raise SystemExit(1)


class NotATable(Exception):
    """Raised by dig() when an ancestor exists but is the wrong type.

    Absence is fine -- an omitted `[risk]` table means "no risk paths
    configured". `risk = "high"` is not absence: `paths` cannot be reached
    because its parent isn't a table at all. The old dig() returned None for
    both cases alike, which reads a typo as "nothing configured" instead of
    refusing it.
    """

    def __init__(self, prefix: tuple[str, ...]):
        self.prefix = prefix


def dig(doc: dict, path: tuple[str, ...]):
    """Return doc[a][b]... or None if the path is genuinely absent."""
    node = doc
    for depth, part in enumerate(path):
        if not isinstance(node, dict):
            raise NotATable(path[:depth])
        if part not in node:
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

    def dig_checked(path_: tuple[str, ...]):
        try:
            return dig(doc, path_)
        except NotATable as exc:
            prefix = ".".join(exc.prefix) or "(root)"
            die(f"{path}: {prefix} must be a table")

    # Refuse anything this loader doesn't recognise, up front, rather than
    # reading a typo as "nothing configured" one key at a time below.
    unknown_tables = sorted(set(doc) - set(KNOWN_TABLES))
    if unknown_tables:
        die(f"{path}: unknown section(s): {', '.join(unknown_tables)}")
    for table, known_keys in KNOWN_TABLES.items():
        section = doc.get(table)
        if not isinstance(section, dict):
            continue  # absent, or wrong-typed -- dig_checked() catches the latter below
        unknown_keys = sorted(set(section) - known_keys)
        if unknown_keys:
            die(f"{path}: unknown key(s) in [{table}]: {', '.join(unknown_keys)}")

    out: list[tuple[str, str]] = []

    for key, path_, default in SCALARS:
        value = dig_checked(path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, str):
            die(f"{path}: {'.'.join(path_)} must be a string")
        # A required field satisfied by "" or all-whitespace is exactly the
        # failure test.command exists to prevent: a build agent with no test
        # command reports success from having written code.
        if default is None and not value.strip():
            die(f"{path}: {'.'.join(path_)} may not be empty")
        if "\0" in value:
            die(f"{path}: {'.'.join(path_)} may not contain a NUL byte")
        out.append((key, value))

    for key, path_, joiner, default in LISTS:
        value = dig_checked(path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
            die(f"{path}: {'.'.join(path_)} must be a list of strings")
        # An EMPTY list is a statement, not an absence: "nothing is high risk".
        # It must survive as an empty string rather than reinstating a default.
        # A required list, though, may not be satisfied by an empty list or by
        # an empty entry -- same failure mode as an empty required scalar.
        if default is None and not value:
            die(f"{path}: {'.'.join(path_)} must name at least one check")
        if default is None and any(not v.strip() for v in value):
            die(f"{path}: {'.'.join(path_)} entries may not be empty")
        if any(joiner in v for v in value):
            die(f"{path}: {'.'.join(path_)} entries may not contain {joiner!r}")
        if any("\0" in v for v in value):
            die(f"{path}: {'.'.join(path_)} entries may not contain a NUL byte")
        out.append((key, joiner.join(value)))

    limits = dig_checked(("limits",)) or {}
    if not isinstance(limits, dict):
        die(f"{path}: limits must be a table")
    for key, fallback in LIMITS.items():
        value = limits.get(key.lower(), fallback)
        floor = LIMIT_MINIMUMS.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < floor:
            if floor > 0:
                die(f"{path}: limits.{key.lower()} must be an integer >= {floor} "
                    f"(0 would disarm the adversarial review gate)")
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
