#!/usr/bin/env bash
# Claim: two dispatches racing for a board's last slot cannot both spawn.
#
# The ceiling is counted from history.jsonl, and a card holds a slot only once
# its spawn row is written. dispatch.sh used to check the ceiling and then, a
# worktree cut and a spawn later, write that row -- with nothing between the
# two. Two dispatches started together both counted zero held slots, both
# passed, and both spawned: the board one past MAX_CONCURRENT with every gate
# reporting success. dispatch.sh now holds a machine-wide lock from a second
# ceiling check through the spawn row.
#
# `claude` is the only external boundary stubbed. The stub answers `agents` for
# every name it has spawned, so both spawns can register, and it takes a second
# to spawn, the way the real one does, which is the window the race needs.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

names="$work_dir/spawned-names"
: >"$names"
cat >"$_DISPATCH_STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  sleep 1
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--name" && \$# -ge 2 ]]; then printf '%s\n' "\$2" >>"$names"; fi
    shift
  done
  echo "stub-session-\$\$"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  python3 - "$names" "\$\$" "\$PWD" <<'PY'
import json, sys
path, pid, cwd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
names = [n for n in open(path).read().split("\n") if n]
print(json.dumps([{"name": n, "id": "stub-" + n, "sessionId": "session-" + n, "pid": pid,
                   "state": "working", "startedAt": 1, "cwd": cwd, "status": "running"}
                  for n in names]))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$_DISPATCH_STUB_BIN/claude"

# dispatch_fixture_run, with the board's own ceiling at 1 and the output kept
# per ticket. The fixture raises both ceilings out of the way; this test is
# about one of them.
dispatch_at_ceiling_one() { # <ticket>
  local toolchain=() name
  for name in $_DISPATCH_TOOLCHAIN; do
    if [[ -n "${!name+set}" ]]; then toolchain+=("$name=${!name}"); fi
  done
  env -i HOME="$DISPATCH_HOME" FOREMAN_INSTANCE=demo FOREMAN_HOME="$DISPATCH_HOME/.foreman" \
    MAX_CONCURRENT=1 HOST_MAX_CONCURRENT=9 PATH="$_DISPATCH_STUB_BIN:$PATH" \
    ${toolchain[@]+"${toolchain[@]}"} \
    "$DISPATCH" --ticket "$1" --role build --attempt 1 --prompt-file "$DISPATCH_PROMPT" \
    >"$work_dir/$1.log" 2>&1
}
_dispatch_ensure_toolchain

dispatch_at_ceiling_one RACE-1 &
first=$!
dispatch_at_ceiling_one RACE-2 &
second=$!
wait "$first"; wait "$second"

cards="$DISPATCH_HOME/.foreman/instances/demo/cards"
spawns="$(cat "$cards"/RACE-*/history.jsonl 2>/dev/null | grep -c '"action":"spawn"')"
if [[ "$spawns" == 1 ]]; then
  ok "exactly one of two racing dispatches spawned"
else
  bad "$spawns of two racing dispatches spawned against a ceiling of 1"
  cat "$work_dir"/RACE-*.log >&2
fi
grep -l 'at the concurrency ceiling' "$work_dir"/RACE-*.log >/dev/null \
  && grep -h 'NOT a failure of ticket' "$work_dir"/RACE-*.log >/dev/null \
  && ok "the other was refused at the ceiling, not charged to its ticket" \
  || { bad "neither dispatch was refused at the ceiling"; cat "$work_dir"/RACE-*.log >&2; }

[[ "$fail" -eq 0 ]] && printf 'PASS: two dispatches cannot both take the last slot\n'
exit "$fail"
