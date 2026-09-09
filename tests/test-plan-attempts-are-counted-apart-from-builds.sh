#!/usr/bin/env bash
# Claim: `reconcile.py` charges a failed plan attempt to `plan_attempts` and to
# nothing else, and a card's record no longer carries a `plan` field at all.
#
# The failure the counter prevents: the plan stage is its own agent now, so a
# card whose plan agent dies, times out or never posts a graph is re-dispatched
# from scratch. Charged to `build_attempts`, those failures would arrive at the
# build stage as a build budget already spent -- and the card would then fail
# the build almost at once, for a reason the build agent never touched.
# MAX_PLAN_ATTEMPTS is a separate cap because it answers a separate question,
# and it can only be enforced if the number it reads counts one stage.
#
# The failure the missing field prevents: `plan` used to be `plan_pushed()`,
# which asked origin whether the card's branch ADDED a file under `PLAN_DIR`.
# The plan is a comment on the Linear card now, found by `plancomments.py`. A
# record that still carried the old field would answer that question from git
# forever -- `absent` on every card, because no branch adds a plan any more --
# and a tick reading it would hold every card in `Plan` for a push that is
# never coming.
#
# It drives the real `reconcile.py` and writes history through the real
# `card_log`, so the entry shape asserted here is the shape `dispatch.sh`
# actually appends. Only the two things outside this machine are stubbed:
# `gh`, which is asked for the card's pull request, and `claude`, which is
# asked for the agent registry.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

fh="$work/.foreman"
repo="$work/repo"
mkdir -p "$repo"
fixture_board_toml "$repo"
fixture_add_board "$work" demo "$repo"

# The two external boundaries, and nothing else. `gh` answers that the card has
# no pull request, which is what a card still in `Plan` looks like; `claude`
# answers that no agent is running. Both must be valid JSON on stdout: an
# unreadable registry makes `reconcile.py` refuse the whole run (exit 3), which
# is its own tested behaviour and would hide this one.
stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/gh" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
cat > "$stubs/claude" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
chmod +x "$stubs/gh" "$stubs/claude"

export FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo
# `card_log` is the real writer from config.sh, sourced rather than reimplemented
# so this test cannot pass against a history format nothing writes.
# shellcheck source=../skills/board/config.sh
. "$root/skills/board/config.sh"

logged() {  # $1 ticket, $2.. one event JSON per history line
  local ticket="$1"; shift
  rm -rf "$BOARD_HOME/cards/$ticket"
  local event
  for event in "$@"; do card_log "$ticket" "$event"; done
}

field() {  # $1 ticket, $2 field -> that field of the card's record
  PATH="$stubs:$PATH" "$root/skills/board/reconcile.py" "$1" \
    | python3 -c '
import json, sys
record = json.load(sys.stdin)[0]
value = record.get(sys.argv[1], "<<absent>>")
print(json.dumps(value))
' "$2"
}

is() {  # $1 name, $2 wanted, $3 got
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1: wanted [$2], got [$3]"
}

# --- one stage's attempts are not another's ---------------------------------
#
# Every kind of entry a card accumulates, on one card. Two build attempts, one
# plan attempt, one review spawn, the generic resume line `dispatch.sh --resume`
# writes for every resume of every kind, and the explicit plan ROUND the tick
# logs when an operator asks for a revision. Only the plan spawn is a plan
# attempt. The generic resume is the one that has to be ignored by reading the
# `role` the entry states: it names no stage, and counting it would charge the
# plan budget for a build resumed to fix a failing check.
logged PRA-1 \
  '{"action":"spawn","role":"build","attempt":"1"}' \
  '{"action":"spawn","role":"build","attempt":"2"}' \
  '{"action":"spawn","role":"plan","attempt":"1"}' \
  '{"action":"spawn","role":"review","attempt":"1"}' \
  '{"action":"resume","name":"foreman/demo/PRA-1/build-2","session":"s"}' \
  '{"action":"resume","role":"plan","round":"1"}'

is "a plan attempt is charged to plan_attempts" 1 "$(field PRA-1 plan_attempts)"
is "and build attempts are not charged to it" 2 "$(field PRA-1 build_attempts)"
is "an operator's plan revision is a round, not an attempt" \
  1 "$(field PRA-1 plan_rounds)"

# --- a plan attempt costs what a build attempt costs -------------------------
#
# The same two rules, because it is the same budget arithmetic: a re-dispatch at
# the same attempt number after an environment repair is still one attempt, and
# an attempt voided for a machine fault costs nothing. A full disk is evidence
# about the machine and none at all about the card, so spending the plan budget
# on it would park a card that was never actually planned even once.
logged PRA-2 \
  '{"action":"spawn","role":"plan","attempt":"1"}' \
  '{"action":"spawn","role":"plan","attempt":"1"}' \
  '{"action":"spawn","role":"plan","attempt":"2"}' \
  '{"action":"void","role":"plan","attempt":"2","reason":"no disk"}'

is "a plan attempt re-dispatched at the same number is one attempt, and a voided one is none" \
  1 "$(field PRA-2 plan_attempts)"

# --- the plan is not a pushed file any more ---------------------------------
#
# `<<absent>>` rather than a null, so a field that came back as JSON `null`
# cannot pass for a field that is gone. The evidence lives on the Linear card,
# where `plancomments.py` reads it; `reconcile.py` never asks git about it.
is "a card's record carries no plan field" '"<<absent>>"' "$(field PRA-1 plan)"

exit "$fail"
