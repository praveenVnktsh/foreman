#!/usr/bin/env bash
# Claim: `skills/board/starved.py` names a Todo card that has waited past the
# threshold on a board with a free slot, and says why for every board it does
# not call starved.
#
# The failure it prevents: on 2026-09-16 a tick alive for two hours stopped
# reading one board's Todo column. A card waited 30 minutes with 8 free slots
# until a manual `supervise.sh --restart`. Nothing in the repository could
# tell that tick from a board with no work, because both print nothing.
#
# It also pins the other direction. A halted board, a board at its ceiling, a
# blocked card, a main that is not green and a machine preflight calls unfit
# are the tick doing its job, and a restart there would only interrupt work. A
# Linear read that failed has no verdict at all: reported as "not starved", it
# is the incident's own silence. A waiting card past the first Todo page is
# still waiting: a first: 100 with no cursor used to hide it. A later page
# that fails is the same no-verdict rule, one page down.
#
# It drives the real script, and reconcile.py and queue.py under it, against a
# temporary FOREMAN_HOME. Linear is stubbed with tests/lib/linear-stub.py, and
# `gh` and `claude` with scripts on PATH; preflight.py runs for real against a
# local bare origin.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
starved="$root/skills/board/starved.py"
stub="$root/tests/lib/linear-stub.py"
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
# ids, and on the first run of this file they did win: MAX_CONCURRENT came from
# the real target's board.toml and the real Linear key file was read. Remove
# every name the fixture means to supply.
unset REPO KEY_FILE BOARD_HOME INSTANCE INSTANCE_HOME BOARD_NAME_PREFIX \
  BOARD_WORKTREE_PREFIX FOREMAN_ROOT MAX_CONCURRENT HOST_MAX_CONCURRENT \
  HOST_SLOT_STALE_MINUTES
for name in $(compgen -e); do
  case "$name" in STATE_*|LABEL_*|LINEAR_*) unset "$name" ;; esac
done

home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
origin="$work/origin"
mkdir -p "$repo"
git init -q --bare "$origin"
git init -q -b main "$repo"
fixture_board_toml "$repo"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q origin main
# Three slots, so one held card still leaves free ones.
printf '[limits]\nmax_concurrent = 3\n' >> "$repo/board.toml"
fixture_add_board "$home" demo "$repo"
board_dir="$fh/instances/demo"
printf 'LINEAR_PROJECT_ID=project-1\nSTATE_TO_PICK_UP=state-todo\n' > "$board_dir/ids.env"

# `gh run list` answers with $work/ci.json, the newest CI run on main. `gh api
# user` fails while $work/gh-dead exists, which fails preflight's gh check.
stubs="$work/bin"
mkdir -p "$stubs"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/claude"
cat > "$stubs/gh" <<GH
#!/usr/bin/env bash
if [[ "\$1" == "run" && "\$2" == "list" ]]; then cat "$work/ci.json"; exit 0; fi
if [[ "\$1" == "api" && "\$2" == "user" && -e "$work/gh-dead" ]]; then
  echo "HTTP 401: Requires authentication" >&2; exit 1
fi
if [[ "\$1" == "api" ]]; then echo '{"total_count": 0, "runners": []}'; exit 0; fi
exit 0
GH
chmod +x "$stubs/claude" "$stubs/gh"
main_ci() {  # $1 conclusion of the newest, completed CI run on main
  printf '[{"databaseId": 1, "headSha": "abc", "status": "completed", "conclusion": "%s", "url": "u"}]\n' \
    "$1" > "$work/ci.json"
}
main_ci success

