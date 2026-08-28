#!/usr/bin/env bash
# Keep exactly one healthy self-looping board tick agent alive.
#
#   supervise.sh            # cron entry point: start or restart as needed
#   supervise.sh --status   # report what it sees, change nothing
#   supervise.sh --stop     # stop the loop agent and leave it stopped
#
# THIS SCRIPT NEVER DISPATCHES A CARD. It starts an agent that runs `/board` on
# a loop, and that agent does all board work. The separation is the point: a
# watchdog able to dispatch would double-dispatch the moment it misjudged
# liveness, and misjudging liveness is exactly what a watchdog does under load.
#
# Why cron supervises a self-looping agent rather than firing each tick itself:
# a `claude --bg` invocation returns as soon as the agent is SPAWNED, not when
# the tick ends. Wrapping that in withlock.py would release the lock a second
# later while the tick still ran, so two cron fires could both pass the lock and
# both dispatch. Cron therefore never starts ticks — only the loop does — and
# this script's own check-and-spawn is synchronous, so a lock does hold across it.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SKILL_DIR/config.sh"

# Cron runs with PATH=/usr/bin:/bin and no profile. `claude` lives in
# ~/.local/bin, so without this the watchdog silently finds nothing to run and
# the board simply stops, with a log full of "command not found".
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin:$PATH"

# A dead-threshold at or below the interval marks a healthy waiting agent as
# dead and restarts it every pass, which looks like a crash loop and never ticks.
[[ "$TICK_DEAD_MINUTES" -gt "$TICK_INTERVAL_MINUTES" ]] \
  || die "TICK_DEAD_MINUTES ($TICK_DEAD_MINUTES) must exceed TICK_INTERVAL_MINUTES ($TICK_INTERVAL_MINUTES)"

MODE="${1:-run}"

log() { printf '%s supervise: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One JSON object describing the newest agent by our name, or an empty object.
# Health is judged on the transcript's mtime, the same evidence reconcile.py
# uses, because `state` alone cannot tell "waiting for the next tick" from
# "wedged mid-turn".
inspect() {
  claude agents --json --all 2>/dev/null | python3 -c '
import json,os,re,sys,time
want=sys.argv[1]
# Exit non-zero on an unreadable registry rather than returning "[]", which the
# caller cannot tell apart from "no agents are running" — and which it would
# answer by starting a second loop agent.
try: agents=json.load(sys.stdin)
except Exception: sys.exit(3)
# A registry that is not a LIST is not an empty one. `for a in agents` over a
# future {"agents": [...]} wrapper iterates its KEYS, matches nothing, prints
# "{}" and exits 0 -- which this script cannot tell from "no tick agent exists"
# and answers by starting a second loop agent beside a healthy one. Same check
# as reconcile.load_agents(), in the copy that can double-dispatch.
if not isinstance(agents,list): sys.exit(3)
mine=[a for a in agents if isinstance(a,dict) and a.get("name")==want]
if not mine:
    print("{}"); raise SystemExit
# --bg --resume forks and inherits the name, so several may share it. Newest wins.
a=max(mine, key=lambda x: x.get("startedAt") or 0)
cwd=a.get("cwd") or ""; sid=a.get("sessionId") or ""
idle=None
if cwd and sid:
    p=os.path.expanduser("~/.claude/projects/%s/%s.jsonl"%(re.sub(r"[/.]","-",cwd),sid))
    if os.path.exists(p): idle=round((time.time()-os.path.getmtime(p))/60,1)
started=a.get("startedAt") or 0
print(json.dumps({
  "id":a.get("id"), "sessionId":sid, "state":a.get("state"),
  "idle_minutes":idle,
  "age_hours": round((time.time()-started/1000)/3600,2) if started else None,
}))
' "$TICK_AGENT_NAME"
}

field() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) if sys.stdin else "")' "$2" 2>/dev/null || printf 'None'; }

stop_agent() {
  local id="$1"
  [[ -n "$id" && "$id" != "None" ]] || return 0
  if [[ -n "$BOARD_DRY_RUN" ]]; then log "DRY RUN: would stop $TICK_AGENT_NAME ($id)"; return 0; fi
  claude stop "$id" >/dev/null 2>&1 || true
  log "stopped $TICK_AGENT_NAME ($id)"
}

start_agent() {
  # NO INTERVAL. `/loop 20m /board` is fixed-interval cron mode, which polls and
  # never arms the agent Monitor — the polling design the event-driven board
  # replaced. This script said `/loop ${TICK_INTERVAL_MINUTES}m /board` for a
  # while after that change, so the durable path would silently have been the
  # old design while SKILL.md described the new one. TICK_INTERVAL_MINUTES is now
  # only the cadence this watchdog *expects* the loop to self-pace at, used for
  # the staleness thresholds below.
  local prompt="/loop /board"
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would start $TICK_AGENT_NAME: $prompt (model=$TICK_MODEL cwd=$REPO)"
    return 0
  fi
  # `--permission-mode` is non-variadic and sits immediately before the prompt,
  # for the same reason dispatch.sh does it: a variadic flag here eats the prompt
  # and produces an agent that starts and then waits at an empty prompt forever.
  ( cd "$REPO" && claude --bg \
      --name "$TICK_AGENT_NAME" \
      --model "$TICK_MODEL" \
      --permission-mode bypassPermissions \
      "$prompt" >/dev/null )
  log "started $TICK_AGENT_NAME: $prompt"
}

