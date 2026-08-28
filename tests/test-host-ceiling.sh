#!/usr/bin/env bash
# The machine has a ceiling too, not just each instance -- and the probe that
# proves an instance can build must not lie to a second instance measuring the
# same moment.
#
# `reconcile.py --host-slots` answers the first half: how many cards, across
# every instance under `~/.foreman/instances/*/cards/`, currently hold a build
# slot. It is deliberately a LOCAL read -- no Linear, no `gh`, no `claude
# agents` -- because the host ceiling has to be cheap enough to check before
# every dispatch, for every instance sharing the machine.
#
# `preflight.py`'s probe lock answers the second half. The write-and-release
# check proves "there is room" by actually using it and giving it back, which
# means it is a POINT-IN-TIME measurement, not a reservation. Two instances
# probing at the same point in time both observe room that only one of them
# can have -- the same class of failure as the `/tmp` quota that cost PRA-28
# two build attempts on 2026-08-02, scaled by the number of instances. Cases 4
# and 5 below are why the lock exists at all; case 5 in particular, because a
# lock that survives a SIGKILL wedges every future dispatch on the machine,
# which is worse than the race it prevents.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
reconcile="$repo_root/skills/board/reconcile.py"
preflight="$repo_root/skills/board/preflight.py"
withlock="$repo_root/skills/board/withlock.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$reconcile" ]] || { echo "FAIL: $reconcile is missing or not executable" >&2; exit 1; }
[[ -x "$preflight" ]] || { echo "FAIL: $preflight is missing or not executable" >&2; exit 1; }
[[ -x "$withlock" ]]  || { echo "FAIL: $withlock is missing or not executable" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Real disk, not the OS's own /tmp -- which is a tmpfs on some hosts and would
# make the write-and-release probe measure RAM speed instead of the disk a
# real build actually uses. Same derivation
# tests/test-preflight-fetches-only-to-gate.sh uses.
tmp_root="$("$repo_root/bin/tmp-dir.sh")"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

git_q() {
  git -c user.name="Host Ceiling Test" -c user.email="host-ceiling-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

verdict_field() {
  local json="$1" expr="$2"
  printf '%s' "$json" | /usr/bin/env python3 -c '
import json
import sys

verdict = json.load(sys.stdin)
checks = {c["name"]: c for c in verdict.get("checks", [])}
print(eval(sys.argv[1], {"v": verdict, "c": checks}))
' "$expr"
}

# wait_lock_state <lockfile> locked|free <budget-seconds>
#
# Polls a NON-BLOCKING trylock of its own, every 5ms, until `lockfile` is
# observed in the wanted state or the budget runs out. This is what makes
# cases 4 and 5 deterministic rather than timing guesses: the caller does not
# have to know how long a probe takes on whatever disk this runs against, only
# that it takes SOME nonzero time, which a write-then-fsync of a real file
# always does off a tmpfs.
wait_lock_state() {
  python3 - "$1" "$2" "$3" <<'PY'
import fcntl
import os
import sys
import time

lockfile, want, budget = sys.argv[1], sys.argv[2], float(sys.argv[3])
deadline = time.monotonic() + budget
while True:
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        locked = False
    except OSError:
        locked = True
    finally:
        os.close(fd)
    if locked == (want == "locked"):
        sys.exit(0)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.005)
PY
}

monotonic() { python3 -c 'import time; print(time.monotonic())'; }

# ============================================================================
# Cases 1-3: reconcile.py --host-slots
# ============================================================================
#
# One "current" instance is enough to make config.sh (and therefore
# reconcile.py's module-level load) happy; --host-slots itself never reads
# config through it for any instance but this one -- it walks
# FOREMAN_HOME/instances/*/cards/ directly on disk, which is the whole point:
# it must work for instances this process has no config for at all.

slots_home="$work_dir/slots-home"
slots_target="$work_dir/slots-target"
mkdir -p "$slots_target"
git_q init -q -b main "$slots_target"
fixture_board_toml "$slots_target"
git_q -C "$slots_target" add board.toml
git_q -C "$slots_target" commit -q -m "Seed"
fixture_add_instance "$slots_home" current "$slots_target"

write_history() { # instance ticket line...
  local inst="$1" ticket="$2"; shift 2
  local dir="$slots_home/.foreman/instances/$inst/cards/$ticket"
  mkdir -p "$dir"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/history.jsonl"; done
}

SPAWN='{"at":"2026-08-27T00:00:00Z","event":{"action":"spawn","role":"build","attempt":"1"}}'
FINISHED='{"at":"2026-08-27T00:05:00Z","event":{"action":"finished","reason":"merged"}}'

# alpha: one card still in flight.
write_history alpha PRA-1 "$SPAWN"
# beta: a DIFFERENT instance entirely, with its own in-flight card. If
# --host-slots only read the CURRENT instance's cards (the bug this exists to
# catch), beta's card would never be counted.
write_history beta PRA-9 "$SPAWN"
# delta: one card that was dispatched and has since finished. Isolated in its
# own instance so its zero cannot be explained by anything but the trailing
# `finished` entry.
write_history delta PRA-2 "$SPAWN" "$FINISHED"
# gamma: an instance directory that exists but has never dispatched anything,
# so it has no cards/ subdirectory at all.
mkdir -p "$slots_home/.foreman/instances/gamma"

host_json="$(HOME="$slots_home" FOREMAN_INSTANCE=current "$reconcile" --host-slots)"

expect() {
  local want="$1" got="$2" what="$3"
  [[ "$got" == "$want" ]] || fail "$what: expected [$want], got [$got]"
}

expect "1" "$(verdict_field "$host_json" 'v["instances"]["alpha"]')" \
  "alpha's in-flight card is counted"
expect "1" "$(verdict_field "$host_json" 'v["instances"]["beta"]')" \
  "beta's card is counted even though beta is not the current instance"
expect "5" "$(verdict_field "$host_json" 'len(v["instances"])')" \
  "every instance directory appears in the report, including empty ones"
echo "ok  --host-slots counts cards across every instance, not just this one"

expect "0" "$(verdict_field "$host_json" 'v["instances"]["delta"]')" \
  "a card whose history's last line is a finished event must not count"
echo "ok  --host-slots ignores a card whose history says it finished"

expect "0" "$(verdict_field "$host_json" 'v["instances"]["gamma"]')" \
  "an instance with no cards/ at all must read as zero, not raise"
expect "2" "$(verdict_field "$host_json" 'v["total"]')" \
  "the total is alpha (1) + beta (1) + delta (0) + gamma (0) + current (0)"
echo "ok  --host-slots survives an instance directory with no cards/ at all"

# ============================================================================
# Cases 4-6: preflight.py's probe lock
# ============================================================================

lock_home="$work_dir/lock-home"
lock_target="$work_dir/lock-target"
mkdir -p "$lock_target"
git_q init -q -b main "$lock_target"
# A deliberately distinctive QUICK_PROBE_MB -- neither the OLD hardcoded
# config.sh default (16) nor the NEW contract default (4) -- so a check
# reporting exactly this number can only have come from THIS board.toml.
cat > "$lock_target/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "fixture"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
[limits]
quick_probe_mb = 3
TOML
git_q -C "$lock_target" add board.toml
git_q -C "$lock_target" commit -q -m "Seed"
fixture_add_instance "$lock_home" fixture "$lock_target"

lockfile="$lock_home/.foreman/preflight.lock"

run_preflight_quick() { # NAME=VALUE overrides, e.g. QUICK_PROBE_MB=1
  env HOME="$lock_home" FOREMAN_INSTANCE=fixture MIN_FREE_TMP_MB=1 MIN_FREE_REPO_MB=1 \
    TMPDIR="$tmp_root" "$@" "$preflight" --quick
}

# --- 4. a second preflight blocks while the first holds the probe lock ------
#
# The lock is taken externally, with withlock.py itself -- the exact primitive
# preflight.py calls in-process -- so this proves preflight actually WAITS on
# the same lock file, not merely that withlock.py can serialize two of its own
# invocations.

"$withlock" "$lockfile" 30 -- sleep 3 &
holder_pid=$!
wait_lock_state "$lockfile" locked 10 ||
  { kill "$holder_pid" 2>/dev/null || true
    fail "never observed the external holder take the probe lock"; }

start="$(monotonic)"
blocked_json="$(run_preflight_quick QUICK_PROBE_MB=1)" || {
  wait "$holder_pid" 2>/dev/null || true
  fail "preflight failed while it should merely have waited for the held probe lock"
}
end="$(monotonic)"
wait "$holder_pid" 2>/dev/null || true

elapsed="$(python3 -c "print($end - $start)")"
python3 -c "import sys; sys.exit(0 if $elapsed >= 2.5 else 1)" ||
  fail "a second preflight did not block on the held probe lock (waited only ${elapsed}s, expected >= 2.5s -- the holder released after 3s)"
expect "True" "$(verdict_field "$blocked_json" 'v["fit"]')" \
  "preflight succeeds once the held lock is released, having merely waited for it"
echo "ok  a second preflight blocks while the first holds the probe lock"

# --- 5. the probe lock is released when preflight is killed mid-probe -------
#
# A large probe so there is a real, measurable window between "lock acquired"
# and "probe complete" on a real (non-tmpfs) disk -- see wait_lock_state's
# docstring for why the exact duration does not have to be guessed.

run_preflight_quick QUICK_PROBE_MB=512 >/dev/null 2>&1 &
pid=$!
if ! wait_lock_state "$lockfile" locked 15; then
  kill -9 "$pid" 2>/dev/null || true
  fail "never observed preflight's own probe hold the lock -- cannot prove anything about a mid-probe SIGKILL"
fi
kill -9 "$pid"
wait "$pid" 2>/dev/null || true

wait_lock_state "$lockfile" free 5 ||
  fail "the probe lock was NOT released within 5s of SIGKILL -- a lock that survives a kill wedges every future dispatch on this machine, which is worse than the race it prevents"
echo "ok  the probe lock is released when preflight is killed mid-probe (SIGKILL)"

# --- 6. probe sizes come from the contract, not from a constant -------------
#
# No QUICK_PROBE_MB override here at all: the only source left is
# board.toml's [limits] quick_probe_mb = 3, read through bin/contract.py and
# config.sh. A hardcoded constant (the old config.sh default was 16; the new
# contract default is 4) would report either of THOSE numbers instead.

contract_json="$(run_preflight_quick)" ||
  fail "preflight --quick failed unexpectedly while reading the contract-sourced probe size"
probe_name="$(verdict_field "$contract_json" 'next(iter(c))')"
case "$probe_name" in
  "write 3MB to"*) : ;;
  *) fail "expected the quick probe to report quick_probe_mb=3 from board.toml, got: $probe_name" ;;
esac
echo "ok  probe sizes come from the contract, not from a constant"

echo "PASS: the host ceiling counts across instances, and the probe lock does not race"
