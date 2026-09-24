#!/usr/bin/env bash
# Claim: `reconcile.py` charges a build resume for a failing check to
# `build_attempts`. A resume to fix a blocking review finding is not charged,
# nor is the one retry of a build that produced no PR, nor a plan resume.
#
# The failure this prevents: `build_attempts` counted spawns only. A card whose
# required check never passes is resumed with `brief.py ci-fix` on every pass,
# never spawns again, and so never reaches MAX_BUILD_ATTEMPTS.
#
# It drives the real `reconcile.py` and writes history through the real
# `card_log`, with each resume row in the shape `dispatch.sh --resume --reason`
# appends. Only `gh` and `claude`, the two boundaries outside this machine, are
# stubbed.
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

# No pull request and no running agent. Both answers must be valid JSON: an
# unreadable registry makes `reconcile.py` refuse the whole run.
stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/gh" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
cp "$stubs/gh" "$stubs/claude"
chmod +x "$stubs/gh" "$stubs/claude"

export FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo
# shellcheck source=../skills/board/config.sh
. "$root/skills/board/config.sh"

logged() {  # $1 ticket, $2.. one event JSON per history line
  local ticket="$1"; shift
  rm -rf "$BOARD_HOME/cards/$ticket"
  local event
  for event in "$@"; do card_log "$ticket" "$event"; done
}

attempts() {  # $1 ticket -> its build_attempts
  PATH="$stubs:$PATH" "$root/skills/board/reconcile.py" "$1" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["build_attempts"])'
}

is() {  # $1 name, $2 wanted, $3 got
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1: wanted [$2], got [$3]"
}

spawn='{"action":"spawn","role":"build","attempt":"1"}'
resume() {  # $1 reason -> the row dispatch.sh writes for a build resume
  printf '{"action":"resume","name":"foreman/demo/PRA-1/build-1","session":"s","role":"build","reason":"%s"}' "$1"
}

logged PRA-1 "$spawn" "$(resume ci-fix)"
is "one spawn and one ci-fix resume are two attempts" 2 "$(attempts PRA-1)"

logged PRA-1 "$spawn" "$(resume ci-fix)" "$(resume fix)"
is "a resume to fix a review finding is not charged" 2 "$(attempts PRA-1)"

logged PRA-1 "$spawn" "$(resume retry)"
is "a retry after a build that produced no PR is part of that attempt" 1 "$(attempts PRA-1)"

logged PRA-1 "$spawn" \
  '{"action":"spawn","role":"build","attempt":"2"}' \
  '{"action":"void","role":"build","attempt":"2","reason":"no disk"}' \
  "$(resume ci-fix)"
is "a voided spawn still costs nothing beside a charged resume" 2 "$(attempts PRA-1)"

# A plan resume carries its own role and is counted by plan_rounds. The generic
# row a non-build resume writes names no role, so neither is a build attempt.
logged PRA-1 "$spawn" \
  '{"action":"resume","role":"plan","round":"1"}' \
  '{"action":"resume","name":"foreman/demo/PRA-1/plan-1","session":"s"}'
is "plan resumes do not touch build_attempts" 1 "$(attempts PRA-1)"

exit "$fail"
