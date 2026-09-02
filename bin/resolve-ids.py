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
  - The needs-answers state must be of type `started`. A `completed` one there
    shows every card parked for a question as finished, so the operator the
    pause exists for never learns there is a question waiting.
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
from typing import NamedTuple

DEFAULT_API_URL = "https://api.linear.app/graphql"


class StateRole(NamedTuple):
    """One workflow state the board moves cards through.

    `role` is the board's own vocabulary and never changes. `name` is what an
    operator sees in Linear and is free to rename -- which is exactly why this
    script exists, and why nothing downstream of it reads a name again.

    `type` is Linear's own state type, and it is VERIFIED when declared.
    `type_reason` is the sentence the refusal ends with, and it is a field
    rather than one shared line because the two states that declare a type do
    so for entirely different failures -- a refusal that cannot say which one
    it is protecting is a refusal the operator has to go and read this file to
    understand. Only those two declare a type at all; the other four are the
    operator's ordinary columns, and demanding a type of them would refuse an
    installation that has been working for months over a fact the board never
    reads.

    `create` says the board may create this column when the team does not have
    it. Exactly one state carries it, for the same reason the labels below are
    created: a fork's team has never had a reason to make a column the board
    invented, and the board cannot pause a card without somewhere to put it.
    """

    role: str
    name: str
    type: str | None = None
    type_reason: str = ""
    create: bool = False


# The six workflow states the board moves cards through (skills/board/
# SKILL.md), in the order a card walks them.
STATE_ROLES = [
    StateRole("STATE_PLANNED", "Backlog"),
    # The to-pick-up state is the one the board is never allowed to move a card
    # OUT of on its own initiative, and never allowed to move one INTO either --
    # it is where a human hands work to the board. `unstarted` is Linear's own
    # marker for "not begun".
    StateRole(
        "STATE_TO_PICK_UP",
        "Todo",
        type="unstarted",
        type_reason=(
            "A mismatch here is the difference between a card that waits for "
            "pickup and a card the board would ship on its own."
        ),
    ),
    StateRole("STATE_IN_PROGRESS", "In Progress"),
    # Where a card labelled `human-cobuild` waits for its operator. The board
    # moves cards in and never out, so this column is `Todo`'s mirror: the
    # operator answers on the card and moves it back, and that move is the
    # dispatch authorisation all over again. `started` is Linear's marker for
    # work that has begun, which is what a paused card is.
    StateRole(
        "STATE_NEEDS_ANSWERS",
        "Needs Answers",
        type="started",
        type_reason=(
            "A completed or cancelled column shows every card parked for a "
            "question as finished, so the operator the pause exists for never "
            "learns there is a question waiting."
        ),
        create=True,
    ),
    StateRole("STATE_IN_REVIEW", "In Review"),
    StateRole("STATE_MERGED", "Done"),
]

# The colour a created "Needs Answers" column gets. Linear requires one, and a
# board that refused to create the column over an unset colour would fail the
# whole resolve for a decoration. Amber, because the column means "waiting on a
# person", not "broken". An operator who wants another colour changes it in
# Linear and this script never touches it again -- it only ever creates a
# column that is missing.
CREATED_STATE_COLOR = "#f2994a"

# Labels the board owns and only ever writes onto cards itself, plus the one
# label the operator owns and the board only reads (skills/board/SKILL.md).
# All of them are created if missing -- a fork's team has never had a reason to
# create them by hand, and the board cannot function without somewhere to put a
# follow-up or a needs-merge flag. `human-cobuild` is created for the opposite
# reason: an operator cannot put a label on a card that does not exist yet, so
# a label the board never writes still has to be there before anyone can ask
# for a co-build.
LABEL_ROLES = [
    ("LABEL_FOLLOW_UP", "follow-up"),
    ("LABEL_FOLLOW_UPS_WRITTEN", "follow-ups-written"),
    ("LABEL_NEEDS_MERGE", "needs-merge"),
    ("LABEL_BOARD_FAILED", "board-failed"),
    ("LABEL_HUMAN_COBUILD", "human-cobuild"),
]

IDS_ENV_ORDER = (
    ["LINEAR_TEAM_ID", "LINEAR_PROJECT_ID"]
    + [state.role for state in STATE_ROLES]
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

CREATE_STATE_MUTATION = """
mutation CreateState($teamId: String!, $name: String!, $type: String!, $color: String!) {
  workflowStateCreate(input: { teamId: $teamId, name: $name, type: $type, color: $color }) {
    success
    workflowState { id name type }
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


def _find_state(nodes: list, state: StateRole) -> dict | None:
    """The one state named `state.name`, or None when it may be created.

    Absence refuses for every state the operator owns, and answers None for
    the one the board owns -- there is nothing to fall back to for a column
    Linear never ships and the operator has never heard of. Ambiguity refuses
    either way, through the same rule every other name goes through.
    """
    if state.create and not [n for n in nodes if n.get("name") == state.name]:
        return None
    return _pick_unique(nodes, "state", state.name)


def _create_state(api_url: str, key: str, team_id: str, state: StateRole) -> dict:
    """Create the board's own column, and check what came back is what was asked for.

    The id and the name arrive in one response, so this is the same strength of
    check the found-existing path gets from the states list: nothing here trusts
    an id that was never seen next to its own name.
    """
    created = query(
        api_url,
        key,
        CREATE_STATE_MUTATION,
        {
            "teamId": team_id,
            "name": state.name,
            "type": state.type,
            "color": CREATED_STATE_COLOR,
        },
    )
    result = created.get("workflowStateCreate") or {}
    node = result.get("workflowState")
    if not result.get("success") or not node:
        die(f"failed to create the {state.name!r} column")
    if node.get("name") != state.name:
        die(
            f"asked Linear to create the column {state.name!r} and it returned "
            f"one named {node.get('name')!r} -- refusing. The board would move "
            "every parked card into a column nobody is watching."
        )
    return node


def resolve_states(api_url: str, key: str, team_id: str) -> dict:
    """Resolve every workflow state, creating the one the board owns.

    Returns {role: id} for every role in STATE_ROLES.
    """
    data = query(api_url, key, STATES_QUERY, {"teamId": team_id})
    nodes = data.get("team", {}).get("states", {}).get("nodes", [])
    ids: dict = {}
    for state in STATE_ROLES:
        node = _find_state(nodes, state) or _create_state(api_url, key, team_id, state)
        if state.type is not None and node.get("type") != state.type:
            die(
                f"the {state.name!r} state (id {node['id']!r}) has type "
                f"{node.get('type')!r}, not {state.type!r} -- refusing. "
                f"{state.type_reason}"
            )
        ids[state.role] = node["id"]
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