now="2026-09-16T12:00:00Z"
minutes_before_now() {  # $1 minutes -> an ISO stamp in Linear's own format
  python3 -c '
import sys
from datetime import datetime, timedelta, timezone
now = datetime(2026, 9, 16, 12, 0, tzinfo=timezone.utc)
print((now - timedelta(minutes=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
' "$1"
}

hold_slot() {  # $1 ticket -> a card that holds a slot, stamped just now
  mkdir -p "$board_dir/cards/$1"
  printf '{"at":"%s","event":{"action":"spawn","name":"x","role":"review","attempt":"1"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$board_dir/cards/$1/history.jsonl"
}

# scenario <entered-minutes-ago> <blocker-state-type or ""> [fail_after]
# One Todo card, ABC-7, in the fixture project. It was created long ago and
# moved into Todo <entered-minutes-ago> before $now, so the history entry and
# not createdAt is what dates it.
scenario() {
  python3 - "$work/scenario.json" "$(minutes_before_now 600)" \
    "$(minutes_before_now "$1")" "$2" "${3:-}" <<'PY'
import json, sys
path, created, entered, blocker, fail_after = sys.argv[1:6]
relations = []
if blocker:
    relations.append({"type": "blocks",
                      "issue": {"identifier": "ABC-3", "state": {"type": blocker}}})
card = {
    "projectId": "project-1", "stateId": "state-todo",
    "identifier": "ABC-7", "priority": 2, "createdAt": created,
    "labels": {"nodes": []},
    "history": {"nodes": [
        {"createdAt": created, "toState": {"id": "state-backlog"}},
        {"createdAt": entered, "toState": {"id": "state-todo"}},
    ]},
    "inverseRelations": {"nodes": relations},
}
world = {"issues": [card]}
if fail_after:
    world["fail_after"] = int(fail_after)
with open(path, "w") as handle:
    json.dump(world, handle)
PY
}

# paged_scenario [fail_after]
# 100 Todo cards entered 10m ago (page one) and ABC-101 entered 90m ago
# (page two). Linear's first: 100 hid ABC-101 before PRA-461.
paged_scenario() {
  python3 - "$work/scenario.json" "$(minutes_before_now 600)" \
    "$(minutes_before_now 10)" "$(minutes_before_now 90)" "${1:-}" <<'PY'
import json, sys
path, created, recent, waiting, fail_after = sys.argv[1:6]
def card(ident, entered):
    return {
        "projectId": "project-1", "stateId": "state-todo",
        "identifier": ident, "priority": 2, "createdAt": created,
        "labels": {"nodes": []},
        "history": {"nodes": [
            {"createdAt": created, "toState": {"id": "state-backlog"}},
            {"createdAt": entered, "toState": {"id": "state-todo"}},
        ]},
        "inverseRelations": {"nodes": []},
    }
world = {"issues": [card(f"ABC-{n}", recent) for n in range(1, 101)]
                    + [card("ABC-101", waiting)]}
if fail_after:
    world["fail_after"] = int(fail_after)
with open(path, "w") as handle:
    json.dump(world, handle)
PY
}

# start_stub -- backgrounds the stub directly (not through a process
# substitution) so $! is python's own pid under bash 3.2, not a wrapper
# subshell's. A wrapper pid here would make `kill` miss python, and 1,353 of
# them were found still serving under PID 1 on this machine.
start_stub() {
  [[ -n "$STUB_PID" ]] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  local port_file="$work/stub.port"
  rm -f "$port_file"
  python3 "$stub" "$work/scenario.json" >"$port_file" 2>"$work/stub.err" &
  STUB_PID=$!
  local tries=0
  until [[ -s "$port_file" ]]; do
    tries=$((tries + 1))
    if [[ $tries -gt 100 ]]; then
      echo "FAIL: stub server never printed a port: $(cat "$work/stub.err")" >&2
      exit 1
    fi
    kill -0 "$STUB_PID" 2>/dev/null || {
      echo "FAIL: stub server exited early: $(cat "$work/stub.err")" >&2
      exit 1
    }
    sleep 0.05
  done
  api_url="http://127.0.0.1:$(cat "$port_file")/graphql"
}

# Prints starved.py's stdout and exits with its status; stderr lands in
# $work/err. $1 is the FOREMAN_INSTANCE, the rest is argv.
ask() {
  local instance="$1"; shift
  env HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE="$instance" PATH="$stubs:$PATH" \
    "$starved" "$@" --older-than 60 --api-url "$api_url" --now "$now" 2>"$work/err"
}

field() {  # $1 python expression over `v`, the parsed verdict; stdin is JSON
  python3 -c 'import json, sys; v = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

# --- a: free slots, a card in review, one card waiting 90 minutes -------------
hold_slot ABC-2
scenario 90 ""
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == True \
      && "$(field '[w["identifier"] for w in v["waiting"]]' <<<"$out")" == "['ABC-7']" \
      && "$(field 'v["waiting"][0]["waiting_minutes"]' <<<"$out")" == 90.0 ]]; then
  ok "a board with free slots and a card 90m in Todo is starved, naming the card"
else
  bad "a board with free slots and a card 90m in Todo is starved: status=$status out=$out $(cat "$work/err")"
fi
case "$(field 'v["reason"]' <<<"$out" 2>/dev/null)" in
  "demo has 2 free slots and ABC-7 has waited 90m in Todo") ok "the starved reason names the free slots and the card" ;;
  *) bad "the starved reason names the free slots and the card: out=$out" ;;
esac

# --- b: the same card entered Todo 10 minutes ago ----------------------------
scenario 10 ""
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False \
      && "$(field 'v["waiting"]' <<<"$out")" == "[]" ]]; then
  ok "a card 10m in Todo does not make the board starved"
