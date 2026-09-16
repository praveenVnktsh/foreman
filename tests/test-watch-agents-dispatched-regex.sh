#!/usr/bin/env bash
# watch-agents.py's DISPATCHED regex must match a ticket whose Linear team key
# contains a digit. Nothing else in the codebase constrains a team key to
# letters only -- bin/contract.py takes `linear.team` as an arbitrary
# non-empty string, bin/resolve-ids.py resolves it by name with no charset
# check, and reconcile.py's own agents_for() matches agents by plain prefix,
# never a regex. A team key with a digit in it (Linear allows them) would
# still dispatch and still show up in `claude agents --json --all`, but
# silently never matched DISPATCHED -- this Monitor then never reports that
# instance's agents finishing, and the event-driven wakeup this whole script
# exists for quietly stops working for that one instance, with no error.
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

# FOREMAN_HOME is named explicitly. config.sh no longer derives it from $HOME:
# it asks bin/installation.py, which reads the home as the parent of this
# clone. An explicit home is what that derivation yields to, and it is how this
# file stays pointed at its temporary directory.
HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
  python3 - "$board_dir" <<'PY'
import importlib.util
import os
import sys

board_dir = sys.argv[1]
sys.path.insert(0, board_dir)

spec = importlib.util.spec_from_file_location(
    "watch_agents", os.path.join(board_dir, "watch-agents.py")
)
watch_agents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch_agents)

failures = []


def check(ok, what, detail=""):
    if ok:
        print(f"    ok: {what}")
    else:
        failures.append(what)
        print(f"    FAIL: {what} {detail}")


# INSTANCE is "demo", from FOREMAN_INSTANCE above. This home declares no
# installation.toml, so bin/installation.py reads it as the lone Claude
# installation with legacy names, and no dispatched name carries an
# installation segment.
digit_team = "foreman/demo/AB2-7/build-1"
letters_only_team = "foreman/demo/PRA-7/build-1"
tick_agent = "foreman/tick"
other_instance = "foreman/other/AB2-7/build-1"

check(watch_agents._dispatched(letters_only_team) == ("PRA-7", "build", "1"),
      "a letters-only team key still matches (no regression)",
      repr(watch_agents._dispatched(letters_only_team)))

check(watch_agents._dispatched(digit_team) == ("AB2-7", "build", "1"),
      "a team key containing a digit matches DISPATCHED",
      repr(watch_agents._dispatched(digit_team)))

check(watch_agents._dispatched(tick_agent) is None,
      "the tick agent itself still never matches")

check(watch_agents._dispatched(other_instance) is None,
      "a digit-team ticket from a DIFFERENT instance is still ignored")

# Every role dispatch.sh will spawn. A role this regex does not know finishes
# without waking the board at all.
for role in ("plan", "build", "review"):
    name = f"foreman/demo/PRA-7/{role}-1"
    check(watch_agents._dispatched(name) == ("PRA-7", role, "1"),
          f"a {role} agent matches DISPATCHED",
          repr(watch_agents._dispatched(name)))

# A scheduled cleanup run has no card yet, so its ticket segment is the
# literal word "cleanup", not a Linear key -- and dispatch.sh names the
# agent's role "cleanup" too.
cleanup_agent = "foreman/demo/cleanup/cleanup-202609150900"
check(watch_agents._dispatched(cleanup_agent) == ("cleanup", "cleanup", "202609150900"),
      "the cleanup agent matches DISPATCHED",
      repr(watch_agents._dispatched(cleanup_agent)))

if failures:
    sys.exit(1)
PY
