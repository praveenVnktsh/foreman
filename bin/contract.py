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

One exception: `limits.max_followups` is deprecated now that scheduled cleanup
(the `[cleanup]` table below) replaces follow-ups. It is dropped rather than
refused, so a board.toml written before this change keeps loading instead of
breaking on a key nothing needs anymore. It warns on stderr, but only when
stderr is a terminal: this loader runs on every dispatch, sweep, evidence.sh
call and reconcile.py query, and none of those redirect its stderr, so an
unconditional warning would repeat dozens of times a tick for a board that
still sets the key -- a warning nobody would read.
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
    # Names the step (board.toml [deploy] step naming; the job's own step,
    # never a fixed string) whose conclusion and logged reason distinguish a
    # queued deploy from a stand-down and from a failed selection -- see
    # skills/board/reconcile.py's deploy_verdict. Optional: a target that
    # deploys on every merge, with no scheduling step to read, has nothing to
    # name here, so absence must stay "" rather than refuse to load.
    ("DEPLOY_SELECTION_STEP", ("deploy", "selection_step"), ""),
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
    # Deliberately absent from LIMIT_MINIMUMS above: MAX_PLAN_ROUNDS=0 means the
    # plan is posted once and never revised -- the card idles in Plan until the
    # operator removes needs-plan, but nothing merges unreviewed, so zero is a
    # legitimate (if unusual) operator choice, not a disarmed gate.
    "MAX_PLAN_ROUNDS": 2,
    # Review now runs once: a blocking finding buys exactly one fix and the
    # fix merges with no re-review, and one reviewer is enough to gate a
    # single round. Follow-ups (MAX_FOLLOWUPS, below) funded the second and
    # third look this used to need; scheduled cleanup replaces them instead
    # of stacking review rounds on every merge. LIMIT_MINIMUMS still floors
    # both at 1, so a target cannot disarm the gate by zeroing them.
    "MAX_REVIEW_ROUNDS": 1,
    "REVIEWERS_PER_ROUND": 1,
    "STALL_MINUTES": 30,
    # statvfs free-space floors. Necessary but not sufficient -- see
    # preflight.py's module docstring for why the write probes below exist at
    # all -- but still worth keeping comfortably above zero so a nearly-full
    # disk is caught even when nothing gets as far as a probe.
    "MIN_FREE_TMP_MB": 128,
    "MIN_FREE_REPO_MB": 128,
    # Free MEMORY, which is the resource that actually took a machine down.
    #
    # On 2026-08-31 a self-hosted CI runner was OOM-killed at a 5.2GB peak, and
    # on 2026-09-01 four build agents plus that runner drove the same 14GB box to
    # a load average of 14 with ssh timing out. preflight probed disk in two
    # places and never once looked at memory, so it called that machine fit
    # throughout.
    #
    # The agents are not the cost: a claude process measures about 0.3GB. What
    # peaks is the WORK -- the target's own test suite, run concurrently by every
    # build agent. So this floor is sized for one more of those, not for one more
    # agent, and a target whose suite is heavier should raise it in board.toml.
    "MIN_FREE_MEMORY_MB": 1024,
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
    # The character budget bin/check-plan-graph.py measures every plan-graph
    # label line against. 80 is that checker's own default, chosen for the
    # longest path this repository tracks. A target whose paths are deeper
    # raises it here, so a correct plan node naming one of its files is not
    # refused with no compliant wording to offer.
    #
    # Deliberately absent from LIMIT_MINIMUMS above: max_label_chars=0 refuses
    # every label, which starves planning loudly -- the card idles unplanned,
    # but nothing merges unreviewed, so zero is a legitimate (if unusual)
    # operator choice, not a disarmed gate.
    #
    # The default 80 is written twice, here and in bin/check-plan-graph.py,
    # because this loader deliberately depends on nothing. tests/test-contract.sh
    # pins the two together.
    "MAX_LABEL_CHARS": 80,
}

# Keys `[limits]` used to accept and no longer does. Present, they warn on
# stderr and are dropped rather than refusing the whole contract -- see the
# module docstring. Kept out of LIMITS (which also drives KNOWN_TABLES) so a
# deprecated key never round-trips through the normal load-and-emit path.
DEPRECATED_LIMITS = {"max_followups"}

