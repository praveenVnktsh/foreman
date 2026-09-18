#!/usr/bin/env python3
"""Is this board starved: a free slot, and a Todo card that has waited too long?

    FOREMAN_INSTANCE=<board> starved.py <board> --older-than <minutes>
        [--api-url URL] [--now <ISO-8601 UTC, tests only>]

THE FAILURE. On 2026-09-16 a self-looping tick stayed alive for two hours but
stopped reading one board's Todo column. A card waited 30 minutes with 8 free
slots (max_concurrent 10, 2 held). `reconcile.py --may-dispatch` allowed it
and `queue.py` ranked it. Only `supervise.sh --restart` moved it. The process
was alive, so a liveness check saw nothing wrong. A tick that stopped reading
Todo and a board with no work print the same thing: nothing. This file tells
them apart by reading Linear itself, outside the tick.

    stdout  exactly one JSON object when a verdict was reached:
            {"board": ..., "starved": true|false, "reason": "<one line>",
             "waiting": [{"identifier": "ABC-7", "waiting_minutes": 73.0}, ...]}
            `waiting` is oldest first, and may be empty.
    exit 0  a verdict was reached, starved or not.
    exit 1  no verdict. stdout is empty and stderr says what failed. A read
            that failed is never reported as "not starved": that is the same
            silence as the incident, one level up.
    exit 2  the call was wrong: bad argv, a board that is not declared, or a
            board that is not the one $FOREMAN_INSTANCE resolves.

NOT STARVED, in the order the reasons are checked (cheapest first):

- the board is halted (`instances/<board>/HALT`);
- the board holds `MAX_CONCURRENT` slots already (`reconcile.py --host-slots`);
- the machine refuses a dispatch (`reconcile.py --may-dispatch`);
- no Todo card is routed to this installation and rankable (`queue.py`);
- no such card is unblocked and has waited longer than `--older-than`;
- this board's `main` is not `green` or `running` (`reconcile.py --main-ci`);
- this machine is unfit to build this board (`preflight.py`).

Every one of those is a board the tick is right to leave alone. Anything else
with a waiting card is starved.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.join(os.path.dirname(os.path.dirname(SKILL_DIR)), "bin")
CONFIG_SH = os.path.join(SKILL_DIR, "config.sh")
RECONCILE_PY = os.path.join(SKILL_DIR, "reconcile.py")
QUEUE_PY = os.path.join(SKILL_DIR, "queue.py")
PREFLIGHT_PY = os.path.join(SKILL_DIR, "preflight.py")
INSTALLATION_PY = os.path.join(BIN_DIR, "installation.py")
BOARDS_PY = os.path.join(BIN_DIR, "boards.py")


def _load_resolve_ids():
    """bin/resolve-ids.py as a module, for its one Linear client.

    Loaded by path because the file name holds a hyphen. A second copy of the
    request, header and fail-closed error handling here would drift from the
    one resolve-ids.py tests against the same stub.
    """
    spec = importlib.util.spec_from_file_location(
        "resolve_ids", os.path.join(BIN_DIR, "resolve-ids.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resolve_ids = _load_resolve_ids()
DEFAULT_API_URL = resolve_ids.DEFAULT_API_URL

EXIT_NO_VERDICT = 1
EXIT_BAD_CALL = 2

# A local subprocess that runs longer than this is hung, not slow.
LOCAL_TIMEOUT_SECONDS = 60

# Linear's state type for a finished issue. A blocker in any other state still
# blocks, and SKILL.md step 6 skips a blocked card on purpose.
COMPLETED_STATE_TYPE = "completed"
BLOCKS_RELATION = "blocks"

# The `reconcile.py --main-ci` verdicts under which SKILL.md step 0 lets a board
# dispatch. Every other one -- red, rerunning, untested, none, unknown -- stands
# the board down: it "merges nothing and dispatches nothing". Found in review:
# without this gate a board with a red main read as starved, and supervise.sh
# replaced a healthy tick once a window for as long as main stayed red. A
# restart cannot fix main any more than it can fix Linear.
DISPATCHABLE_MAIN = frozenset({"green", "running"})

CONFIG_KEYS = (
    "INSTANCE", "INSTALLATION", "IS_DEFAULT", "KEY_FILE",
    "MAX_CONCURRENT", "HOST_MAX_CONCURRENT", "LINEAR_PROJECT_ID", "STATE_TO_PICK_UP",
)
# Written by bin/resolve-ids.py into ids.env. config.sh reads that file
# quietly when it is absent, so an empty value here means "never resolved".
IDS_ENV_KEYS = ("LINEAR_PROJECT_ID", "STATE_TO_PICK_UP")

# first: 100 with no cursor (PRA-461) hid a waiting card past the first page.
# starved.py then reported the board as not starved, and supervise.sh left
# the stuck tick running. Walk every page; refuse when pageInfo or a later
# page is unreadable. A partial walk as "not starved" is the same silence.
TODO_PAGE_SIZE = 100
TODO_QUERY = f"""
query TodoIssues($projectId: ID!, $stateId: ID!, $after: String) {{
  issues(filter: {{ project: {{ id: {{ eq: $projectId }} }}, state: {{ id: {{ eq: $stateId }} }} }}, first: {TODO_PAGE_SIZE}, after: $after) {{
    nodes {{
      identifier
      priority
      createdAt
      labels {{ nodes {{ name }} }}
      history(first: 50) {{ nodes {{ createdAt toState {{ id }} }} }}
      inverseRelations {{ nodes {{ type issue {{ identifier state {{ type }} }} }} }}
    }}
    pageInfo {{
      hasNextPage
      endCursor
    }}
  }}
}}
"""


class NoVerdict(Exception):
    """A read failed, so there is no answer. Exit 1, never "not starved"."""


class BadCall(Exception):
    """The caller asked the wrong question. Exit 2."""


# --- the pure core ---------------------------------------------------------


@dataclass(frozen=True)
class Waiting:
    identifier: str
    waiting_minutes: float


@dataclass(frozen=True)
class Verdict:
    board: str
    starved: bool
    reason: str
    waiting: tuple[Waiting, ...] = ()

    def to_json(self) -> str:
        return json.dumps(asdict(self))


@dataclass(frozen=True)
class TodoCard:
    """One Todo node, parsed once at the edge."""

    identifier: str
    entered_todo: datetime
    blocked: bool


def halted_verdict(board: str) -> Verdict:
    return Verdict(board, False, f"{board} is halted (instances/{board}/HALT exists)")


def ceiling_verdict(board: str, held: int, max_concurrent: int) -> Verdict | None:
    """Not starved when the board holds every slot it has; None when one is free."""
    if held < max_concurrent:
        return None
    return Verdict(board, False, f"{board} holds {held} of its {max_concurrent} "
                                 f"card slots, so it is at its ceiling")


def machine_verdict(board: str, refusal: str) -> Verdict | None:
    """Not starved when `reconcile.py --may-dispatch` printed a refusal line."""
    if not refusal:
        return None
    return Verdict(board, False, f"the machine refuses {board} a dispatch: {refusal}")


def todo_verdict(board: str, free_slots: int, cards: list[TodoCard],
                 routed: list[str], now: datetime, older_than: float) -> Verdict:
    """Starved when a routed, unblocked card has waited longer than `older_than`."""
    if not routed:
        return Verdict(board, False,
                       f"no Todo card on {board} is routed to this installation and rankable")
    by_id = {card.identifier: card for card in cards}
    waiting = []
    for identifier in routed:
        card = by_id.get(identifier)
        if card is None or card.blocked:
            continue
        minutes = round((now - card.entered_todo).total_seconds() / 60, 1)
        if minutes > older_than:
            waiting.append(Waiting(identifier, minutes))
    if not waiting:
        return Verdict(board, False,
                       f"none of the {len(routed)} routed Todo cards on {board} is "
                       f"unblocked and has waited longer than {older_than:g}m")
    waiting.sort(key=lambda w: (-w.waiting_minutes, w.identifier))
    oldest = waiting[0]
    reason = (f"{board} has {free_slots} free {'slot' if free_slots == 1 else 'slots'} "
              f"and {oldest.identifier} has waited {oldest.waiting_minutes:.0f}m in Todo")
    if len(waiting) > 1:
        reason += f", with {len(waiting) - 1} more waiting behind it"
    return Verdict(board, True, reason, tuple(waiting))


def main_ci_verdict(board: str, main_ci: dict, waiting: tuple[Waiting, ...]) -> Verdict | None:
    """Not starved when this board's `main` stands its dispatching down."""
    verdict = main_ci.get("verdict")
    if verdict in DISPATCHABLE_MAIN:
        return None
    return Verdict(board, False,
                   f"{board}'s main CI is {verdict} ({main_ci.get('reason', 'no reason given')}), "
                   f"so the board dispatches nothing", waiting)


