#!/usr/bin/env bash
# Claim: `reconcile.py` tells a spawn the model refused apart from every other
# death, names the model each agent ran on, and reports a run of voids.
#
# The failure this prevents: on 2026-09-16 the plan stage ran on a model that
# was rate-limited for 11 hours. Every plan spawn died at once on an API 429,
# the tick read each death as an ordinary failure, and no card moved. The tick
# can only fall back a tier if the record says three things:
#   - `death.rate_limited`, true only for a rate-limit or capacity error from
#     an agent that never ran a tool. An ordinary API error, or a limit hit by
#     an agent that did real work, must stay false, or a ticket's own failure
#     is retried on a weaker model and hidden.
#   - `agent.model`, from the spawn entry, so the tick marks the model that was
#     refused and not the stage's first choice.
#   - `environmental_streak`, so a card voiding pass after pass reaches the
#     tick's report instead of looping silently.
#
# It drives the real `reconcile.py` and the real harness adapter. Only `gh`
# (the pull request) and `claude` (the agent registry) are stubbed; the
# transcripts are files where the adapter says Claude keeps them.
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

stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/gh" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
# The registry is whatever the test last wrote to agents.json.
cat > "$stubs/claude" <<SH
#!/usr/bin/env bash
cat "$work/agents.json"
SH
chmod +x "$stubs/gh" "$stubs/claude"
printf '[]\n' > "$work/agents.json"

export HOME="$work" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo
# shellcheck source=../skills/board/config.sh
. "$root/skills/board/config.sh"

# One stopped plan agent per ticket, its transcript written from stdin at the
# path the claude adapter reports for its cwd and session.
stopped_agent() {  # $1 ticket; transcript rows on stdin
  local ticket="$1" cwd="/wt/$1" slug
  slug="$(printf '%s' "$cwd" | tr './' '--')"
  mkdir -p "$HOME/.claude/projects/$slug"
  cat > "$HOME/.claude/projects/$slug/s-$ticket.jsonl"
  python3 - "$work/agents.json" "$BOARD_NAME_PREFIX/$ticket/plan-1" "$cwd" "s-$ticket" <<'PY'
import json, sys
path, name, cwd, session = sys.argv[1:]
agents = json.load(open(path))
agents.append({"name": name, "id": session, "sessionId": session, "pid": None,
               "state": "stopped", "startedAt": 1, "cwd": cwd, "status": None})
json.dump(agents, open(path, "w"))
PY
}

record() {  # $1 ticket, $2 python expression over `r` (the card's record)
  PATH="$stubs:$PATH" "$root/skills/board/reconcile.py" "$1" \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)[0]
print(json.dumps(eval(sys.argv[1])))
' "$2"
}

is() {  # $1 name, $2 wanted, $3 got
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1: wanted [$2], got [$3]"
}

death='r["agents"][0]["death"]["rate_limited"]'

# --- a refused spawn is rate-limited ----------------------------------------
stopped_agent PRA-10 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Number of requests has exceeded your rate limit\"}}"}]}}
ROWS
is "a spawn refused with a 429 before any tool is rate-limited" true "$(record PRA-10 "$death")"
is "and the error text is carried for the card comment" true \
  "$(record PRA-10 '"429" in (r["agents"][0]["death"]["rate_limit_error"] or "")')"

stopped_agent PRA-11 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}]}}
ROWS
is "a spawn refused as overloaded (529) is rate-limited" true "$(record PRA-11 "$death")"

# --- everything else is not --------------------------------------------------
stopped_agent PRA-12 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git log -1"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"abc"}]}}
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 429 rate_limit_error"}]}}
ROWS
is "an agent that ran a tool before the 429 is not rate-limited" false "$(record PRA-12 "$death")"

# A limit the agent waited out is not a refused spawn: it went on to work, so
# whatever killed it later may be the ticket's.
stopped_agent PRA-15 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 429 rate_limit_error"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git log -1"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"abc"}]}}
ROWS
is "an agent that ran a tool after a 429 is not rate-limited" false "$(record PRA-15 "$death")"

stopped_agent PRA-13 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","isApiErrorMessage":true,"error":"invalid_request","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long\"}}"}]}}
ROWS
is "an ordinary API error with no tools is not rate-limited" false "$(record PRA-13 "$death")"

