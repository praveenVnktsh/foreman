#!/usr/bin/env bash
# watch-agents.py must stamp $BOARD_HOME/monitor.stamp on every poll, including
# the silent seeding poll and a poll that sees no dispatched agents. The stamp
# is the only evidence that a Monitor is armed: a Monitor lives inside the
# session and nothing persists it, and a tick asked to report its own arming
# reports intent rather than liveness. A board with no agents in flight must
# still stamp, or an idle board reads as an unarmed one and stops the machine.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
  python3 - "$board_dir" <<'PY'
import importlib.util
import os
import sys
import time

board_dir = sys.argv[1]
sys.path.insert(0, board_dir)

spec = importlib.util.spec_from_file_location(
    "watch_agents", os.path.join(board_dir, "watch-agents.py")
)
watch_agents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch_agents)

stamp_path = watch_agents.STAMP_PATH
assert not os.path.exists(stamp_path), "the fixture must start with no stamp"

# A poll that finds nothing must still stamp. An idle board is not an unarmed
# one, and main()'s loop skips an empty poll -- so the stamp cannot live after
# that skip.
watch_agents.stamp()
assert os.path.exists(stamp_path), f"no stamp written at {stamp_path}"
first = os.path.getmtime(stamp_path)

body = open(stamp_path).read()
assert body.endswith("\n"), f"stamp must end with a newline, got {body!r}"
lines = body.splitlines()
time.strptime(lines[0], "%Y-%m-%dT%H:%M:%SZ")

# THE POLL TRAVELS WITH THE STAMP. watch-agents.py reads WATCH_POLL_SECONDS
# from the tick session's environment and config.sh derives the staleness window
# from supervise.sh's cron environment, which has no profile and no exports.
# Nothing else carries the value between the two, so an operator who exported it
# got a watcher stamping every 60s and a supervisor demanding one every 60s -- a
# permanent halt of a healthy machine.
assert f"poll={watch_agents.POLL_SECONDS}" in lines, \
    f"stamp does not record the poll it was written at: {body!r}"

# Every poll refreshes it. A stamp written once proves a process started; a
# stamp refreshed every WATCH_POLL_SECONDS proves the Monitor is alive now.
time.sleep(1.1)
watch_agents.stamp()
second = os.path.getmtime(stamp_path)
assert second > first, f"stamp not refreshed: {first} then {second}"

# THE PLACEMENT IS THE CLAIM, AND ONLY main() CAN TEST IT. Calling stamp()
# directly proves the function writes a file and nothing about WHERE it is
# called: move the call below the empty-poll `continue` and every assertion
# above still passes, while a board with no dispatched agents would stop
# stamping and halt the machine. So drive the real main(), with poll() stubbed
# to return nothing -- the idle board -- and one sleep allowed before the loop
# is broken out of.
class _Stop(Exception):
    pass


polls = []


def _empty_poll():
    polls.append(1)
    # THE SEEDING STAMP IS REMOVED HERE, from inside the first poll, so that the
    # file existing at the end can only be the work of the stamp() inside the
    # loop. Removing it before main() would leave main()'s own pre-loop stamp()
    # to satisfy the assertion, and the placement under test -- above the
    # empty-poll `continue`, not below it -- would go unexercised again.
    if len(polls) == 1:
        os.remove(stamp_path)
    return {}


def _one_sleep(_seconds):
    # Two sleeps means the loop went round twice and stamped at least once
    # after the seeding poll, which is all this needs to observe.
    if len(polls) >= 2:
        raise _Stop


watch_agents.poll = _empty_poll
watch_agents.time.sleep = _one_sleep
try:
    watch_agents.main()
except _Stop:
    pass
assert os.path.exists(stamp_path), \
    "main() left no stamp: the call must sit above the empty-poll continue"
assert len(polls) >= 2, f"main() did not reach a second poll: {polls}"

print("ok   watch-agents.py stamps on every poll, empty or not")
PY
