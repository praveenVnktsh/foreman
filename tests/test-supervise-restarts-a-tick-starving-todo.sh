#!/usr/bin/env bash
# Claim: supervise.sh replaces a live, healthy-looking tick that has outlived a
# Todo card waiting on a board with free slots, and names the board and the card.
#
# The failure it prevents: on 2026-09-16 a tick alive for two hours stopped
# reading one board's Todo column. A card waited 30 minutes with 8 free slots
# until a manual `supervise.sh --restart`. The transcript kept moving, so every
# liveness check passed and the watchdog called the tick healthy.
#
# It also pins the other direction, because a restart is not free:
#   - a card that entered Todo moments ago is the tick's to adopt, not a fault;
#   - a tick younger than TICK_STARVED_MINUTES has not had its window yet, and
#     judging it would restart every replacement before its first pass;
#   - a Linear read that failed is no verdict, and a restart cannot fix Linear;
#   - a red main stands the board down, and a restart cannot fix main either;
#   - a threshold inside TICK_INTERVAL_MINUTES is refused outright.
#
# It drives the real supervise.sh, and the real starved.py, reconcile.py and
# queue.py and preflight.py under it. Only the harness (a stub `claude` on
# PATH), GitHub (a stub `gh` on PATH) and Linear (tests/lib/linear-stub.py) are
# stubbed; the target's origin is a local bare repository.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"
stub="$repo_root/tests/lib/linear-stub.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" >/dev/null 2>&1
  [[ -n "$STUB_PID" ]] && wait "$STUB_PID" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# config.sh lets the environment win over boards.toml, board.toml and ids.env.
# A test run from inside a board slice inherits that slice's REPO, KEY_FILE and
# ids, and they would answer for the fixture board. Remove every name the
# fixture means to supply.
unset REPO KEY_FILE BOARD_HOME INSTANCE INSTANCE_HOME BOARD_NAME_PREFIX \
  BOARD_WORKTREE_PREFIX FOREMAN_ROOT MAX_CONCURRENT HOST_MAX_CONCURRENT \
  HOST_SLOT_STALE_MINUTES TICK_STARVED_MINUTES TICK_INTERVAL_MINUTES \
  TICK_MAX_AGE_HOURS STARVED_API_URL
for name in $(compgen -e); do
  case "$name" in STATE_*|LABEL_*|LINEAR_*) unset "$name" ;; esac
done

target="$work/target"
mkdir -p "$target"
git init -q --bare "$work/origin"
git -C "$target" init -q -b main
fixture_board_toml "$target"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$target" remote add origin "$work/origin"
git -C "$target" push -q origin main
printf '[limits]\nmax_concurrent = 3\n' >>"$target/board.toml"
home="$work/home"
fh="$home/.foreman"
fixture_add_board "$home" demo "$target"
printf 'LINEAR_PROJECT_ID=project-1\nSTATE_TO_PICK_UP=state-todo\n' >"$fh/instances/demo/ids.env"

# One card in review holds a slot, so the board has cards in flight AND free
# slots: the incident's shape.
mkdir -p "$fh/instances/demo/cards/ABC-2"
printf '{"at":"%s","event":{"action":"spawn","name":"x","role":"review","attempt":"1"}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$fh/instances/demo/cards/ABC-2/history.jsonl"

registry="$work/registry.json"
stopped="$work/stopped.log"
started="$work/started.log"
install="$home/install"
mkdir -p "$install"
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
transcripts="$home/.claude/projects/$(slug "$install")"
mkdir -p "$transcripts"
export INSTALL="$install"

