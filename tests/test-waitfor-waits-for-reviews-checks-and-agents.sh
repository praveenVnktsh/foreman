#!/usr/bin/env bash
# waitfor.py's `reviews`, `checks` and `agents` waits, driven for real with
# `gh` and `claude` stubbed on PATH. Only `deploy` was tested before, and the
# `agents` wait had a prefix bug nobody saw: waiting on attempt 1 matched
# attempt 10's agents too, so a round-10 reviewer still running held up a wait
# on round 1 until its budget ran out.
#
# Each wait has three answers, and each is asserted by exit code and verdict:
# 0 satisfied, 1 the budget ran out, 3 settled and unsatisfied (deploy only).
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
waitfor="$root/skills/board/waitfor.py"

# shellcheck source=lib/without-board.sh
source "$here/lib/without-board.sh"
# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

TICKET="ACME-2"
home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"
reviews="$fh/instances/demo/cards/$TICKET/reviews"
mkdir -p "$reviews"

stub_bin="$work/bin"
registry="$work/agents.json"
pr_json="$work/pr.json"
mkdir -p "$stub_bin"
printf '[]\n' > "$registry"

cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then cat "$pr_json"; exit 0; fi
exit 1
STUB
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then cat "$registry"; exit 0; fi
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

# Prints `<exit> <satisfied> <outcome>` for one wait. The budget is one second:
# every wait here either holds on its first poll or never will.
ask() { # subcommand args...
  local out rc
  out="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$waitfor" "$@" --timeout 1 2>"$work/err")"
  rc=$?
  printf '%s ' "$rc"
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    print("no-verdict")
else:
    print(d["satisfied"], d["outcome"])
' "$out"
}

expect() { # label expected actual
  if [[ "$3" == "$2" ]]; then ok "$1"
  else bad "$1 -- expected '$2', got '$3': $(cat "$work/err")"; fi
}

# --------------------------------------------------------------- reviews
printf '{"findings": []}\n' > "$reviews/1a.json"
expect "reviews: a round with a file still missing waits out its budget" \
  "1 False budget-expired" "$(ask reviews --ticket "$TICKET" --round 1 --slots a,b)"

printf '{"findings": [{"severity": "note"}]}\n' > "$reviews/1b.json"
expect "reviews: every slot's file arrived, so the wait holds" \
  "0 True satisfied" "$(ask reviews --ticket "$TICKET" --round 1 --slots a,b)"

# Half a file may still be mid-write: it is waited on, never read as a review
# that found nothing.
printf '{"findings": [' > "$reviews/1b.json"
expect "reviews: a half-written file is waited on, not read as clean" \
  "1 False budget-expired" "$(ask reviews --ticket "$TICKET" --round 1 --slots a,b)"

# ---------------------------------------------------------------- checks
write_pr() { # status:conclusion of the required check
  local status="${1%%:*}" conclusion="${1#*:}"
  printf '{"state":"OPEN","headRefOid":"abc","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"Tests","status":"%s","conclusion":"%s"}]}\n' \
    "$status" "$conclusion" > "$pr_json"
}

write_pr "IN_PROGRESS:"
expect "checks: a required check still running waits out its budget" \
  "1 False budget-expired" "$(ask checks --pr 7)"

write_pr "COMPLETED:SUCCESS"
expect "checks: a required check that passed holds" \
  "0 True satisfied" "$(ask checks --pr 7)"

# A failing check is an answer too. The tick acts on it now rather than
# waiting for it to improve.
write_pr "COMPLETED:FAILURE"
expect "checks: a required check that failed also ends the wait" \
  "0 True satisfied" "$(ask checks --pr 7)"

printf '{"state":"OPEN","headRefOid":"abc","statusCheckRollup":[]}\n' > "$pr_json"
expect "checks: an empty rollup is a build that never queued, and is waited on" \
  "1 False budget-expired" "$(ask checks --pr 7)"

# ---------------------------------------------------------------- agents
row() { # name state
  printf '{"name": "foreman/demo/%s/%s", "sessionId": "s-%s", "startedAt": 1, "cwd": "/tmp", "state": "%s", "pid": 4242}' \
    "$TICKET" "$1" "$1" "$2"
}
printf '[%s, %s, %s]\n' "$(row review-1a done)" "$(row review-1b done)" \
  "$(row review-10a working)" > "$registry"

expect "agents: round 1's reviewers are done; round 10's running reviewer is not theirs" \
  "0 True satisfied" "$(ask agents --ticket "$TICKET" --role review --attempt 1)"
expect "agents: round 10's running reviewer holds up a wait on round 10" \
  "1 False budget-expired" "$(ask agents --ticket "$TICKET" --role review --attempt 10)"

printf '[%s]\n' "$(row build-1 working)" > "$registry"
expect "agents: a running build agent holds up the wait" \
  "1 False budget-expired" "$(ask agents --ticket "$TICKET" --role build --attempt 1)"
expect "agents: no agent for the role is waited on, never read as done" \
  "1 False budget-expired" "$(ask agents --ticket "$TICKET" --role review --attempt 1)"

exit "$fail"