# `inspect` must not be allowed to fail the script or to look like "no agent".
#
# Two ways that went wrong. With `set -o pipefail`, a non-zero `claude agents`
# made this assignment fail and killed the watchdog before it logged anything —
# the same silent stand-down the lock fix removed. And an unreadable registry
# produced an empty object, which the decision below reads as "no tick agent
# exists" and answers by starting one. That is the worst outcome this script can
# produce: a second loop agent beside a healthy one, two ticks dispatching into
# the same slots.
#
# "I could not tell" is therefore its own answer, and the answer is do nothing.
if ! INFO="$(inspect)" || [[ -z "${INFO//[[:space:]]/}" ]]; then
  # `--status` is documented to answer with JSON on stdout, and something is
  # parsing it. Standing down with a prose log line here made it answer with
  # neither JSON nor a failing exit code, which reads as "there is no agent".
  if [[ "$MODE" == "--status" ]]; then
    printf '{"error":"could not read the agent registry"}\n'
    exit 1
  fi
  log "could not read the agent registry; standing down rather than guessing"
  exit 0
fi
STATE="$(field "$INFO" state)"
IDLE="$(field "$INFO" idle_minutes)"
AGE="$(field "$INFO" age_hours)"
ID="$(field "$INFO" id)"

if [[ "$MODE" == "--status" ]]; then
  printf '%s\n' "${INFO:-{\}}"
  exit 0
fi

if [[ "$MODE" == "--stop" ]]; then
  stop_agent "$ID"
  exit 0
fi

# Serialise check-and-spawn so two overlapping cron fires cannot both start an
# agent. Unlike a `--bg` dispatch this whole section is synchronous, so the lock
# genuinely covers the decision it is protecting.
# Create BOARD_HOME first. Nothing else does before the first tick exists, so on
# a fresh machine the redirect below failed, `flock` then failed on an unopened
# fd, and the `|| true` swallowed both — leaving a watchdog that logged "another
# supervisor holds the lock" and stood down on every single fire, forever. A
# board that never starts and says something reassuring is the worst outcome
# available here, so this no longer tolerates a failure to open the lock.
mkdir -p "$BOARD_HOME" || die "cannot create $BOARD_HOME"
exec 9>"$BOARD_HOME/supervise.lock" || die "cannot open $BOARD_HOME/supervise.lock"
# `! flock -n 9` is true both when the lock is held and when flock(1) does not
# exist — and macOS has no flock(1), which is the entire reason the sibling
# withlock.py exists. Reading "no such command" as "someone else is running"
# gives a watchdog that stands down forever on the platform it was never tested
# on, saying something reassuring each time. Establish the tool separately.
command -v flock >/dev/null 2>&1 \
  || die "flock(1) is not installed; this watchdog needs it (withlock.py covers the same gap elsewhere)"
# flock -n exits 1 when the lock is held. Any other non-zero is a failure of the
# tool, not a busy lock, and must not be reported as one — standing down on an
# error means a watchdog that never runs and always sounds fine.
# `flock -n 9; LOCK_RC=$?` does not work here: under `set -e` the failing flock
# aborts the script before the assignment runs, so neither branch below is ever
# reached. The `||` puts it in a condition context, which is what exempts it.
LOCK_RC=0
flock -n 9 || LOCK_RC=$?
if [[ $LOCK_RC -eq 1 ]]; then
  log "another supervisor holds the lock; standing down"
  exit 0
elif [[ $LOCK_RC -ne 0 ]]; then
  die "flock failed with exit $LOCK_RC; refusing to run unlocked"
fi

# Reasons to (re)start, most specific first. Each prints why, because a watchdog
# that restarts silently is indistinguishable from one that does nothing.
if [[ -z "$ID" || "$ID" == "None" ]]; then
  log "no $TICK_AGENT_NAME agent exists"
  start_agent
elif [[ "$STATE" == "stopped" ]]; then
  log "$TICK_AGENT_NAME is stopped"
  start_agent
elif [[ "$STATE" == "working" && "$IDLE" != "None" ]] \
     && awk "BEGIN{exit !($IDLE > $TICK_STALL_MINUTES)}"; then
  log "$TICK_AGENT_NAME wedged: mid-turn and silent for ${IDLE}m (> ${TICK_STALL_MINUTES}m)"
  stop_agent "$ID"; start_agent
elif [[ "$IDLE" != "None" ]] && awk "BEGIN{exit !($IDLE > $TICK_DEAD_MINUTES)}"; then
  log "$TICK_AGENT_NAME loop stopped rescheduling: idle ${IDLE}m (> ${TICK_DEAD_MINUTES}m)"
  stop_agent "$ID"; start_agent
elif [[ "$AGE" != "None" ]] && awk "BEGIN{exit !($AGE > $TICK_MAX_AGE_HOURS)}"; then
  log "recycling $TICK_AGENT_NAME to bound context: age ${AGE}h (> ${TICK_MAX_AGE_HOURS}h)"
  stop_agent "$ID"; start_agent
else
  log "$TICK_AGENT_NAME healthy (state=$STATE idle=${IDLE}m age=${AGE}h)"
fi