else
  bad "a card 10m in Todo does not make the board starved: status=$status out=$out $(cat "$work/err")"
fi

# --- c: the card is blocked by an issue still in progress --------------------
scenario 90 started
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False ]]; then
  ok "a card blocked by a started issue is not waiting"
else
  bad "a card blocked by a started issue is not waiting: status=$status out=$out $(cat "$work/err")"
fi

# A blocker that is finished no longer blocks, so the card waits again.
scenario 90 completed
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == True ]]; then
  ok "a card whose blocker is completed is waiting"
else
  bad "a card whose blocker is completed is waiting: status=$status out=$out $(cat "$work/err")"
fi

# --- d: the board is halted --------------------------------------------------
scenario 90 ""
start_stub
touch "$board_dir/HALT"
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False \
      && "$(field 'v["reason"]' <<<"$out")" == *halted* ]]; then
  ok "a halted board is not starved"
else
  bad "a halted board is not starved: status=$status out=$out $(cat "$work/err")"
fi
rm -f "$board_dir/HALT"

# --- e: the board already holds MAX_CONCURRENT slots -------------------------
hold_slot ABC-4
hold_slot ABC-5
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False \
      && "$(field 'v["reason"]' <<<"$out")" == *"3 of its 3"*ceiling* ]]; then
  ok "a board at its ceiling is not starved, and the reason names the ceiling"
else
  bad "a board at its ceiling is not starved: status=$status out=$out $(cat "$work/err")"
fi
rm -rf "$board_dir/cards/ABC-4" "$board_dir/cards/ABC-5"

# --- e2: main CI is red, so step 0 stands the board down ----------------------
scenario 90 ""
start_stub
main_ci failure
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False \
      && "$(field 'v["reason"]' <<<"$out")" == *"main CI is red"* ]]; then
  ok "a board whose main CI is red is not starved, and the reason names main"
else
  bad "a board whose main CI is red is not starved: status=$status out=$out $(cat "$work/err")"
fi
main_ci success

# --- e3: preflight calls the machine unfit, so dispatch.sh refuses ------------
touch "$work/gh-dead"
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == False \
      && "$(field 'v["reason"]' <<<"$out")" == *unfit*"gh auth"* ]]; then
  ok "a board this machine is unfit to build is not starved, naming the failed check"
else
  bad "a board this machine is unfit to build is not starved: status=$status out=$out $(cat "$work/err")"
fi
rm -f "$work/gh-dead"

# --- f: Linear answers HTTP 500 ----------------------------------------------
scenario 90 "" 0
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 1 && -z "$out" && "$(cat "$work/err")" == starved:*500* ]]; then
  ok "a failed Linear read has no verdict: exit 1, empty stdout"
else
  bad "a failed Linear read has no verdict: status=$status out=$out $(cat "$work/err")"
fi

# --- g: the board named is not the board FOREMAN_INSTANCE resolves ------------
scenario 90 ""
start_stub
fixture_add_board "$home" other "$repo"
out="$(ask demo other)"; status=$?
if [[ "$status" -eq 2 && -z "$out" ]]; then
  ok "a board other than the resolved FOREMAN_INSTANCE is refused with exit 2"
else
  bad "a board other than the resolved FOREMAN_INSTANCE is refused: status=$status out=$out $(cat "$work/err")"
fi

out="$(ask nosuch nosuch)"; status=$?
if [[ "$status" -eq 2 && -z "$out" ]]; then
  ok "an undeclared board is refused with exit 2"
else
  bad "an undeclared board is refused: status=$status out=$out $(cat "$work/err")"
fi

# --- h: a waiting card after the first page of 100 -----------------------------
paged_scenario
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 0 && "$(field 'v["starved"]' <<<"$out")" == True \
      && "$(field '[w["identifier"] for w in v["waiting"]]' <<<"$out")" == "['ABC-101']" \
      && "$(field 'v["waiting"][0]["waiting_minutes"]' <<<"$out")" == 90.0 ]]; then
  ok "a waiting card after the first Todo page makes the board starved"
else
  bad "a waiting card after the first Todo page makes the board starved: status=$status out=$out $(cat "$work/err")"
fi

# --- i: a later Todo page that fails has no verdict -----------------------------
paged_scenario 1
start_stub
out="$(ask demo demo)"; status=$?
if [[ "$status" -eq 1 && -z "$out" && "$(cat "$work/err")" == starved:*page*2* ]]; then
  ok "a failed later Todo page has no verdict: exit 1, empty stdout"
else
  bad "a failed later Todo page has no verdict: status=$status out=$out $(cat "$work/err")"
fi

exit "$fail"
