#!/usr/bin/env bash
# A stage whose model is rate-limited runs on the next tier down, and on its
# first choice again once the cooldown ends.
#
# On 2026-09-16 the plan stage stayed on a rate-limited `PLAN_MODEL=fable` for
# 11 hours: every plan agent died on its first API call, and every pass
# dispatched the next one onto the same model. skills/board/fallback.py is what
# dispatch.sh now asks for the model, so this drives it directly, with a pinned
# clock (FALLBACK_NOW) and a temporary home. Nothing is stubbed: the stamps are
# real files written by the script's own `mark`.
#
# Every run starts from `env -i`, so a PLAN_MODEL or FALLBACK_TIERS in the
# shell that runs this test cannot decide what it proves. Callers prefix the
# knobs; config.sh does not export them.
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

# fb [KEY=VALUE ...] -- <fallback.py args>
# Runs fallback.py under the environment dispatch.sh prefixes for a claude
# installation with default tiers and no floors, plus the given overrides.
# stdout is the script's; stderr lands in $work_dir/stderr.
fb() {
  local overrides=()
  while [[ "$1" != "--" ]]; do overrides+=("$1"); shift; done
  shift
  env -i PATH="$PATH" \
    FOREMAN_HOME="$home" \
    FALLBACK_NOW="2026-09-16T06:00:00Z" \
    FALLBACK_TIERS="fable opus sonnet haiku" \
    FALLBACK_COOLDOWN_MINUTES=60 \
    PLAN_MODEL=fable BUILD_MODEL=opus REVIEW_MODEL=opus CLEANUP_MODEL=fable \
    PLAN_FLOOR= BUILD_FLOOR= REVIEW_FLOOR= \
    ${overrides[@]+"${overrides[@]}"} \
    "$fallback" "$@" 2>"$work_dir/stderr"
}

# field <json> <key>: one key of a JSON object, printed as compact JSON.
field() {
  python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])[sys.argv[2]], separators=(",", ":")))' "$1" "$2"
}

expect() { # description got want
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    bad "$1: expected $3, got $2"
    # The script's own refusal is the reason, and the EXIT trap deletes it.
    [[ -s "$work_dir/stderr" ]] && sed 's/^/     /' "$work_dir/stderr"
  fi
}

forget_limits() { rm -rf "$home/rate-limits"; }

expect "with no stamps, the plan stage runs on its first choice" \
  "$(fb -- model plan)" "fable"

fb -- mark fable >/dev/null
expect "with fable limited, the plan stage runs on opus" \
  "$(fb -- model plan)" "opus"
if grep -q 'plan model fable is rate-limited until 2026-09-16T07:00:00Z; running on opus' "$work_dir/stderr"; then
  ok "model says on stderr which model was limited, until when, and what it runs on"
else
  bad "model says on stderr why it fell back: got $(cat "$work_dir/stderr")"
fi

resolved="$(fb -- resolve plan)"
expect "resolve says the plan stage fell back" "$(field "$resolved" fell_back)" "true"
expect "resolve names the limited model and when its limit ends" \
  "$(field "$resolved" limited)" '[{"model":"fable","until":"2026-09-16T07:00:00Z"}]'
expect "resolve reports no floor reached while a tier below is free" \
  "$(field "$resolved" floor_reached)" "false"

fb -- mark opus >/dev/null
expect "with fable and opus limited and no floor, the plan stage runs on sonnet" \
  "$(fb -- model plan)" "sonnet"

resolved="$(fb PLAN_FLOOR=opus -- resolve plan)"
expect "with fable and opus limited and PLAN_FLOOR=opus, the plan stage stays on opus" \
  "$(field "$resolved" model)" '"opus"'
expect "with fable and opus limited and PLAN_FLOOR=opus, the floor is reached" \
  "$(field "$resolved" floor_reached)" "true"

# The stamps above expire at 07:00:00. A stamp is live while now < expiry, so
# at exactly that moment the cooldown is over.
expect "once the cooldown ends, the plan stage runs on its first choice again" \
  "$(fb FALLBACK_NOW=2026-09-16T07:00:00Z -- model plan)" "fable"

expect "an empty PLAN_MODEL stays empty (inherit) even while fable is limited" \
  "$(fb PLAN_MODEL= -- model plan)" ""

expect "with FALLBACK_TIERS empty, fallback is off even while fable is limited" \
  "$(fb FALLBACK_TIERS= -- model plan)" "fable"

fb -- mark some-model >/dev/null
expect "a first choice that is not a tier is never replaced" \
  "$(fb PLAN_MODEL=some-model -- model plan)" "some-model"

forget_limits
fb -- mark sonnet >/dev/null
expect "the build stage on opus never walks up to fable when sonnet is limited" \
  "$(fb -- model build)" "opus"

forget_limits
mkdir -p "$home/rate-limits"
printf 'not a stamp\n' >"$home/rate-limits/fable"
expect "an unreadable stamp is ignored, not refused" \
  "$(fb -- model plan)" "fable"

forget_limits
marked="$(fb FALLBACK_COOLDOWN_MINUTES=90 -- mark fable)"
expect "mark prints the expiry at now plus FALLBACK_COOLDOWN_MINUTES" \
  "$marked" '{"model":"fable","until":"2026-09-16T07:30:00Z"}'
expect "mark writes that expiry as the stamp's one line" \
  "$(cat "$home/rate-limits/fable")" "2026-09-16T07:30:00Z"
expect "mark --minutes overrides the cooldown" \
  "$(fb -- mark fable --minutes 5)" '{"model":"fable","until":"2026-09-16T06:05:00Z"}'

if fb -- mark ../x >/dev/null; then
  bad "mark refuses a model that would write outside the stamp directory: it exited 0"
elif [[ -e "$home/x" ]]; then
  bad "mark refuses a model that would write outside the stamp directory: $home/x exists"
else
  ok "mark refuses a model that would write outside the stamp directory"
fi

# Callers prefix every stage model. An unset one means the knobs never
# arrived, and reading it as empty would spawn the stage on inherit.
if env -i PATH="$PATH" FOREMAN_HOME="$home" FALLBACK_TIERS="fable opus sonnet haiku" \
    PLAN_FLOOR= "$fallback" model plan >/dev/null 2>"$work_dir/stderr"; then
  bad "an unset PLAN_MODEL is refused rather than read as inherit: it exited 0"
elif ! grep -q 'PLAN_MODEL is unset' "$work_dir/stderr"; then
  bad "an unset PLAN_MODEL is refused rather than read as inherit: the refusal does not name it: $(cat "$work_dir/stderr")"
else
  ok "an unset PLAN_MODEL is refused rather than read as inherit"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: fallback picks the next tier\n'
exit "$fail"
