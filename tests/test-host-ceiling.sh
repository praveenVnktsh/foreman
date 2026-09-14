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
# can have -- the same class of failure as the `/tmp` quota that cost one card
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
# config through it for any board but this one -- it reads the board roster
# from boards.toml (via bin/boards.py --list) and each board's runtime
# directory directly on disk, which is the whole point: it must work for
# boards this process has no config for at all.

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

# write_boards_toml <home> <repo> <board-name>...
# The roster --host-slots now reads: a board only counts if it is declared
# here. One shared repo dir is fine for every name -- boards.py only checks
# that it exists, and nothing in this suite reads board.toml through it.
write_boards_toml() {
  local home="$1" repo="$2"; shift 2
  local out="$home/.foreman/boards.toml"
  mkdir -p "$(dirname -- "$out")"
  : > "$out"
  local name
  for name in "$@"; do
    { printf '[boards.%s]\n' "$name"; printf 'repo = "%s"\n' "$repo"; } >> "$out"
  done
}

expect() {
  local want="$1" got="$2" what="$3"
  [[ "$got" == "$want" ]] || fail "$what: expected [$want], got [$got]"
}

# Timestamped at RUN time, not a hardcoded date -- a hardcoded past date is
# exactly what HOST_SLOT_STALE_MINUTES's backstop (added in review round 1)
# now treats as a leaked slot to reclaim, which made a fixed "2026-08-27"
# literal silently go stale and fail this very suite the day after it was
# written. These cases are about the `released` MARKER, not about staleness
# -- see the dedicated backstop case further down -- so every timestamp here
# must stay fresh no matter when the suite runs.
SPAWN="{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":{\"action\":\"spawn\",\"role\":\"build\",\"attempt\":\"1\"}}"
RELEASED="{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":{\"action\":\"released\",\"reason\":\"merged\"}}"

# alpha: one card still in flight.
write_history alpha PRA-1 "$SPAWN"
# beta: a DIFFERENT instance entirely, with its own in-flight card. If
# --host-slots only read the CURRENT instance's cards (the bug this exists to
# catch), beta's card would never be counted.
write_history beta PRA-9 "$SPAWN"
# delta: one card that was dispatched and has since released its slot.
# Isolated in its own instance so its zero cannot be explained by anything but
# the trailing `released` entry.
write_history delta PRA-2 "$SPAWN" "$RELEASED"
# gamma: an instance directory that exists but has never dispatched anything,
# so it has no cards/ subdirectory at all.
mkdir -p "$slots_home/.foreman/instances/gamma"
# epsilon: a ticket directory that exists (e.g. created for some other reason)
# but was never actually logged to -- no history.jsonl at all.
mkdir -p "$slots_home/.foreman/instances/epsilon/cards/PRA-NOHIST"
# zeta: a history.jsonl whose LAST line is corrupt -- not valid JSON at all.
# `_read_jsonl` must skip it rather than raise, falling back to the last line
# that DID parse (a spawn, so this still counts).
zeta_dir="$slots_home/.foreman/instances/zeta/cards/PRA-BAD"
mkdir -p "$zeta_dir"
printf '%s\n{not json at all\n' "$SPAWN" > "$zeta_dir/history.jsonl"
# theta: a leftover RUNTIME directory for a board that is not in boards.toml
# -- either removed after being declared, or never declared at all -- with
# one card still in flight. Must not count: a board's declaration, not the
# directory a past tick left behind, is what makes it part of the machine
# ceiling now.
write_history theta PRA-77 "$SPAWN"

write_boards_toml "$slots_home" "$slots_target" \
  alpha beta current delta epsilon gamma zeta

# FOREMAN_HOME is named explicitly. config.sh no longer derives it from $HOME:
# it asks bin/installation.py, which reads the home as the parent of this
# clone. An explicit home is what that derivation yields to, and it is how this
# file stays pointed at its temporary directory.
host_json="$(HOME="$slots_home" FOREMAN_HOME="$slots_home/.foreman" \
  FOREMAN_INSTANCE=current "$reconcile" --host-slots)"

# `--host-slots` keys every board as `<installation>/<board>`, because two
# installations on one machine may serve one repository and would otherwise
# share a board name. This home declares no installation.toml, so
# bin/installation.py reads it as the lone Claude installation and every key
# below is `claude/<board>`.
expect "1" "$(verdict_field "$host_json" 'v["instances"]["claude/alpha"]')" \
  "alpha's in-flight card is counted"
expect "1" "$(verdict_field "$host_json" 'v["instances"]["claude/beta"]')" \
  "beta's card is counted even though beta is not the current instance"
expect "7" "$(verdict_field "$host_json" 'len(v["instances"])')" \
  "every instance directory appears in the report, including empty ones"
echo "ok  --host-slots counts cards across every instance, not just this one"

expect "0" "$(verdict_field "$host_json" 'v["instances"]["claude/delta"]')" \
  "a card whose history's last line is a released event must not count"
echo "ok  --host-slots ignores a card whose history says it finished"

expect "0" "$(verdict_field "$host_json" 'v["instances"]["claude/gamma"]')" \
  "an instance with no cards/ at all must read as zero, not raise"
expect "3" "$(verdict_field "$host_json" 'v["total"]')" \
  "the total is alpha (1) + beta (1) + delta (0) + gamma (0) + current (0) + epsilon (0) + zeta (1)"
echo "ok  --host-slots survives an instance directory with no cards/ at all"

expect "0" "$(verdict_field "$host_json" 'v["instances"]["claude/epsilon"]')" \
  "a card directory with no history.jsonl at all must not count, and must not raise"
echo "ok  --host-slots survives a card directory with no history.jsonl"

expect "1" "$(verdict_field "$host_json" 'v["instances"]["claude/zeta"]')" \
  "a corrupt trailing line must not crash the read -- it falls back to the last line that DID parse"
echo "ok  --host-slots survives a malformed trailing line in history.jsonl"

expect "False" "$(verdict_field "$host_json" '"claude/theta" in v["instances"]')" \
  "an undeclared board's leftover runtime directory must not even appear in the report"
expect "3" "$(verdict_field "$host_json" 'v["total"]')" \
  "theta's in-flight card must not raise the total above alpha (1) + beta (1) + zeta (1) -- a board removed from boards.toml must not silently pin the machine ceiling forever"
echo "ok  --host-slots does not count a leftover runtime directory for an undeclared board"

# ============================================================================
# Regression coverage added in review round 1: the CRITICAL finding
# ============================================================================
#
# card_holds_slot() originally counted a card unless its history's last line
# said `{"action":"finished",...}` -- and NOTHING in the codebase ever wrote
# that action except the `Done` path. Both `board-failed` exits (attempts
# exhausted, review rounds exhausted) left a card counting FOREVER, because
# sweep.sh deliberately never deletes history.jsonl. Four cumulative
# board-failed cards -- ever, not concurrently -- pins HOST_MAX_CONCURRENT's
# default of 4 and wedges dispatch across EVERY instance on the machine,
# unrecoverable without hand-editing history.jsonl. The fix is two mechanisms,
# and this section proves both independently:
#
#   1. THE MARKER, renamed `released` and now written at both `board-failed`
#      exits too (SKILL.md steps 2 and 3), not just `Done`.
#   2. THE BACKSTOP, `HOST_SLOT_STALE_MINUTES`: a card whose last entry is
#      older than the bound stops counting even with no marker at all -- so a
#      THIRD terminal exit someone adds later and forgets to wire self-heals
#      instead of wedging forever.

wedge_home="$work_dir/wedge-home"
wedge_target="$work_dir/wedge-target"
mkdir -p "$wedge_target"
git_q init -q -b main "$wedge_target"
fixture_board_toml "$wedge_target"
git_q -C "$wedge_target" add board.toml
git_q -C "$wedge_target" commit -q -m "Seed"
fixture_add_instance "$wedge_home" current "$wedge_target"

write_wedge_history() { # instance ticket line...
  local inst="$1" ticket="$2"; shift 2
  local dir="$wedge_home/.foreman/instances/$inst/cards/$ticket"
  mkdir -p "$dir"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/history.jsonl"; done
}

# --- the exact scenario the reviewer reproduced: 4 cumulative failed cards --

# "lambda": four cards, each with only a fresh, unreleased spawn -- exactly
# what a board-failed card looked like before this fix, and exactly
# HOST_MAX_CONCURRENT's shipped default. If this reads as 4, dispatch is
# wedged on this machine from this moment forward.
for n in 1 2 3 4; do
  write_wedge_history lambda "PRA-L$n" "$SPAWN"
done
# "kappa": the same four cards, but with `released` appended -- the fix,
# applied. This is what SKILL.md now does at both board-failed exits.
for n in 1 2 3 4; do
  write_wedge_history kappa "PRA-K$n" "$SPAWN" "$RELEASED"
done

# mu and nu (written below, for the backstop case) share this boards.toml, so
# they are declared here too -- boards.toml does not change between the two
# --host-slots calls in this section, only the cards on disk do.
write_boards_toml "$wedge_home" "$wedge_target" current lambda kappa mu nu

wedge_json="$(HOME="$wedge_home" FOREMAN_HOME="$wedge_home/.foreman" \
  FOREMAN_INSTANCE=current "$reconcile" --host-slots)"

expect "4" "$(verdict_field "$wedge_json" 'v["instances"]["claude/lambda"]')" \
  "four unreleased cards read as 4 -- confirmed AT the shipped HOST_MAX_CONCURRENT default, this is a real deadlock shape, not a hypothetical one"
expect "0" "$(verdict_field "$wedge_json" 'v["instances"]["claude/kappa"]')" \
  "the same four cards, released at both board-failed exits (as SKILL.md now instructs), do not accumulate -- dispatch is never wedged by them"
echo "ok  cumulative board-failed cards release their slots once released (no permanent deadlock)"

# --- the backstop: a stale, unreleased card self-heals with no marker at all

past='2000-01-01T00:00:00Z'                      # always older than any bound below
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"              # always fresher than any bound below
STALE_SPAWN="{\"at\":\"$past\",\"event\":{\"action\":\"spawn\",\"role\":\"build\",\"attempt\":\"1\"}}"
FRESH_SPAWN="{\"at\":\"$now\",\"event\":{\"action\":\"spawn\",\"role\":\"build\",\"attempt\":\"1\"}}"
# "mu": a card dispatched in the year 2000 and never released -- imagine a
# terminal exit that forgot to write the marker at all.
write_wedge_history mu PRA-M1 "$STALE_SPAWN"
# "nu": a card dispatched moments ago, also unreleased -- real, active work
# that the backstop must NOT mistake for a leak.
write_wedge_history nu PRA-N1 "$FRESH_SPAWN"

# A 5-minute bound: `$past` is a quarter century old and `$now` is seconds
# old, so which side of 5 minutes each falls on cannot be timing-flaky.
backstop_json="$(HOME="$wedge_home" FOREMAN_HOME="$wedge_home/.foreman" \
  FOREMAN_INSTANCE=current HOST_SLOT_STALE_MINUTES=5 "$reconcile" --host-slots)"

expect "0" "$(verdict_field "$backstop_json" 'v["instances"]["claude/mu"]')" \
  "a card with no released marker but a 26-year-old last entry must stop counting -- this is the self-heal for a marker nobody wrote"
expect "1" "$(verdict_field "$backstop_json" 'v["instances"]["claude/nu"]')" \
  "a card with no released marker but a SECONDS-old last entry must still count -- the backstop must not mistake live work for a leak"
echo "ok  a stale, unreleased card self-heals past HOST_SLOT_STALE_MINUTES (backstop)"

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
# config.sh now resolves REPO from boards.toml (bin/boards.py), not from
# instance.env -- fixture_add_instance still stands up the runtime directory,
# but this is what makes FOREMAN_INSTANCE=fixture resolve at all.
write_boards_toml "$lock_home" "$lock_target" fixture

lockfile="$lock_home/.foreman/preflight.lock"

run_preflight_quick() { # NAME=VALUE overrides, e.g. QUICK_PROBE_MB=1
  env HOME="$lock_home" FOREMAN_HOME="$lock_home/.foreman" FOREMAN_INSTANCE=fixture \
    MIN_FREE_TMP_MB=1 MIN_FREE_REPO_MB=1 \
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

# 30s, not 5. The property under test is that the lock is released at all --
# a lock that survives a kill wedges every future dispatch on this machine,
# which is worse than the race it prevents. It is NOT a performance assertion.
#
# `kill -9` reaps the wrapper, not the 512MB write probe it spawned, and that
# child holds the lock until its write finishes. Five seconds was calibrated on
# a developer's SSD and failed on a loaded CI runner against the same code that
# had passed minutes earlier. A flaky test in a repository whose whole premise
# is unattended merging is not a nuisance: it fails real builds at random and
# costs a card an attempt for nothing.
wait_lock_state "$lockfile" free 30 ||
  fail "the probe lock was NOT released within 30s of SIGKILL -- a lock that survives a kill wedges every future dispatch on this machine, which is worse than the race it prevents"
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
