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

# THE MACHINE-WIDE HALT, top-level and beside the tick. supervise.sh writes
# $FOREMAN_HOME/HALT and stops every board; a picture that carries only each
# board's own HALT reports that machine as "no tick running", which sends the
# operator to the cron log to find out why.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["machine_halt"]["halted"] is False, d["machine_halt"]
assert d["machine_halt"]["reason"] == "", d["machine_halt"]
' || { echo "FAIL --overview claims a halt on a machine with no marker" >&2; fail=1; }

printf 'halted because the Monitor is not armed\n' >"$py_home/.foreman/HALT"
halted_out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
              "$board_dir/reconcile.py" --overview)" \
  || { echo "FAIL --overview did not answer with a halt marker present" >&2; exit 1; }
printf '%s' "$halted_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
mh = d["machine_halt"]
assert mh["halted"] is True, mh
assert mh["marker"].endswith("/HALT"), mh
assert "Monitor is not armed" in mh["reason"], mh
# The machine halt is its OWN fact. A board that is not parked must still read
# unhalted, or a reader cannot tell one stopped board from a stopped machine.
assert all(b["halted"] is False for b in d["boards"]), d["boards"]
' || { echo "FAIL --overview does not carry the machine halt" >&2; fail=1; }

# AN EMPTY MARKER IS NOT AN UNREADABLE ONE. The page prints one sentence for
# each, and folding them together sends the operator hunting a permissions
# fault that does not exist.
: >"$py_home/.foreman/HALT"
empty_out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
             "$board_dir/reconcile.py" --overview)" \
  || { echo "FAIL --overview did not answer with an empty marker" >&2; exit 1; }
printf '%s' "$empty_out" | python3 -c '
import json, sys
mh = json.load(sys.stdin)["machine_halt"]
assert mh["halted"] is True, mh
assert mh["reason"] == "", mh
assert mh["readable"] is True, mh
' || { echo "FAIL an empty but readable marker is not distinguished" >&2; fail=1; }
printf 'halted because the Monitor is not armed\n' >"$py_home/.foreman/HALT"

# TOLERANT, even when the marker cannot be read. A halt nobody can explain is
# still a halt, and raising here renders as a blank page rather than a problem.
chmod 000 "$py_home/.foreman/HALT"
unreadable="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
              "$board_dir/reconcile.py" --overview)" \
  && printf '%s' "$unreadable" | python3 -c '
import json, sys
mh = json.load(sys.stdin)["machine_halt"]
assert mh["halted"] is True, mh
assert mh["readable"] is False, mh
' || { echo "FAIL an unreadable marker did not report a halt" >&2; fail=1; }
chmod 644 "$py_home/.foreman/HALT"
rm -f "$py_home/.foreman/HALT"

# The page must render it. It reads --overview and nothing else.
grep -q 'monitor' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py does not render the monitor field" >&2; fail=1; }
# ABOVE the per-board rows, in its own element, from --overview's own field and
# never from a second subprocess: bin/dashboard.py derives nothing.
grep -q 'id="halt"' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py has no element for the machine halt" >&2; fail=1; }
grep -q 'machine_halt' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py does not read machine_halt" >&2; fail=1; }
grep -q 'supervise.sh --resume' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py does not say how to clear the halt" >&2; fail=1; }
grep -q 'no reason recorded' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py calls an empty marker unreadable" >&2; fail=1; }
python3 -c '
import sys
page = open(sys.argv[1]).read()
assert page.index("id=\"halt\"") < page.index("<h2>Now</h2>"), \
    "the halt banner renders below the per-board rows"
' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL the halt banner is not above the board rows" >&2; fail=1; }
python3 -c "import ast; ast.parse(open('$repo_root/bin/dashboard.py').read())" \
  || { echo "FAIL dashboard.py does not parse" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --overview carries monitor state and the machine halt, and the page renders both"
exit "$fail"
