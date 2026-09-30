#!/usr/bin/env bash
# Claim: `reconcile.py` counts one plan round per plan resume, whichever of
# the three history shapes recorded it.
#
#   - Now: dispatch.sh writes `role` on every resume row, so its own row
#     (`"role":"plan"`, with the agent's `name`) is the round, and the tick
#     writes nothing more.
#   - Before: dispatch.sh's row named no role, and the tick logged the round
#     by hand (`"role":"plan","round":"<n>"`, no `name`). A card parked across
#     the upgrade must keep those rounds.
#   - During the upgrade: a tick still following the old prose writes its hand
#     row right after dispatch.sh's new one. That pair is ONE round.
#
# The failure it prevents: counting both rows of that pair sends a card to
# `Needs Human` at half the MAX_PLAN_ROUNDS the operator allowed; counting
# neither shape lets a conversation that is not converging loop forever.
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

rounds() {  # $1 claim, $2 wanted, $3 ticket
  local got
  got="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$3" 2>"$work/err" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["plan_rounds"])')"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

spawn='{"action":"spawn","role":"plan","attempt":"1"}'
now_row='{"action":"resume","name":"foreman/demo/P-1/plan-1","session":"s","role":"plan"}'
old_row='{"action":"resume","name":"foreman/demo/P-1/plan-1","session":"s"}'
hand_row() { printf '{"action":"resume","role":"plan","round":"%s"}' "$1"; }
build_resume='{"action":"resume","name":"foreman/demo/P-1/build-1","session":"s","role":"build","reason":"fix"}'

logged P-1 "$spawn" "$now_row" "$now_row"
rounds "two resumes logged by dispatch.sh are two rounds" 2 P-1

logged P-2 "$spawn" "$old_row" "$(hand_row 1)" "$old_row" "$(hand_row 2)"
rounds "rounds logged the old way, by hand, still count" 2 P-2

logged P-3 "$spawn" "$now_row" "$(hand_row 1)" "$now_row" "$(hand_row 2)"
rounds "a hand row right after dispatch.sh's own is the same round" 2 P-3

logged P-4 "$spawn" "$old_row" "$(hand_row 1)" "$now_row"
rounds "a card parked across the upgrade keeps its old rounds and adds new ones" 2 P-4

logged P-5 "$spawn" "$build_resume" "$now_row"
rounds "a build resume is never a plan round" 1 P-5

logged P-6 '{"action":"spawn","role":"build","attempt":"1"}'
rounds "a card built without a plan stage has no plan rounds" 0 P-6

[[ "$fail" -eq 0 ]] && printf 'PASS: one plan round per plan resume\n'
exit "$fail"
