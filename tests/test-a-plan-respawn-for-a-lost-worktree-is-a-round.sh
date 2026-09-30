#!/usr/bin/env bash
# Claim: `reconcile.py` counts a fresh plan spawn at an attempt number the card
# already spawned as a plan round, and a plan spawn at a new or voided attempt
# number as no round.
#
# The failure it prevents: when a parked card's plan worktree is gone, SKILL.md
# step 2 answers the operator with a fresh `--role plan` dispatch at the SAME
# attempt number, because `--resume` refuses. That writes a `spawn` row, not a
# `resume` row, so the round counted as nothing -- and the same attempt number
# costs no plan attempt either. A card whose worktree kept going was bounded by
# neither MAX_PLAN_ROUNDS nor MAX_PLAN_ATTEMPTS.
#
# A plan agent that failed is re-dispatched at the next number, and one the
# machine killed at the same number after a `void`. Neither is a round.
#
# It drives the real script over a real history file. Only `gh` and `claude`
# are stubbed.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/without-board.sh
source "$root/tests/lib/without-board.sh"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "pr" && "$2" == "list" ]] && { printf '[]\n'; exit 0; }
exit 1
STUB
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

logged() {  # $1 ticket, then one event JSON per argument
  local dir="$fh/instances/demo/cards/$1" event
  mkdir -p "$dir"
  : > "$dir/history.jsonl"
  shift
  for event in "$@"; do
    printf '{"at":"2026-09-30T09:00:00Z","event":%s}\n' "$event" >> "$dir/history.jsonl"
  done
}

counts() {  # $1 claim, $2 wanted, $3 ticket, $4 the fields to print
  local got
  got="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$3" 2>"$work/err" \
    | python3 -c 'import json, sys; c = json.load(sys.stdin)[0]; print(*(c[f] for f in sys.argv[1:]))' $4)"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

spawn() { printf '{"action":"spawn","name":"foreman/demo/P-1/plan-%s","role":"plan","attempt":"%s"}' "$1" "$1"; }
park='{"action":"released","reason":"parked: awaiting plan sign-off"}'
resume='{"action":"resume","name":"foreman/demo/P-1/plan-1","session":"s","role":"plan"}'
hand='{"action":"resume","role":"plan","round":"1"}'
void='{"action":"void","role":"plan","attempt":"1","reason":"disk full"}'

logged P-1 "$(spawn 1)" "$park" "$(spawn 1)"
counts "a fresh spawn at the same attempt, for a lost worktree, is a round and no attempt" \
  "1 1" P-1 "plan_rounds plan_attempts"

logged P-2 "$(spawn 1)" "$park" "$resume" "$park" "$(spawn 1)" "$park" "$(spawn 1)"
counts "resumes and same-attempt spawns each count once" "3" P-2 plan_rounds

logged P-3 "$(spawn 1)" "$(spawn 2)"
counts "a spawn at the next attempt is a new attempt, not a round" \
  "0 2" P-3 "plan_rounds plan_attempts"

logged P-4 "$(spawn 1)" "$void" "$(spawn 1)"
counts "a spawn at a voided attempt is not a round" "0" P-4 plan_rounds

logged P-5 "$(spawn 1)" "$park" "$(spawn 1)" "$void" "$(spawn 1)"
counts "a round's own spawn, voided and re-dispatched, stays one round" "1" P-5 plan_rounds

logged P-6 "$(spawn 1)" "$park" "$hand" "$(spawn 1)"
counts "an old-prose hand row before its fallback spawn is the same round" "1" P-6 plan_rounds

[[ "$fail" -eq 0 ]] && printf 'PASS: a plan respawn for a lost worktree is a plan round\n'
exit "$fail"
