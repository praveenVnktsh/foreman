#!/usr/bin/env bash
# --overview must carry each board's monitor state, so the page can name the
# board whose Monitor is not alive and the age of its stamp. A halted machine
# whose page does not say why sends the operator to the logs, and the halt is
# the one state where that costs the most.
#
# It rides on --overview rather than a second call from bin/dashboard.py,
# because that file derives nothing: every number on the page comes from one
# --overview. Two readers of one fact is the drift _load_config warns about.
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
fail=0

out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
       "$board_dir/reconcile.py" --overview)" \
  || { echo "FAIL --overview did not answer" >&2; exit 1; }

# A board with no stamp reports stale, and --overview stays TOLERANT: it must
# report what it could reach, never raise. A crash renders as nothing at all.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
board = next(b for b in d["boards"] if b["name"] == "demo")
m = board["monitor"]
assert m["present"] is False, m
assert m["stale"] is True, m
assert m["age_seconds"] is None, m
' || { echo "FAIL --overview does not carry monitor state" >&2; fail=1; }

# The page must render it. It reads --overview and nothing else.
grep -q 'monitor' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py does not render the monitor field" >&2; fail=1; }
python3 -c "import ast; ast.parse(open('$repo_root/bin/dashboard.py').read())" \
  || { echo "FAIL dashboard.py does not parse" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --overview carries monitor state and the page renders it"
exit "$fail"