stopped_agent PRA-14 <<'ROWS'
{"type":"user","message":{"role":"user","content":"plan the card"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr create"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Posted the plan. Hit no rate limit (429) today."}]}}
ROWS
is "a finished agent that mentions a 429 in prose is not rate-limited" false "$(record PRA-14 "$death")"

# --- the agent's model comes from its newest spawn ---------------------------
card_log PRA-10 "{\"action\":\"spawn\",\"name\":\"$BOARD_NAME_PREFIX/PRA-10/plan-1\",\"role\":\"plan\",\"attempt\":\"1\",\"model\":\"fable\",\"first_choice\":\"fable\"}"
card_log PRA-10 "{\"action\":\"spawn\",\"name\":\"$BOARD_NAME_PREFIX/PRA-10/plan-1\",\"role\":\"plan\",\"attempt\":\"1\",\"model\":\"opus\",\"first_choice\":\"fable\"}"
is "an agent's model is the model of its newest spawn" '"opus"' \
  "$(record PRA-10 'r["agents"][0]["model"]')"
is "an agent spawned before models were recorded has none" null \
  "$(record PRA-13 'r["agents"][0]["model"]')"

# --- environmental_streak ----------------------------------------------------
#
# Written line by line with distinct stamps, in card_log's shape, so `since`
# can be told apart from the newest void.
history_of() {  # $1 ticket; `<at> <event json>` lines on stdin
  local dir="$BOARD_HOME/cards/$1" at event
  rm -rf "$dir"; mkdir -p "$dir"
  while read -r at event; do
    printf '{"at":"%s","event":%s}\n' "$at" "$event" >> "$dir/history.jsonl"
  done
}

history_of PRA-20 <<'H'
2026-09-16T01:00:00Z {"action":"spawn","role":"plan","attempt":"1","model":"fable"}
2026-09-16T01:01:00Z {"action":"fallback","role":"plan","model":"fable","until":"2026-09-16T02:01:00Z","next":"opus"}
2026-09-16T01:01:00Z {"action":"void","role":"plan","attempt":"1","reason":"first"}
2026-09-16T01:02:00Z {"action":"spawn","role":"plan","attempt":"1","model":"opus"}
2026-09-16T01:10:00Z {"action":"void","role":"plan","attempt":"1","reason":"second"}
2026-09-16T01:11:00Z {"action":"resume","name":"x","session":"s"}
2026-09-16T01:20:00Z {"action":"void","role":"plan","attempt":"1","reason":"third"}
H
is "three plan voids at the tail are a streak of three from the first" \
  '{"role": "plan", "count": 3, "since": "2026-09-16T01:01:00Z", "last_reason": "third"}' \
  "$(record PRA-20 'r["environmental_streak"]')"

# A fallback entry names a role, and one carrying an attempt label must still
# not count: only spawn and void entries are attempt arithmetic. Counted, every
# rate-limited pass would spend the plan budget the void just refunded.
history_of PRA-23 <<'H'
2026-09-16T01:00:00Z {"action":"spawn","role":"plan","attempt":"1","model":"fable"}
2026-09-16T01:01:00Z {"action":"fallback","role":"plan","attempt":"2","model":"fable","until":"2026-09-16T02:01:00Z","next":"opus"}
H
is "a fallback entry does not spend a plan attempt" 1 "$(record PRA-23 'r["plan_attempts"]')"

history_of PRA-21 <<'H'
2026-09-16T01:00:00Z {"action":"void","role":"plan","attempt":"1","reason":"first"}
2026-09-16T01:05:00Z {"action":"resume","role":"plan","round":"1"}
2026-09-16T01:06:00Z {"action":"posted","role":"plan"}
2026-09-16T01:07:00Z {"action":"void","role":"build","attempt":"1","reason":"other stage"}
2026-09-16T01:10:00Z {"action":"void","role":"plan","attempt":"2","reason":"latest"}
H
is "a non-void action for the role ends the run" \
  '{"role": "plan", "count": 1, "since": "2026-09-16T01:10:00Z", "last_reason": "latest"}' \
  "$(record PRA-21 'r["environmental_streak"]')"

history_of PRA-22 <<'H'
2026-09-16T01:00:00Z {"action":"void","role":"build","attempt":"1","reason":"disk"}
2026-09-16T01:05:00Z {"action":"released","reason":"done"}
H
is "a card whose history ends without a void has no streak" null \
  "$(record PRA-22 'r["environmental_streak"]')"

exit "$fail"
