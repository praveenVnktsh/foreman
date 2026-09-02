#!/usr/bin/env bash
# Claim: preflight refuses a machine with too little memory available, and stays
# quiet where memory is not measurable.
#
# Memory is the resource that actually took a machine down. On 2026-08-31 a
# self-hosted CI runner was OOM-killed at a 5.2GB peak; on 2026-09-01 four build
# agents plus that runner drove the same 14GB box to a load average of 14 with
# ssh timing out. preflight probed disk in two places and never once looked at
# memory, so it reported that machine fit throughout.
#
# The agents were never the cost -- a claude process measures about 0.3GB. What
# peaks is the target's own test suite, run concurrently by every build agent.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# The function is exercised directly. Standing up a whole instance fixture to
# reach it would test the fixture; what matters here is the arithmetic and the
# two ways it must not fire.
run_check() {
  local meminfo="$1" floor="$2"
  python3 - "$meminfo" "$floor" <<PY
import importlib.util, sys, builtins
spec = importlib.util.spec_from_file_location("pf", "$root/skills/board/preflight.py")
pf = importlib.util.module_from_spec(spec); spec.loader.exec_module(pf)
real_open = builtins.open
path = sys.argv[1]
def fake_open(f, *a, **k):
    if f == "/proc/meminfo":
        if path == "ABSENT":
            raise OSError("no such file")
        return real_open(path, *a, **k)
    return real_open(f, *a, **k)
builtins.open = fake_open
c = pf.memory_check(int(sys.argv[2]))
print(c["ok"], "|", c["detail"])
PY
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf 'MemTotal:       14000000 kB\nMemAvailable:     512000 kB\n' > "$work/low"
printf 'MemTotal:       14000000 kB\nMemAvailable:    9000000 kB\n' > "$work/plenty"
printf 'MemTotal:       14000000 kB\nMemFree:          100000 kB\n' > "$work/no-available"

r="$(run_check "$work/low" 1024)"
case "$r" in
  False*OOM*) ok "too little memory is unfit, and it says why" ;;
  *) bad "low memory -> $r" ;;
esac

r="$(run_check "$work/plenty" 1024)"
case "$r" in True*) ok "plenty of memory passes" ;; *) bad "plenty -> $r" ;; esac

# MemAvailable, not MemFree. On a host with 99 days of uptime MemFree reads as
# almost nothing because the page cache holds it, and a gate keyed on MemFree
# would refuse every dispatch on every long-lived machine.
r="$(run_check "$work/no-available" 1024)"
case "$r" in True*) ok "a meminfo without MemAvailable does not invent a failure" ;; *) bad "no MemAvailable -> $r" ;; esac

r="$(run_check ABSENT 1024)"
case "$r" in
  True*"not measurable"*) ok "where memory is not measurable the check stays quiet" ;;
  *) bad "absent /proc/meminfo -> $r" ;;
esac

exit "$fail"
