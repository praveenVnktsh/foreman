#!/usr/bin/env bash
# The review stage falls back no lower than sonnet unless foreman.toml sets a floor.
#
# Found auditing the board on 2026-09-30. bin/installation.py emits an empty
# REVIEW_FLOOR when foreman.toml sets no floor, and fallback.py read empty as
# "no floor": with opus and sonnet rate-limited, the one review a diff gets
# before it merges ran on haiku. Nothing is stubbed: the stamps are real files
# written by the script's own `mark`, under a pinned clock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fallback="$repo_root/skills/board/fallback.py"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
home="$work_dir/home"
mkdir -p "$home"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# fb [KEY=VALUE ...] -- <fallback.py args>: the environment dispatch.sh
# prefixes for a claude installation whose foreman.toml sets no floors.
fb() {
  local overrides=()
  while [[ "$1" != "--" ]]; do overrides+=("$1"); shift; done
  shift
  env -i PATH="$PATH" FOREMAN_HOME="$home" FALLBACK_NOW="2026-09-16T06:00:00Z" \
    FALLBACK_TIERS="fable opus sonnet haiku" FALLBACK_COOLDOWN_MINUTES=60 \
    PLAN_MODEL=fable BUILD_MODEL=opus REVIEW_MODEL=opus CLEANUP_MODEL=fable \
    PLAN_FLOOR= BUILD_FLOOR= REVIEW_FLOOR= \
    ${overrides[@]+"${overrides[@]}"} \
    "$fallback" "$@" 2>"$work_dir/stderr"
}

expect() { # description got want
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected $3, got $2 ($(cat "$work_dir/stderr"))"; fi
}

fb -- mark opus >/dev/null
fb -- mark sonnet >/dev/null

expect "with opus and sonnet limited and no floor declared, review stays on sonnet" \
  "$(fb -- model review)" "sonnet"
expect "the build stage keeps no default floor and runs on haiku" \
  "$(fb -- model build)" "haiku"
expect "a review floor foreman.toml declares wins over the default" \
  "$(fb REVIEW_FLOOR=haiku -- model review)" "haiku"
expect "tiers that do not name sonnet get no default review floor" \
  "$(fb FALLBACK_TIERS="opus haiku" -- model review)" "haiku"

[[ "$fail" -eq 0 ]] || exit 1
echo "all review floor cases passed"
