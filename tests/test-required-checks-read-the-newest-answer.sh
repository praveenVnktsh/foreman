#!/usr/bin/env bash
# Claim: `reconcile.py` reads each required check from its NEWEST run, and a
# commit status that has not answered yet is pending, never failing.
#
# Two failures it prevents, both in `check_rollup`:
#
#   - A commit status (`StatusContext`) has no `status` field, only a `state`
#     of PENDING, EXPECTED, SUCCESS, FAILURE or ERROR. PENDING and EXPECTED
#     were read as conclusions, so a check still waiting to report was
#     `failing`, and the tick resumed a build agent to fix a failure that did
#     not exist -- spending a build attempt on it.
#   - One check name can appear several times: a re-run, or two workflows with
#     a job of the same name. The verdict came from whichever entry GitHub
#     listed last, so a check that failed and then passed on a re-run could
#     read as failing, and one that passed and then failed as passing. The
#     newest entry answers. When the stamps cannot say which is newest, any
#     pending entry makes the check pending, and otherwise any failed entry
#     makes it failing.
#
# It drives the real script. `gh pr list` answers with the rollup each case
# writes; nothing else is stubbed but the agent registry.
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
# The fixture's board.toml requires exactly one check, named `Tests`.
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then cat "$work/prs"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then echo README.md; exit 0; fi
exit 1
STUB
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

# $1 claim, $2 wanted `passing=<bool> failing=<names> pending=<names>`,
# $3 the rollup as a JSON list
checks_of() {
  python3 - "$work/prs" "$3" <<'PY'
import json, sys
path, rollup = sys.argv[1], json.loads(sys.argv[2])
open(path, "w").write(json.dumps([{
    "number": 7, "state": "OPEN", "isCrossRepository": False,
    "headRefOid": "1" * 40, "statusCheckRollup": rollup,
}]))
PY
  local got
  got="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" ACME-1 2>"$work/err" \
    | python3 -c '
import json, sys
c = json.load(sys.stdin)[0]["pr"]["checks"]
print("passing=%s failing=%s pending=%s"
      % (c["passing"], ",".join(c["failing"]), ",".join(c["pending"])))
')"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

ZERO="0001-01-01T00:00:00Z"
run() {  # $1 status, $2 conclusion, $3 startedAt, $4 completedAt
  printf '{"__typename":"CheckRun","name":"Tests","status":"%s","conclusion":"%s","startedAt":"%s","completedAt":"%s"}' \
    "$1" "$2" "$3" "$4"
}
status() {  # $1 state
  printf '{"__typename":"StatusContext","context":"Tests","state":"%s","startedAt":"2026-09-30T09:00:00Z"}' "$1"
}

# --- commit statuses ---------------------------------------------------------
checks_of "a commit status still PENDING is pending, not failing" \
  "passing=False failing= pending=Tests" "[$(status PENDING)]"
checks_of "a commit status still EXPECTED is pending, not failing" \
  "passing=False failing= pending=Tests" "[$(status EXPECTED)]"
checks_of "a commit status that reported SUCCESS passes" \
  "passing=True failing= pending=" "[$(status SUCCESS)]"
checks_of "a commit status that reported ERROR fails" \
  "passing=False failing=Tests pending=" "[$(status ERROR)]"

# --- one name, several runs ----------------------------------------------------
failed="$(run COMPLETED FAILURE 2026-09-30T09:00:00Z 2026-09-30T09:05:00Z)"
passed="$(run COMPLETED SUCCESS 2026-09-30T09:10:00Z 2026-09-30T09:15:00Z)"
checks_of "a re-run that passed after a failure passes, listed after it" \
  "passing=True failing= pending=" "[$failed, $passed]"
checks_of "a re-run that passed after a failure passes, listed before it" \
  "passing=True failing= pending=" "[$passed, $failed]"

older_pass="$(run COMPLETED SUCCESS 2026-09-30T09:00:00Z 2026-09-30T09:05:00Z)"
newer_fail="$(run COMPLETED FAILURE 2026-09-30T09:10:00Z 2026-09-30T09:15:00Z)"
checks_of "a failure after a pass fails, whatever the order" \
  "passing=False failing=Tests pending=" "[$newer_fail, $older_pass]"

in_flight="$(run IN_PROGRESS "" 2026-09-30T09:10:00Z "$ZERO")"
checks_of "a re-run in flight after a failure is pending" \
  "passing=False failing= pending=Tests" "[$failed, $in_flight]"

# gh prints a stamp GitHub left null as 0001-01-01. A queued re-run has both,
# and read as dates they made it the OLDEST entry, so the failure it re-runs won.
queued="$(run QUEUED "" "$ZERO" "$ZERO")"
checks_of "a queued re-run with no stamps is pending, not the failure it re-runs" \
  "passing=False failing= pending=Tests" "[$failed, $queued]"

undated_fail='{"name":"Tests","status":"COMPLETED","conclusion":"FAILURE"}'
undated_pass='{"name":"Tests","status":"COMPLETED","conclusion":"SUCCESS"}'
checks_of "undated runs that disagree fail, whatever the order" \
  "passing=False failing=Tests pending=" "[$undated_pass, $undated_fail]"

[[ "$fail" -eq 0 ]] && printf 'PASS: each required check is read from its newest answer\n'
exit "$fail"