# tick <age hours> -- one live tick with a pid and a transcript written just
# now, so no liveness check fires and only the starved check can.
tick() {
  python3 - "$registry" "$1" <<'PY'
import json, os, sys, time
path, age_hours = sys.argv[1], float(sys.argv[2])
json.dump([{"id": "tick-old", "name": "foreman/tick", "state": "idle", "pid": 4321,
            "startedAt": int((time.time() - age_hours * 3600) * 1000),
            "cwd": os.environ["INSTALL"], "sessionId": "sid-old"}], open(path, "w"))
PY
  : >"$transcripts/sid-old.jsonl"
}
# supervise.sh halts the machine, without restarting it, while any declared
# board's agent Monitor is not alive, and that gate sits ahead of the branch
# this test drives. Arming every declared board on each scenario keeps the
# stamps fresh for the whole run, including boards declared partway through.
arm_monitors() {
  local dir
  for dir in "$fh"/instances/*/; do
    [[ -d "$dir" ]] || continue
    fixture_arm_monitor "$fh" "$(basename "$dir")"
  done
}
reset() { rm -f "$registry"; : >"$stopped"; : >"$started"; arm_monitors; }

mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
registry="$registry"; stopped="$stopped"; started="$started"
if [[ "\$1" == "agents" ]]; then cat "\$registry"; exit 0; fi
if [[ "\$1" == "stop" ]]; then
  printf '%s\n' "\$2" >>"\$stopped"
  python3 - "\$registry" "\$2" <<'PY'
import json, sys
path, victim = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
for r in rows:
    if r["id"] == victim:
        r["state"] = "stopped"; r.pop("pid", None)
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
if [[ "\$1" == "--bg" ]]; then
  name=""
  while [[ \$# -gt 0 ]]; do [[ "\$1" == "--name" ]] && name="\$2"; shift; done
  printf '%s\n' "\$name" >>"\$started"
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

# `gh run list` answers with $work/ci.json, the newest CI run on main, which
# starved.py reads through `reconcile.py --main-ci`. Every other call succeeds,
# so preflight.py's gh and runner checks pass.
cat >"$home/.local/bin/gh" <<GH
#!/usr/bin/env bash
if [[ "\$1" == "run" && "\$2" == "list" ]]; then cat "$work/ci.json"; exit 0; fi
if [[ "\$1" == "api" ]]; then echo '{"total_count": 0, "runners": []}'; fi
exit 0
GH
chmod +x "$home/.local/bin/gh"
main_ci() { # <conclusion> -- the newest, completed CI run on main
  printf '[{"databaseId": 1, "headSha": "abc", "status": "completed", "conclusion": "%s", "url": "u"}]\n' \
    "$1" >"$work/ci.json"
}
main_ci success

# scenario <minutes in Todo> [fail_after] -- ABC-7 was created ten hours ago
# and entered Todo <minutes> before the real now. supervise.sh cannot pass
# starved.py a fixed --now, so the stamps follow the clock.
scenario() {
  python3 - "$work/scenario.json" "$1" "${2:-}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path, minutes, fail_after = sys.argv[1], float(sys.argv[2]), sys.argv[3]
now = datetime.now(timezone.utc)
stamp = lambda m: (now - timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
card = {
    "projectId": "project-1", "stateId": "state-todo",
    "identifier": "ABC-7", "priority": 2, "createdAt": stamp(600),
    "labels": {"nodes": []},
    "history": {"nodes": [
        {"createdAt": stamp(600), "toState": {"id": "state-backlog"}},
        {"createdAt": stamp(minutes), "toState": {"id": "state-todo"}},
    ]},
    "inverseRelations": {"nodes": []},
}
world = {"issues": [card]}
if fail_after:
    world["fail_after"] = int(fail_after)
json.dump(world, open(path, "w"))
PY
}

start_stub() {
  [[ -n "$STUB_PID" ]] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  exec 3< <(python3 "$stub" "$work/scenario.json")
  STUB_PID=$!
  read -r port <&3
  api_url="http://127.0.0.1:$port/graphql"
}

run() { # [VAR=value...] -- run mode, with extra environment
  env HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" STARVED_API_URL="$api_url" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=1 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 "$@" \
      "$supervise" 2>&1
}

# --- a: a three-hour tick, and a card two hours in Todo with free slots -------
reset; tick 3; scenario 120; start_stub
out="$(run)"
grep -qx 'tick-old' "$stopped" \
  && ok "a tick that outlived a waiting Todo card is asked to stop" \
  || bad "the starving tick was not asked to stop: $out"
grep -q 'foreman/tick' "$started" \
  && ok "and a replacement is started" \
  || bad "no replacement was started: $out"
grep -q 'starving a board: demo has 2 free slots and ABC-7 has waited 120m in Todo' <<<"$out" \
  && ok "and the log names the board and the card" \
  || bad "the log did not name the starved board and card: $out"

# --- b: the card entered Todo five minutes ago --------------------------------
reset; tick 3; scenario 5; start_stub
out="$(run)"
[[ ! -s "$stopped" && ! -s "$started" ]] \
  && ok "a card five minutes in Todo restarts nothing" \
  || bad "a fresh Todo card restarted the tick: $out"
grep -q 'healthy' <<<"$out" \
  && ok "and run mode calls the tick healthy" \
  || bad "run mode did not call the tick healthy: $out"

# --- c: the card is old, but the tick is twenty minutes old -------------------
reset; tick 0.33; scenario 120; start_stub
out="$(run)"
[[ ! -s "$stopped" && ! -s "$started" ]] \
  && ok "a tick younger than TICK_STARVED_MINUTES is not judged, so a replacement cannot loop" \
  || bad "a twenty-minute tick was restarted: $out"

# --- d: Linear answers HTTP 500 -----------------------------------------------
reset; tick 3; scenario 120 0; start_stub
out="$(run)"
[[ ! -s "$stopped" && ! -s "$started" ]] \
  && ok "a failed Linear read restarts nothing" \
  || bad "a failed Linear read restarted the tick: $out"
grep -q 'starved: could not read demo: .*500' <<<"$out" \
  && ok "and the log names the board it could not read" \
  || bad "the log did not name the unreadable board: $out"

# --- d2: main CI is red -------------------------------------------------------
# Found in review: SKILL.md step 0 stands a board with a red main down, so its
# Todo card waits by design. Judged starved, the tick was replaced once a window
# for as long as main stayed red.
reset; tick 3; scenario 120; start_stub; main_ci failure
out="$(run)"
[[ ! -s "$stopped" && ! -s "$started" ]] \
  && ok "a board whose main CI is red restarts nothing" \
  || bad "a red main restarted the tick: $out"
grep -q 'healthy' <<<"$out" \
  && ok "and run mode calls the tick healthy" \
  || bad "run mode did not call the tick healthy beside a red main: $out"
main_ci success

# --- e: a threshold inside the tick interval ----------------------------------
reset; tick 3; scenario 120; start_stub
out="$(run TICK_STARVED_MINUTES=20 TICK_INTERVAL_MINUTES=20)"; status=$?
if [[ "$status" -ne 0 && ! -s "$stopped" && ! -s "$started" ]] \
   && grep -q 'TICK_STARVED_MINUTES (20) must exceed TICK_INTERVAL_MINUTES (20)' <<<"$out"; then
  ok "TICK_STARVED_MINUTES not above TICK_INTERVAL_MINUTES is refused"
else
  bad "a starved threshold inside the interval was not refused (exit $status): $out"
fi

# --- f: each board is judged in its own environment ---------------------------
# supervise.sh sources config.sh for the board it resolves, which EXPORTS that
# board's REPO and KEY_FILE. Here that board is alpha, whose repository allows
# one slot. Leaked into demo's starved.py, alpha's REPO would make demo read
# alpha's board.toml, see its one held card as a full ceiling, and hide the
# starved card. alpha has no ids.env, so it has no verdict and is skipped.
alpha_repo="$work/alpha"
mkdir -p "$alpha_repo"
git -C "$alpha_repo" init -q -b main
fixture_board_toml "$alpha_repo"
printf '[limits]\nmax_concurrent = 1\n' >>"$alpha_repo/board.toml"
fixture_add_board "$home" alpha "$alpha_repo"
reset; tick 3; scenario 120; start_stub
out="$(run FOREMAN_INSTANCE=alpha)"
grep -q 'starved: could not read alpha: ' <<<"$out" \
  && ok "a board with no verdict is logged and the next board is still asked" \
  || bad "the unreadable board was not logged by name: $out"
grep -q 'starving a board: demo has 2 free slots and ABC-7' <<<"$out" && grep -qx 'tick-old' "$stopped" \
  && ok "the second board is judged on its own REPO, not the one supervise.sh resolved first" \
  || bad "a board variable from the first board answered for demo: $out"

exit "$fail"