def preflight_verdict(board: str, failed_checks: list[str],
                      waiting: tuple[Waiting, ...]) -> Verdict | None:
    """Not starved when preflight says this machine cannot build this board."""
    if not failed_checks:
        return None
    return Verdict(board, False,
                   f"this machine is unfit to build {board} ({', '.join(failed_checks)}), "
                   f"so dispatch.sh refuses every dispatch", waiting)


# --- parsing at the edge ---------------------------------------------------


def parse_stamp(text: object, what: str) -> datetime:
    if not isinstance(text, str):
        raise NoVerdict(f"{what} is {text!r}, not an ISO-8601 timestamp")
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        raise NoVerdict(f"{what} is {text!r}, not an ISO-8601 timestamp") from None
    if stamp.tzinfo is None:
        raise NoVerdict(f"{what} is {text!r}, which names no timezone")
    return stamp


def _nodes(parent: object, key: str, where: str) -> list:
    """`parent[key]["nodes"]` as a list, refused in any other shape."""
    container = parent.get(key) if isinstance(parent, dict) else None
    nodes = container.get("nodes") if isinstance(container, dict) else None
    if not isinstance(nodes, list):
        raise NoVerdict(f"{where}: {key}.nodes is not a list")
    return nodes


def parse_todo_connection(data: object, where: str) -> tuple[list, bool, str | None]:
    """One TodoIssues page: nodes, and the next cursor when another page follows.

    Missing pageInfo, a non-boolean hasNextPage, or hasNextPage with no cursor
    is an unreadable page, not an implicit last page.
    """
    connection = data.get("issues") if isinstance(data, dict) else None
    if not isinstance(connection, dict):
        raise NoVerdict(f"{where}: issues is not an object")
    nodes = connection.get("nodes")
    if not isinstance(nodes, list):
        raise NoVerdict(f"{where}: issues.nodes is not a list")
    page_info = connection.get("pageInfo")
    if not isinstance(page_info, dict):
        raise NoVerdict(f"{where}: issues.pageInfo is not an object")
    has_next = page_info.get("hasNextPage")
    if not isinstance(has_next, bool):
        raise NoVerdict(f"{where}: issues.pageInfo.hasNextPage is not a boolean")
    if not has_next:
        return nodes, False, None
    cursor = page_info.get("endCursor")
    if not isinstance(cursor, str) or not cursor:
        raise NoVerdict(f"{where}: issues.pageInfo.hasNextPage is true but "
                        f"endCursor is {cursor!r}, not a cursor string")
    if not nodes:
        raise NoVerdict(f"{where}: issues.pageInfo.hasNextPage is true but nodes is empty")
    return nodes, True, cursor


