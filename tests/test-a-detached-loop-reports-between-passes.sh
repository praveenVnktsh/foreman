#!/bin/bash
# Claim: a detached loop lists `working` with status "between passes" while
# its wrapper sleeps, and a null status while a pass runs.
#
# The failure it prevents: the log of a loop is silent while it sleeps, so a
# reader judging health by the log's age could not tell the wait from a
# wedged pass. The status says which it is; the state stays `working`, so no
# guard that keeps a live agent's record, slot or worktree changes.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skills/board/harness/detached.sh
source "$root/skills/board/harness/detached.sh"

work="$(mktemp -d)"
home="$work/home"
cwd="$work/cwd"
mkdir -p "$home" "$cwd"
id=""
trap '[[ -n "$id" ]] && detached_stop "$home" "$id" >/dev/null 2>&1; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

row() { # <field>
  detached_list "$home" | python3 -c '
import json, sys
value = json.load(sys.stdin)[0].get(sys.argv[1])
print("null" if value is None else value)
' "$1"
}

# Each pass holds until <gate> exists, then the loop waits a minute.
gate="$work/gate"
id="$(detached_spawn foreman/t/tick "$cwd" "$home" 1 -- \
  /bin/bash -c "while [ ! -f '$gate' ]; do sleep 0.1; done")"

tries=0
until [[ -d "$home/agents/$id.tmp" ]] || [[ "$tries" -ge 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
[[ "$(row status)" == null ]] && ok "a loop mid-pass has no status" || bad "a loop mid-pass has status '$(row status)'"

: >"$gate"
tries=0
until [[ "$(row status)" == "between passes" ]] || [[ "$tries" -ge 50 ]]; do sleep 0.1; tries=$(( tries + 1 )); done
[[ "$(row status)" == "between passes" ]] \
  && ok "a loop waiting for its next pass says so in its status" \
  || bad "a loop waiting for its next pass has status '$(row status)'"
[[ "$(row state)" == working ]] \
  && ok "a loop between passes still lists as working" \
  || bad "a loop between passes lists as '$(row state)'"

exit "$fail"
