#!/usr/bin/env bash
# reconcile.py --monitor-stamps is the single derivation of "is this board's
# Monitor alive". dispatch.sh, supervise.sh and bin/dashboard.py all read it,
# so the staleness rule is spelled once. MONITOR_STALE_SECONDS is DERIVED from
# WATCH_POLL_SECONDS, for the reason DEMAND_STALE_MINUTES derives from
# TICK_INTERVAL_MINUTES: an operator who slows the poll widens the window with
# it, instead of silently breaking every gate.
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

run() { HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
          "$board_dir/reconcile.py" --monitor-stamps; }

field() { python3 -c 'import json,sys; print(json.load(sys.stdin)["boards"]["demo"][sys.argv[1]])' "$1"; }

stamp="$py_home/.foreman/instances/demo/monitor.stamp"
fail=0

# A board with no stamp at all is stale, not absent from the report. A missing
# stamp is the fault this exists to catch, so it must never read as "no answer".
out="$(run)"
[[ "$(printf '%s' "$out" | field present)" == "False" ]] || { echo "FAIL missing stamp not reported" >&2; fail=1; }
[[ "$(printf '%s' "$out" | field stale)" == "True" ]] || { echo "FAIL missing stamp not stale" >&2; fail=1; }
[[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')" == "False" ]] \
  || { echo "FAIL ok true with a missing stamp" >&2; fail=1; }

# A stamp written now is fresh.
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] || { echo "FAIL fresh stamp read as stale" >&2; fail=1; }

# A stamp older than MONITOR_STALE_SECONDS is stale. 76s beats the default 75,
# which is the floor of one poll plus 60: four polls is 60s at the default poll
# of 15, and four polls is narrower than the worst-case gap of one poll plus the
# 30s registry-read timeout whenever the poll is 10s or less.
# Set mtime via python3, not `touch -t`: BSD touch reads -t as local time while
# GNU touch does not, so a UTC-computed timestamp lands 7h off on this machine's
# zone and the age check below would compare against the wrong instant.
python3 -c 'import os,sys,time; t=time.time()-76; os.utime(sys.argv[1], (t, t))' "$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "True" ]] || { echo "FAIL 76s-old stamp read as fresh" >&2; fail=1; }

# The window follows the poll. At WATCH_POLL_SECONDS=60 the window is 240s, so
# the same 76s-old stamp is fresh.
out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
        WATCH_POLL_SECONDS=60 "$board_dir/reconcile.py" --monitor-stamps)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] \
  || { echo "FAIL MONITOR_STALE_SECONDS does not follow WATCH_POLL_SECONDS" >&2; fail=1; }

# THE POLL THE STAMP RECORDS WINS OVER THE READER'S OWN. watch-agents.py reads
# WATCH_POLL_SECONDS from the tick session's environment; this reader derives
# its window from whatever environment IT has, which for supervise.sh is cron's
# -- no profile, no exports. Nothing else carries the value between the two, so
# an operator who exported it got a watcher stamping every 60s and a reader
# demanding one every 60s, which halts a healthy machine permanently. A stamp
# that records poll=60 is judged at 240s even when the reader's own poll is 15.
printf '%s\npoll=60\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$stamp"
python3 -c 'import os,sys,time; t=time.time()-76; os.utime(sys.argv[1], (t, t))' "$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] \
  || { echo "FAIL the stamp's own poll did not widen the window" >&2; fail=1; }

# A HALTED BOARD IS REPORTED AND NEVER COUNTED. SKILL.md tells the tick to arm
# one Monitor for every board that is NOT halted, so a halted board's stamp goes
# stale within minutes of `boardctl halt` by design. Counting it made `ok`
# false, and `ok` is machine-wide -- halting one board refused every dispatch on
# every other board and then halted foreman itself.
fixture_add_board "$py_home" quiet "$fixture_repo"
touch "$py_home/.foreman/instances/quiet/HALT"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$stamp"
out="$(run)"
verdict() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
[[ "$(printf '%s' "$out" | verdict ok)" == "True" ]] \
  || { echo "FAIL a halted board with no stamp made ok false: $out" >&2; fail=1; }
[[ "$(printf '%s' "$out" | verdict halt_ok)" == "True" ]] \
  || { echo "FAIL a halted board with no stamp made halt_ok false: $out" >&2; fail=1; }
[[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boards"]["quiet"]["halted"])')" == "True" ]] \
  || { echo "FAIL a halted board is not reported at all: $out" >&2; fail=1; }

# And resuming it puts it back in the verdict, so the exclusion is the HALT file
# and not the board quietly dropping out of the roster.
rm -f "$py_home/.foreman/instances/quiet/HALT"
out="$(run)"
[[ "$(printf '%s' "$out" | verdict ok)" == "False" ]] \
  || { echo "FAIL a resumed board with no stamp still reads ok: $out" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --monitor-stamps classifies missing, fresh and stale"
exit "$fail"