def parse_card(node: object, state_id: str) -> TodoCard:
    """One Linear node as a TodoCard. A shape nobody taught this refuses.

    The card entered Todo at its newest history entry into STATE_TO_PICK_UP.
    A card created straight into Todo has no such entry, so its createdAt
    stands in. `history(first: 50)` can miss an older entry on a busy card;
    that reads the card as waiting longer, which costs at most one restart and
    never hides a starved board.
    """
    if not isinstance(node, dict) or not isinstance(node.get("identifier"), str):
        raise NoVerdict(f"a Todo issue has no identifier: {node!r}")
    identifier = node["identifier"]
    entries = [parse_stamp(entry.get("createdAt"), f"{identifier} history createdAt")
               for entry in _nodes(node, "history", identifier)
               if isinstance(entry, dict)
               and isinstance(entry.get("toState"), dict)
               and entry["toState"].get("id") == state_id]
    entered = max(entries) if entries else parse_stamp(node.get("createdAt"),
                                                       f"{identifier} createdAt")
    blocked = False
    for relation in _nodes(node, "inverseRelations", identifier):
        if not isinstance(relation, dict) or relation.get("type") != BLOCKS_RELATION:
            continue
        blocker = relation.get("issue")
        state = blocker.get("state") if isinstance(blocker, dict) else None
        if not isinstance(state, dict):
            raise NoVerdict(f"{identifier}: a blocking relation names no issue state")
        blocked = blocked or state.get("type") != COMPLETED_STATE_TYPE
    return TodoCard(identifier, entered, blocked)


