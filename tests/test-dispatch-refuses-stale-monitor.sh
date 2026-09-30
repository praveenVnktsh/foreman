#!/usr/bin/env bash
# dispatch.sh must refuse while any board's Monitor is not alive. Machine-wide,
# because a rejected Monitor call is evidence about the harness contract and
# every board on the machine shares one harness.
#
# The gate belongs here rather than only in SKILL.md so that it holds however
# the script is called -- by the tick, by a resume, or by hand. That is the same
# reason the preflight and slot gates live here.
#
# preflight.py's own gate (the one above this one in dispatch.sh) needs a real
# `origin` it can fetch, so the fixture below is a real git repository with a
# bare remote -- not just a directory holding board.toml -- the same shape
# test-dispatch-holds-the-cap.sh uses to reach the gates past preflight.
# `claude` and `gh` are stubbed on PATH, and BOARD_DRY_RUN=1 stops a passing
# run short of actually spawning an agent, the way that test does too.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

home="$work_dir/home"
target="$work_dir/target"
origin="$work_dir/origin"
mkdir -p "$target"
git init -q --bare "$origin"
git init -q -b main "$target"
fixture_board_toml "$target"
echo seed >"$target/seed.txt"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$target" remote add origin "$origin"
git -C "$target" push -q origin main
fixture_add_board "$home" demo "$target"

stub="$work_dir/bin"
mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/claude"; chmod +x "$stub/claude"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/gh"; chmod +x "$stub/gh"

prompt="$work_dir/prompt.txt"
echo "build the card" >"$prompt"
stamp="$home/.foreman/instances/demo/monitor.stamp"
fail=0

attempt() {
  HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$stub:$PATH" BOARD_DRY_RUN=1 \
    "$board_dir/dispatch.sh" --ticket DEMO-1 --role build --attempt 1 \
    --prompt-file "$prompt" 2>&1
}

# EVERY ASSERTION NAMES THE MONITOR GATE'S OWN MESSAGE, and that is the whole
# difference between this test and one that cannot fail. "refusing to dispatch"
# and "must not consume its attempt budget" are shared wording: the preflight
# `die` immediately above this gate in dispatch.sh prints both. A test built on
# them passed with the monitor gate deleted outright, which is the one outcome
# it exists to catch. `MONITOR_GATE` below is that gate's first line and nothing
# else in dispatch.sh says it.
MONITOR_GATE="no board on this machine has a live agent Monitor"

# No stamp at all: refuse, and say so in the same voice as the other gates.
if out="$(attempt)"; then
  echo "FAIL dispatched with no monitor stamp" >&2; fail=1
else
  printf '%s' "$out" | grep -q "$MONITOR_GATE" \
    || { echo "FAIL the refusal is not the monitor gate's: $out" >&2; fail=1; }
  printf '%s' "$out" | grep -q "Stale or missing: demo" \
    || { echo "FAIL the monitor gate does not name the board: $out" >&2; fail=1; }
  printf '%s' "$out" | grep -q "must not consume its attempt budget" \
    || { echo "FAIL refusal charges the ticket an attempt: $out" >&2; fail=1; }
fi

# A stale stamp: refuse, and for the monitor gate's reason rather than any
# other gate's.
# BSD `touch -t` reads its argument as LOCAL time and GNU touch does not, so a
# UTC-computed stamp lands hours off. os.utime takes an epoch and is portable.
mkdir -p "$(dirname "$stamp")"
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
python3 -c 'import os,sys,time; t=time.time()-300; os.utime(sys.argv[1], (t, t))' "$stamp"
if out="$(attempt)"; then
  echo "FAIL dispatched with a stale monitor stamp" >&2; fail=1
else
  printf '%s' "$out" | grep -q "$MONITOR_GATE" \
    || { echo "FAIL a stale stamp was refused by some other gate: $out" >&2; fail=1; }
  printf '%s' "$out" | grep -q "Stale or missing: demo" \
    || { echo "FAIL the monitor gate does not name the stale board: $out" >&2; fail=1; }
fi

# A fresh stamp: the monitor gate must not be what stops it. Any later gate may
# still refuse in this fixture, so assert on the message rather than the exit.
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
out="$(attempt || true)"
printf '%s' "$out" | grep -q "$MONITOR_GATE" \
  && { echo "FAIL monitor gate refused a fresh stamp: $out" >&2; fail=1; }

# A HALTED BOARD MUST NOT STOP A HEALTHY ONE. The gate is machine-wide, and a
# halted board arms no Monitor by design -- SKILL.md says to arm one for every
# board that is NOT halted. Counting its stale stamp made `boardctl halt` refuse
# every dispatch on every other board and then halt foreman itself.
fixture_add_board "$home" quiet "$target"
touch "$home/.foreman/instances/quiet/HALT"
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
out="$(attempt || true)"
printf '%s' "$out" | grep -q "$MONITOR_GATE" \
  && { echo "FAIL a halted board stopped dispatch on a healthy one: $out" >&2; fail=1; }

# And the exclusion is the HALT file, not the board dropping out of the roster:
# resume it and its missing stamp refuses again.
rm -f "$home/.foreman/instances/quiet/HALT"
out="$(attempt || true)"
printf '%s' "$out" | grep -q "Stale or missing: quiet" \
  || { echo "FAIL a resumed board with no stamp did not refuse: $out" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   dispatch.sh refuses while a Monitor is not alive"
exit "$fail"
