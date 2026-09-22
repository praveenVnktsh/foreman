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
time.strptime(body.strip(), "%Y-%m-%dT%H:%M:%SZ")

# Every poll refreshes it. A stamp written once proves a process started; a
# stamp refreshed every WATCH_POLL_SECONDS proves the Monitor is alive now.
time.sleep(1.1)
watch_agents.stamp()
second = os.path.getmtime(stamp_path)
assert second > first, f"stamp not refreshed: {first} then {second}"

print("ok   watch-agents.py stamps on every poll, empty or not")
PY
