#!/usr/bin/env python3
"""Turn the names in a contract into the ids the board moves cards by.

    resolve-ids.py --instance <name> [--api-url URL] [--key-file PATH]

The contract names a team, a project and nothing else, because a fork must not
inherit somebody else's project UUID (see bin/contract.py). The running loop
moves cards by id and never by name, because renaming a column must not
silently change which column the orchestrator is allowed to write to. This
script is the one moment those two requirements meet, and therefore the one
moment a name is trusted.

The credential is per Linear WORKSPACE, not per board: $FOREMAN_HOME/linear.key
by default, or the --key-file path for a board in a different workspace. It
used to be $INSTANCE_HOME/linear.key, so ten boards in one workspace meant ten
identical copies of one secret, and rotating it meant finding all ten. One copy
missed is a board that keeps authenticating with a key the operator believes is
revoked.

$INSTANCE_HOME/ids.env is a CACHE, not state. Every id in it is derived from
the target repository's own board.toml plus Linear, so it can always be rebuilt
by running this script again. It may be absent -- deleting it costs one
re-resolve, never a broken board -- so nothing may treat its absence as fatal.

Everything it resolves, it verifies, and every mismatch fails closed:

  - A label id must belong to a label with the name that asked for it. A
    mismatch there re-files every finding, every run, forever.
  - The to-pick-up state must be of type `unstarted`. A mismatch there is the
    difference between a card that waits and a card that ships.
  - Ambiguity is fatal. Two things sharing the requested name is not a coin
    flip -- refuse, and name both ids so the operator can disambiguate.

State ids, never names: a renamed column must not silently change which
column the orchestrator is allowed to write to. Everything downstream of this
script -- config.sh, reconcile.py, dispatch.sh -- reads only the ids below,
never a name.

ids.env is written atomically: a sibling temp file, chmod 0600, os.replace. A
run that fails partway must leave the previous ids.env byte-identical -- a
half-written id file is a board moving cards into a column nobody is
watching. Absent is recoverable; half-written is not. See write_ids().
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_API_URL = "https://api.linear.app/graphql"

# The six workflow states the board moves cards through (skills/board/
# SKILL.md), and the Linear state name each one resolves from. The role name
# on the left is the board's own vocabulary and never changes; the name on the
# right is what an operator sees in Linear and is free to rename -- which is
# exactly why this script exists, and why nothing downstream of it reads a
# name again.
#
# The rows are in board order, so the list reads as the walk a card takes. A
# new state belongs at its place in that walk, not appended at the end.
STATE_ROLES = [
    ("STATE_PLANNED", "Backlog"),
    ("STATE_TO_PICK_UP", "Todo"),
    ("STATE_IN_PLAN", "Plan"),
    ("STATE_IN_PROGRESS", "In Progress"),
    ("STATE_IN_REVIEW", "In Review"),
    ("STATE_MERGED", "Done"),
]

# The to-pick-up state is the one the board is never allowed to move a card
# OUT of on its own initiative, and never allowed to move one INTO either --
# it is where a human hands work to the board. `unstarted` is Linear's own
# marker for "not begun"; a state of any other type here is the difference
# between a card that waits for pickup and a card that the board would ship.
TO_PICK_UP_ROLE = "STATE_TO_PICK_UP"
TO_PICK_UP_TYPE = "unstarted"

# Labels the board owns and only ever writes onto cards itself (skills/board/
# SKILL.md). Unlike states, these are created if missing -- a fork's team has
# never had a reason to create them by hand, and the board cannot function
# without somewhere to put a follow-up or a needs-merge flag.
LABEL_ROLES = [
    ("LABEL_FOLLOW_UP", "follow-up"),
    ("LABEL_FOLLOW_UPS_WRITTEN", "follow-ups-written"),
    ("LABEL_NEEDS_MERGE", "needs-merge"),
    ("LABEL_BOARD_FAILED", "board-failed"),
]

IDS_ENV_ORDER = (
    ["LINEAR_TEAM_ID", "LINEAR_PROJECT_ID"]
    + [role for role, _ in STATE_ROLES]
    + [role for role, _ in LABEL_ROLES]
)


class ResolveError(Exception):
    """Something failed to resolve or failed to verify.

    Carries a message naming what did not match and what was found instead --
    every raise site below is written to be read on a terminal by the operator
    who has to fix the mismatch, not just logged.
    """


def die(message: str) -> None:
    raise ResolveError(message)


# --- GraphQL documents -------------------------------------------------------
#
# One document per shape of question, named so the local stub in
# tests/lib/linear-stub.py can route on the operation name alone rather than
# re-implementing Linear's schema. Every query filters server-side by name
# where Linear's API supports it (an `eq` filter), but the answer is still
# checked client-side against the requested name below -- filters can be
# case-insensitive or fuzzy in ways this script must not inherit.

TEAM_QUERY = """
query Team($name: String!) {
  teams(filter: { name: { eq: $name } }) {
    nodes { id name }
  }
}
"""

PROJECT_QUERY = """
query Project($teamId: String!, $name: String!) {
  team(id: $teamId) {
    projects(filter: { name: { eq: $name } }) {
      nodes { id name }
    }
  }
}
"""

STATES_QUERY = """
query States($teamId: String!) {
  team(id: $teamId) {
    states {
      nodes { id name type }
    }
  }
}
"""

LABELS_QUERY = """
query Labels($teamId: String!) {
  team(id: $teamId) {
    labels {
      nodes { id name }
    }
  }
}
"""

CREATE_LABEL_MUTATION = """
mutation CreateLabel($teamId: String!, $name: String!) {
  issueLabelCreate(input: { teamId: $teamId, name: $name }) {
    success
    issueLabel { id name }
  }
}
"""

LABEL_BY_ID_QUERY = """
query LabelById($id: String!) {
  issueLabel(id: $id) {
    id
    name
  }
}
"""


def query(api_url: str, key: str, document: str, variables: dict) -> dict:
    """POST one GraphQL request and return its `data`.

    Fails closed on anything that is not a clean 2xx carrying no `errors`:
    a transport failure, a non-2xx response, or a body Linear itself flagged
    as an error. Nothing here retries or degrades -- a resolver that papers
    over a flaky read is a resolver that can pin the wrong id.
    """
    body = json.dumps({"query": document, "variables": variables}).encode()
    request = urllib.request.Request(
        api_url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": key},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        die(f"Linear API returned HTTP {exc.code}: {detail.strip()}")
        raise  # unreachable; satisfies static readers that die() never returns
    except urllib.error.URLError as exc:
        die(f"could not reach {api_url}: {exc.reason}")
        raise

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"Linear API returned a non-JSON response: {exc}")
        raise

    if payload.get("errors"):
        die(f"Linear API returned errors: {payload['errors']}")
    return payload.get("data") or {}


def _pick_unique(nodes: list, kind: str, name: str) -> dict:
    """Return the one node named `name`. Absence and ambiguity both refuse.

    A name is not an id, and resolution is the one moment it is trusted --
    two teams, projects, states or labels sharing a name is not a coin flip.
    """
    matches = [n for n in nodes if n.get("name") == name]
    if not matches:
        die(f"no {kind} named {name!r}")
    if len(matches) > 1:
        ids = ", ".join(sorted(n["id"] for n in matches))
        die(
            f"{len(matches)} {kind}s are named {name!r} ({ids}) -- ambiguous, "
            "refusing to guess which one the board is allowed to write to"
        )
    return matches[0]


def resolve_team(api_url: str, key: str, name: str) -> str:
    data = query(api_url, key, TEAM_QUERY, {"name": name})
    node = _pick_unique(data.get("teams", {}).get("nodes", []), "team", name)
    return node["id"]


def resolve_project(api_url: str, key: str, team_id: str, name: str) -> str:
    data = query(api_url, key, PROJECT_QUERY, {"teamId": team_id, "name": name})
    nodes = data.get("team", {}).get("projects", {}).get("nodes", [])
    node = _pick_unique(nodes, "project", name)
    return node["id"]


def resolve_states(api_url: str, key: str, team_id: str) -> dict:
    """Resolve the six workflow states, and verify the to-pick-up one.

    Returns {role: id} for every role in STATE_ROLES.
    """
    data = query(api_url, key, STATES_QUERY, {"teamId": team_id})
    nodes = data.get("team", {}).get("states", {}).get("nodes", [])

    # Name every missing column in one message, before resolving any of them.
    # _pick_unique on its own answers `no state named 'Plan'`: true, but it
    # leaves the operator to work out that the fix is a column in Linear, and
    # it stops at the first absence, so a team missing two columns costs two
    # runs to learn both. Adding the Plan column made that concrete -- every
    # board that existed before it hit this path.
    present = {node.get("name") for node in nodes}
    missing = [name for _, name in STATE_ROLES if name not in present]
    if missing:
        plural = len(missing) > 1
        die(
            f"this team has no workflow {'columns' if plural else 'column'} "
            f"named {', '.join(repr(name) for name in missing)} -- create "
            f"{'them' if plural else 'it'} in Linear, then run this again. A "
            "missing label is created here; a missing column never is. A "
            "column is the operator's own board layout, and one the board "
            "invented is one nobody agreed to."
        )

    ids: dict = {}
    for role, state_name in STATE_ROLES:
        node = _pick_unique(nodes, "state", state_name)
        if role == TO_PICK_UP_ROLE and node.get("type") != TO_PICK_UP_TYPE:
            die(
                f"the to-pick-up state ({state_name!r}, id {node['id']!r}) has "
                f"type {node.get('type')!r}, not {TO_PICK_UP_TYPE!r} -- refusing. "
                "A mismatch here is the difference between a card that waits "
                "for pickup and a card the board would ship on its own."
            )
        ids[role] = node["id"]
    return ids


def ensure_labels(api_url: str, key: str, team_id: str) -> dict:
    """Resolve the four board-owned labels, creating any that are missing.

    Returns {role: id} for every role in LABEL_ROLES. Whether a label was
    found or just created, its id is independently verified by querying it
    back by id and checking the name that comes back -- the found-existing
    path and the just-created path share this one guard, because a mismatch
    on either would re-file every finding, every run, forever.
    """
    data = query(api_url, key, LABELS_QUERY, {"teamId": team_id})
    nodes = data.get("team", {}).get("labels", {}).get("nodes", [])
    ids: dict = {}
    for role, label_name in LABEL_ROLES:
        matches = [n for n in nodes if n.get("name") == label_name]
        if len(matches) > 1:
            found = ", ".join(sorted(n["id"] for n in matches))
            die(
                f"{len(matches)} labels are named {label_name!r} ({found}) -- "
                "ambiguous, refusing to guess which one the board is allowed "
                "to write to"
            )
        if matches:
            label_id = matches[0]["id"]
        else:
            created = query(
                api_url,
                key,
                CREATE_LABEL_MUTATION,
                {"teamId": team_id, "name": label_name},
            )
            result = created.get("issueLabelCreate") or {}
            issue_label = result.get("issueLabel")
            if not result.get("success") or not issue_label:
                die(f"failed to create label {label_name!r}")
            label_id = issue_label["id"]

        verify = query(api_url, key, LABEL_BY_ID_QUERY, {"id": label_id})
        found = verify.get("issueLabel")
        found_name = found.get("name") if found else None
        if found_name != label_name:
            die(
                f"label {label_name!r} resolved to id {label_id!r}, but that id "
                f"is named {found_name!r} -- refusing. A mismatch here re-files "
                "every finding, every run, forever."
            )
        ids[role] = label_id
    return ids


def write_ids(instance_home: str, ids: dict) -> None:
    """Write ids.env atomically: a sibling temp file, chmod 0600, os.replace.

    os.replace() is an atomic rename on a POSIX filesystem, so a reader never
    observes a partially written file, and a process that dies mid-write
    leaves the temp file behind rather than corrupting ids.env. The bigger
    guarantee is upstream of this function, though: every resolve_* /
    ensure_labels call happens before write_ids is ever reached, so the first
    failure anywhere -- a bad state type, a mismatched label, an ambiguous
    project, an unreachable API -- raises and this function never runs at all,
    leaving whatever ids.env already existed untouched.
    """
    # Create the runtime directory here rather than assuming it.
    #
    # It used to be a side effect of `boardctl add`, which built an instance
    # directory. A board is now two lines in boards.toml and nothing makes a
    # directory for it, so the first resolve on a newly declared board died with
    # FileNotFoundError on ids.env.tmp -- found by declaring a real board and
    # running this for real, not by the suite.
    #
    # This is also the right owner for it: ids.env is a cache, documented as safe
    # to delete, so whatever rebuilds the cache has to be able to rebuild the
    # directory holding it.
    os.makedirs(instance_home, exist_ok=True)
    target = os.path.join(instance_home, "ids.env")
    tmp = os.path.join(instance_home, "ids.env.tmp")
    with open(tmp, "w") as handle:
        for env_key in IDS_ENV_ORDER:
            handle.write(f"{env_key}={ids[env_key]}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)


def _load_instance_config(instance: str) -> dict:
    """Read INSTANCE_HOME, FOREMAN_HOME and the contract's Linear names.

    Sourced through skills/board/config.sh the way reconcile.py and
    preflight.py already read their settings -- not re-implemented here,
    because a second parser is a parser that silently stops matching the one
    an operator's config actually goes through. `printf ... \\0` into the
    subprocess's own stdout is safe from the bash-3.2 NUL-in-$(...) bug
    because it never passes through a `$(...)` capture inside bash itself;
    Python's subprocess.run reads the raw bytes directly.

    REPO, BOARD_HOME and INSTANCE_HOME are scrubbed from the environment
    handed to that subprocess, even though config.sh exports all three
    (`export REPO INSTANCE INSTANCE_HOME BOARD_HOME FOREMAN_HOME`) and reads
    instance.env with `-`, not `:-`, so an already-set value always wins (see
    config.sh:56 -- that is deliberate, and test-config-resolves-instance.sh
    depends on it, for values an operator legitimately overrides per call).
    Left alone here, that combination is a leak: any shell that has sourced
    config.sh once for instance A carries A's REPO in its environment, and
    resolving ids for a DIFFERENT instance B -- `boardctl add B ...` typed
    straight after debugging A in the same terminal -- would silently ignore
    B's own instance.env and pin instance A's team and project into B's
    ids.env. This function's whole job is "derive config fresh for exactly
    the named --instance", and `boardctl add` already writes instance.env's
    REPO before ever calling this script (see boardctl's own comment), so
    there is no legitimate reason for it to inherit an ambient REPO from
    whatever ran before it in this process's environment.
    """
    keys = ("INSTANCE_HOME", "FOREMAN_HOME", "LINEAR_TEAM_NAME", "LINEAR_PROJECT_NAME")
    script = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "skills",
        "board",
        "config.sh",
    )
    printf = 'printf "%s\\0" ' + " ".join(f'"${k}"' for k in keys)
    env = dict(os.environ)
    # FOREMAN_HOME is deliberately NOT scrubbed here. It names the machine's
    # foreman root, not one board's derived state, and an operator (and every
    # test) sets it on purpose to move every board at once. The three below
    # are per-board values config.sh exports, which is what makes them a leak.
    for leaked in ("REPO", "BOARD_HOME", "INSTANCE_HOME"):
        env.pop(leaked, None)
    env["FOREMAN_INSTANCE"] = instance
    result = subprocess.run(
        ["bash", "-c", f". {script!r} >/dev/null; {printf}"],
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    values = result.stdout.split("\0")
    if result.returncode != 0 or len(values) < len(keys):
        die(f"could not read {script}: {result.stderr.strip()}")
    return dict(zip(keys, values))


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", required=True, help="instance name (FOREMAN_INSTANCE)")
    parser.add_argument("--api-url", default=DEFAULT_API_URL, help="Linear GraphQL endpoint")
    parser.add_argument(
        "--key-file",
        default=None,
        help="Linear API key file; defaults to $FOREMAN_HOME/linear.key",
    )
    args = parser.parse_args(argv)

    try:
        cfg = _load_instance_config(args.instance)
        instance_home = cfg["INSTANCE_HOME"]
        team_name = cfg["LINEAR_TEAM_NAME"]
        project_name = cfg["LINEAR_PROJECT_NAME"]

        # One credential per Linear workspace, in the machine's foreman root.
        # --key-file exists for the one board that lives in a DIFFERENT
        # workspace and therefore needs a different key; boards.toml carries
        # that path per board. No fallback to the old per-board copy and no
        # fallback to an empty key: a key read as "" reaches Linear as an
        # unauthenticated request, and the operator reads the resulting error
        # as "Linear is down", not "the key file moved".
        key_path = args.key_file or os.path.join(cfg["FOREMAN_HOME"], "linear.key")
        try:
            with open(key_path) as handle:
                key = handle.read().strip()
        except OSError as exc:
            die(f"could not read {key_path}: {exc}")
        if not key:
            die(f"{key_path} is empty")

        team_id = resolve_team(args.api_url, key, team_name)
        project_id = resolve_project(args.api_url, key, team_id, project_name)
        state_ids = resolve_states(args.api_url, key, team_id)
        label_ids = ensure_labels(args.api_url, key, team_id)

        ids = {
            "LINEAR_TEAM_ID": team_id,
            "LINEAR_PROJECT_ID": project_id,
            **state_ids,
            **label_ids,
        }
        write_ids(instance_home, ids)
    except ResolveError as exc:
        print(f"resolve-ids: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