# --- I/O -------------------------------------------------------------------


def run(args: list[str], what: str, stdin: str | None = None,
        env: dict | None = None) -> subprocess.CompletedProcess:
    """Run one local command. Its stderr passes through to ours, unread."""
    try:
        return subprocess.run(args, input=stdin, stdout=subprocess.PIPE, text=True,
                              env=env, timeout=LOCAL_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise NoVerdict(f"could not run {what}: {exc}") from exc


def nul_fields(text: str) -> list[str]:
    return [field for field in text.split("\0") if field]


def foreman_home() -> str:
    """This installation's home, asked of the loader config.sh itself asks.

    Read BEFORE config.sh, because a halted board's config must not be sourced
    (SKILL.md), and the HALT file lives under this home.
    """
    done = run([INSTALLATION_PY], "bin/installation.py")
    fields = nul_fields(done.stdout)
    pairs = dict(zip(fields[0::2], fields[1::2]))
    if done.returncode != 0 or not pairs.get("FOREMAN_HOME"):
        raise NoVerdict(f"bin/installation.py did not name FOREMAN_HOME "
                        f"(exit {done.returncode})")
    return pairs["FOREMAN_HOME"]


def require_declared(home: str, board: str) -> None:
    boards_toml = os.path.join(home, "boards.toml")
    done = run([BOARDS_PY, "--file", boards_toml, "--list"], "bin/boards.py --list")
    if done.returncode != 0:
        raise NoVerdict(f"{boards_toml} did not load (boards.py exited {done.returncode})")
    if board not in nul_fields(done.stdout):
        raise BadCall(f"no board named {board} in {boards_toml}")


def load_config() -> dict[str, str]:
    """config.sh's values, sourced in a subshell the way reconcile.py reads them."""
    printf = 'printf "%s\\0" ' + " ".join(f'"${key}"' for key in CONFIG_KEYS)
    done = run(["bash", "-c", f". {CONFIG_SH!r} >/dev/null; {printf}"], "config.sh")
    values = done.stdout.split("\0")
    if done.returncode != 0 or len(values) < len(CONFIG_KEYS):
        raise NoVerdict(f"could not read {CONFIG_SH} (exit {done.returncode})")
    config = dict(zip(CONFIG_KEYS, values))
    missing = [key for key in IDS_ENV_KEYS if not config[key]]
    if missing:
        raise NoVerdict(f"{', '.join(missing)} missing from "
                        f"instances/{config['INSTANCE']}/ids.env; run bin/resolve-ids.py")
    return config


def int_setting(config: dict[str, str], key: str) -> int:
    try:
        return int(config[key])
    except ValueError:
        raise NoVerdict(f"{key} is {config[key]!r}, which is not an integer") from None


def slots_held(config: dict[str, str], board: str) -> int:
    done = run([RECONCILE_PY, "--host-slots"], "reconcile.py --host-slots")
    if done.returncode != 0:
        raise NoVerdict(f"reconcile.py --host-slots exited {done.returncode}")
    key = f"{config['INSTALLATION']}/{board}"
    try:
        tickets = json.loads(done.stdout)["tickets"][key]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise NoVerdict(f"reconcile.py --host-slots named no tickets for {key}: {exc!r}") from exc
    return len(tickets)


def machine_refusal(config: dict[str, str], board: str) -> str:
    # HOST_MAX_CONCURRENT reaches reconcile.py through the environment, the way
    # dispatch.sh passes it. Left out, reconcile.py weighs its own default.
    env = {**os.environ, "HOST_MAX_CONCURRENT": config["HOST_MAX_CONCURRENT"]}
    done = run([RECONCILE_PY, "--may-dispatch", board], "reconcile.py --may-dispatch", env=env)
    if done.returncode != 0:
        raise NoVerdict(f"reconcile.py --may-dispatch {board} exited {done.returncode}")
    return done.stdout.strip()


def main_ci(board: str) -> dict:
    done = run([RECONCILE_PY, "--main-ci"], "reconcile.py --main-ci")
    try:
        state = json.loads(done.stdout) if done.returncode == 0 else None
    except json.JSONDecodeError:
        state = None
    if not isinstance(state, dict) or not isinstance(state.get("verdict"), str):
        raise NoVerdict(f"reconcile.py --main-ci gave no verdict for {board} "
                        f"(exit {done.returncode})")
    return state


def failed_preflight_checks() -> list[str]:
    """The names of the preflight checks that fail; empty when the machine is fit.

    The FULL gate, because that is the one dispatch.sh runs: `--quick` passes a
    machine the full gate refuses (a dead token, an unreachable origin), and a
    board dispatch.sh refuses is not starved.
    """
    done = run([PREFLIGHT_PY, "--quiet"], "preflight.py")
    if done.returncode == 0:
        return []
    try:
        report = json.loads(done.stdout)
        failed = [str(check["name"]) for check in report["checks"] if not check["ok"]]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise NoVerdict(f"preflight.py exited {done.returncode} with no readable verdict") from exc
    if report.get("fit") is not False or not failed:
        raise NoVerdict(f"preflight.py exited {done.returncode} but named no failed check")
    return failed


def read_key(key_file: str) -> str:
    try:
        with open(key_file, encoding="utf-8") as handle:
            key = handle.read().strip()
    except OSError as exc:
        raise NoVerdict(f"could not read the Linear key {key_file}: {exc}") from exc
    if not key:
        raise NoVerdict(f"the Linear key {key_file} is empty")
    return key


def todo_nodes(api_url: str, key: str, config: dict[str, str]) -> list:
    """Every Todo issue, walking Linear's cursor until it reports no next page."""
    nodes: list = []
    after = None
    seen_cursors: set[str] = set()
    page = 0
    while True:
        page += 1
        where = f"Linear TodoIssues page {page}"
        variables = {"projectId": config["LINEAR_PROJECT_ID"],
                     "stateId": config["STATE_TO_PICK_UP"],
                     "after": after}
        try:
            data = resolve_ids.query(api_url, key, TODO_QUERY, variables)
        except resolve_ids.ResolveError as exc:
            raise NoVerdict(f"{where}: {exc}") from exc
        except OSError as exc:
            # query() maps URLError; a read that times out mid-response raises
            # TimeoutError, which is an OSError and not a URLError.
            raise NoVerdict(f"{where}: could not read {api_url}: {exc}") from exc
        page_nodes, has_next, cursor = parse_todo_connection(data, where)
        nodes.extend(page_nodes)
        if not has_next:
            return nodes
        if cursor in seen_cursors:
            raise NoVerdict(f"{where}: Linear repeated cursor {cursor!r}")
        seen_cursors.add(cursor)
        after = cursor


def routed_identifiers(home: str, config: dict[str, str], nodes: list) -> list[str]:
    """The Todo cards this installation owns and can rank, from queue.py.

    Asked of queue.py rather than re-derived, so a card the tick would never
    dispatch -- a sibling's, or one with no priority -- never reads as starved.
    """
    listing = run([INSTALLATION_PY, "--home", home, "--siblings"],
                  "bin/installation.py --siblings")
    fields = nul_fields(listing.stdout)
    if listing.returncode != 0 or not fields or len(fields) % 2:
        raise NoVerdict(f"could not list the installations under {home}")
    args = [QUEUE_PY, "--installation", config["INSTALLATION"],
            "--siblings", ",".join(fields[0::2])]
    if config["IS_DEFAULT"]:
        args.append("--default")
    done = run(args, "queue.py", stdin=json.dumps(nodes))
    # 3 is "nothing ranked" with an empty stdout; queue.py names each card on
    # stderr, which reaches the operator through ours.
    if done.returncode not in (0, 3):
        raise NoVerdict(f"queue.py refused the Todo batch (exit {done.returncode})")
    return [line for line in done.stdout.splitlines() if line]


# --- the command -----------------------------------------------------------


class _Parser(argparse.ArgumentParser):
    def error(self, message: str):
        raise BadCall(message)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = _Parser(prog="starved.py", add_help=False)
    parser.add_argument("board")
    parser.add_argument("--older-than", type=float, required=True)
    parser.add_argument("--api-url", default=DEFAULT_API_URL)
    parser.add_argument("--now")
    args = parser.parse_args(argv)
    if args.older_than < 0:
        raise BadCall(f"--older-than is {args.older_than:g}; it must not be negative")
    if args.now is None:
        args.now = datetime.now(timezone.utc)
    else:
        try:
            args.now = parse_stamp(args.now, "--now")
        except NoVerdict as exc:
            raise BadCall(str(exc)) from None
    return args


def verdict_for(args: argparse.Namespace) -> Verdict:
    board = args.board
    # Named in the command AND resolved from the environment, like
    # `reconcile.py --cleanup-due`. A stale FOREMAN_INSTANCE is this skill's
    # oldest bug shape, and answering for a neighbour would weigh one board's
    # Todo against another board's ceiling and ids.
    resolved = os.environ.get("FOREMAN_INSTANCE", "")
    if board != resolved:
        raise BadCall(f"FOREMAN_INSTANCE is {resolved!r}, so this process cannot "
                      f"answer for {board}; run it with FOREMAN_INSTANCE={board}")
    home = foreman_home()
    require_declared(home, board)
    if os.path.exists(os.path.join(home, "instances", board, "HALT")):
        return halted_verdict(board)

    config = load_config()
    max_concurrent = int_setting(config, "MAX_CONCURRENT")
    held = slots_held(config, board)
    at_ceiling = ceiling_verdict(board, held, max_concurrent)
    if at_ceiling:
        return at_ceiling
    # Asked only once the board's own ceiling has room: it walks every board on
    # the machine, and a board at its ceiling is not starved whatever it says.
    refused = machine_verdict(board, machine_refusal(config, board))
    if refused:
        return refused

    nodes = todo_nodes(args.api_url, read_key(config["KEY_FILE"]), config)
    cards = [parse_card(node, config["STATE_TO_PICK_UP"]) for node in nodes]
    routed = routed_identifiers(home, config, nodes)
    verdict = todo_verdict(board, max_concurrent - held, cards, routed,
                           args.now, args.older_than)
    if not verdict.starved:
        return verdict
    # The two stand-downs of SKILL.md step 0, asked last and only of a board that
    # would otherwise be starved: --main-ci calls gh, and the full preflight
    # fetches and writes its probes, which is too much to spend on every board
    # every fire.
    return (main_ci_verdict(board, main_ci(board), verdict.waiting)
            or preflight_verdict(board, failed_preflight_checks(), verdict.waiting)
            or verdict)


def main(argv: list[str]) -> int:
    try:
        verdict = verdict_for(parse_args(argv))
    except BadCall as exc:
        print(f"starved: {exc}\nusage: FOREMAN_INSTANCE=<board> starved.py <board> "
              f"--older-than <minutes> [--api-url URL] [--now ISO-8601]", file=sys.stderr)
        return EXIT_BAD_CALL
    except NoVerdict as exc:
        print(f"starved: {exc}", file=sys.stderr)
        return EXIT_NO_VERDICT
    print(verdict.to_json())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
