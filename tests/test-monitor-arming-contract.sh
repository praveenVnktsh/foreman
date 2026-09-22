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

exit "$fail"
