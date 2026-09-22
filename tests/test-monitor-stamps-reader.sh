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

# A stamp older than MONITOR_STALE_SECONDS is stale. 61s beats the default 60.
# Set mtime via python3, not `touch -t`: BSD touch reads -t as local time while
# GNU touch does not, so a UTC-computed timestamp lands 7h off on this machine's
# zone and the age check below would compare against the wrong instant.
python3 -c 'import os,sys,time; t=time.time()-61; os.utime(sys.argv[1], (t, t))' "$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "True" ]] || { echo "FAIL 61s-old stamp read as fresh" >&2; fail=1; }

# The window follows the poll. At WATCH_POLL_SECONDS=60 the window is 240s, so
# the same 61s-old stamp is fresh.
out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
        WATCH_POLL_SECONDS=60 "$board_dir/reconcile.py" --monitor-stamps)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] \
  || { echo "FAIL MONITOR_STALE_SECONDS does not follow WATCH_POLL_SECONDS" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --monitor-stamps classifies missing, fresh and stale"
exit "$fail"