# Scheduled cleanup runs on its own clock, outside the build/review loop
# above -- see docs/specs/2026-09-15-cleanup-and-light-review-design.md.
#
# Cleanup is ON BY DEFAULT: a board that declares no `[cleanup]` table at all
# runs one every 3 days anyway. Follow-ups are gone as of this change, so a
# board with nothing configured must not silently lose the only thing left
# that files cleanup work.
#
# `every_days = 0` is the operator's explicit off switch -- unlike the
# review-gate limits above, disabling cleanup merges nothing unreviewed, so
# zero is a legitimate value rather than a gate this loader has to floor.
#
# `max_plan_nodes = 0` does not disarm anything either. Step 7 of the cleanup
# agent's flow already sends anything over the limit to `needs-plan` for the
# operator; a floor of 0 just means EVERY cleanup card, however small, waits
# for that sign-off instead of building unattended on a later tick.
CLEANUP = {
    "CLEANUP_EVERY_DAYS": 3,
    "CLEANUP_MODEL": "",
    "CLEANUP_MAX_PLAN_NODES": 8,
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
    "deploy": {"workflow", "step", "selection_step"},
    "risk": {"paths"},
    "test": {"command"},
    "bootstrap": {"command"},
    "docs": {"required"},
    "limits": {key.lower() for key in LIMITS} | DEPRECATED_LIMITS,
    "cleanup": {"every_days", "model", "max_plan_nodes"},
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

    # `... or {}` here used to run BEFORE the isinstance check below, so a
    # falsy wrong-typed value (`limits = false`, `0`, `""`, `[]`) turned into
    # {} first and never reached the check at all -- the exact "wrong-typed
    # ancestor" case this module's docstring already claims is a die(). Only
    # genuine absence (None) may default; every other type must still hit the
    # isinstance check and die.
    limits = dig_checked(("limits",))
    if limits is None:
        limits = {}
    elif not isinstance(limits, dict):
        die(f"{path}: limits must be a table")
    # Warn and drop rather than refuse -- see DEPRECATED_LIMITS and the module
    # docstring. An existing board.toml that still sets this must keep loading.
    for key in DEPRECATED_LIMITS:
        if key in limits:
            # A board that still sets this key loads it on every dispatch,
            # sweep, evidence.sh call and reconcile.py query -- dozens of
            # times a tick -- and load-pairs.sh does not redirect contract.py's
            # stderr. A warning that fires that often is one nobody reads, so
            # it only prints where a human is actually watching: an
            # interactive terminal. This file carries no verbosity flag of its
            # own to gate on instead, and a tty check needs no config to keep
            # working once one exists.
            if sys.stderr.isatty():
                sys.stderr.write(
                    f"contract: {path}: limits.{key} is deprecated and ignored; "
                    "the scheduled cleanup replaced follow-ups\n"
                )
    for key, fallback in LIMITS.items():
        value = limits.get(key.lower(), fallback)
        floor = LIMIT_MINIMUMS.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < floor:
            if floor > 0:
                die(f"{path}: limits.{key.lower()} must be an integer >= {floor} "
                    f"(0 would disarm the adversarial review gate)")
            die(f"{path}: limits.{key.lower()} must be a non-negative integer")
        out.append((key, str(value)))

    # Same bug, same fix as `limits` above: only None (genuine absence) may
    # default to {}. A falsy wrong-typed `cleanup` (`false`, `0`, `""`, `[]`)
    # must still hit the isinstance check and die, not silently load defaults.
    cleanup = dig_checked(("cleanup",))
    if cleanup is None:
        cleanup = {}
    elif not isinstance(cleanup, dict):
        die(f"{path}: cleanup must be a table")
    for key, toml_key in (
        ("CLEANUP_EVERY_DAYS", "every_days"),
        ("CLEANUP_MAX_PLAN_NODES", "max_plan_nodes"),
    ):
        value = cleanup.get(toml_key, CLEANUP[key])
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            die(f"{path}: cleanup.{toml_key} must be a non-negative integer")
        out.append((key, str(value)))
    # Optional, unlike everything else that is a str: absent means "no
    # override", not "required and missing", so "" round-trips same as never
    # having set it -- see CLEANUP_MODEL's default and config.sh's fallback
    # to PLAN_MODEL.
    model = cleanup.get("model", CLEANUP["CLEANUP_MODEL"])
    if not isinstance(model, str):
        die(f"{path}: cleanup.model must be a string")
    # "" is the legitimate "no override" spelling (see above), but a
    # whitespace-only value like "   " is not empty by that check, so it used
    # to survive here and reach config.sh's `CLEANUP_MODEL="${CLEANUP_MODEL:-$PLAN_MODEL}"`
    # as a non-empty string -- `:-` never falls back to PLAN_MODEL, so
    # dispatch.sh hands "--model \"   \"" to the adapter. codex and opencode
    # don't refuse a bad model at spawn time (bin/installation.py's
    # resolve_models says why): the agent dies inside its own log, the card
    # never moves, and the cleanup stamp is already written, so the board
    # repeats it silently every every_days. Refuse it here instead, matching
    # installation.py's wording for the same failure on the four stage models.
    if model and not model.strip():
        die(f"{path}: cleanup.model may not be empty; omit the key to use PLAN_MODEL")
    if "\0" in model:
        die(f"{path}: cleanup.model may not contain a NUL byte")
    out.append(("CLEANUP_MODEL", model))

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
