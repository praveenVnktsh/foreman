#!/usr/bin/env bash
# SKILL.md's Monitor call must name timeout_ms. sdk-tools.d.ts declares it
# required on Claude Code 2.1.228 and on 2.1.275, and the call shipped without
# it. It must also carry the version note: 2.1.228 requires `persistent` and
# 2.1.275 removed it, so no single call works on both and a tick that arms
# nothing leaves the board running at heartbeat speed with nothing saying so.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo_root/skills/board/SKILL.md"
watcher="$repo_root/skills/board/watch-agents.py"
fail=0

check() { # <file> <pattern> <why>
  if grep -q "$2" "$1"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s does not match %s\n' "$3" "$1" "$2" >&2
    fail=1
  fi
}

check "$skill" 'timeout_ms' "SKILL.md's Monitor call names timeout_ms"
check "$watcher" 'timeout_ms' "watch-agents.py's docstring names timeout_ms"
check "$skill" '2\.1\.275' "SKILL.md names the version that removed persistent"

# THE TWO NUMBERS THAT MUST AGREE. config.sh derives MONITOR_HALT_SECONDS from
# MONITOR_TIMEOUT_SECONDS -- how long the Monitor SKILL.md arms actually lives
# -- so a timeout_ms that drifts from it makes the supervisor's halt window
# arithmetic describe a Monitor nobody arms. The failure is silent in the
# direction that matters: a longer timeout_ms than config.sh believes leaves the
# window too wide and the gate stops catching a dead edge-trigger.
skill_ms="$(grep -o 'timeout_ms=[0-9]*' "$skill" | head -1 | cut -d= -f2)"
config_s="$(grep -o 'MONITOR_TIMEOUT_SECONDS:-[0-9]*' "$repo_root/skills/board/config.sh" \
            | head -1 | cut -d- -f2)"
if [[ -n "$skill_ms" && -n "$config_s" && "$skill_ms" -eq $(( config_s * 1000 )) ]]; then
  printf 'ok   SKILL.md timeout_ms (%s) matches config.sh MONITOR_TIMEOUT_SECONDS (%s)\n' \
    "$skill_ms" "$config_s"
else
  printf 'FAIL SKILL.md timeout_ms (%s) does not match config.sh MONITOR_TIMEOUT_SECONDS (%s)\n' \
    "${skill_ms:-none}" "${config_s:-none}" >&2
  fail=1
fi

# The arming cadence, which the halt window's arithmetic depends on. Arming once
# per tick puts the re-arm gap at the whole tick plus the heartbeat wait, which
# exceeds the 30-minute cap on the DEFAULT settings.
check "$skill" 'top of every pass' "SKILL.md tells the tick to arm at the top of every pass"

exit "$fail"
