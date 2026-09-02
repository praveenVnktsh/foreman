#!/usr/bin/env bash
# Keep exactly one healthy self-looping board tick agent alive.
#
#   supervise.sh            # cron entry point: start or restart as needed
#   supervise.sh --status   # report what it sees, change nothing
#   supervise.sh --stop     # stop the loop agent and leave it stopped
#   supervise.sh --restart  # replace the tick, leaving in-flight cards alone
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
INSTALL_ROOT="$(dirname -- "$(dirname -- "$SKILL_DIR")")"

# There is ONE tick for this machine, walking every board a slice at a time, so
# this watchdog is no longer run once per board and needs no board of its own.
#
# It still sources config.sh, which requires a board, because every knob it
# reads -- TICK_AGENT_NAME, TICK_MODEL and the four staleness thresholds --
# describes the machine's tick and not any one board, and duplicating them here
# would be a second copy that drifts. Any declared board yields the same values,
# so it takes the first one. If the operator named a board explicitly, that is
# honoured instead; it changes nothing but keeps the old invocation working.
#
# No boards declared means nothing to supervise. Stand down quietly rather than
# starting a tick that would wake up with no work forever.
if [[ -z "${FOREMAN_INSTANCE:-}" ]]; then
  # `|| true` is load-bearing under `set -euo pipefail`: boards.py exits
  # non-zero when boards.toml is missing, which is the ordinary state of a
  # machine that has declared nothing yet. Without it the watchdog dies here
  # with no message at all, and cron mails an empty failure every ten minutes.
  _first_board="$("$INSTALL_ROOT/bin/boards.py" --list 2>/dev/null | tr '\0' '\n' | head -1 || true)"
  if [[ -z "$_first_board" ]]; then
    printf '%s supervise: no boards declared; nothing to supervise\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
  fi
  FOREMAN_INSTANCE="$_first_board"
  export FOREMAN_INSTANCE
  unset _first_board
fi

# shellcheck source=config.sh
source "$SKILL_DIR/config.sh"

# The lock is MACHINE-level, not board-level, and that is load-bearing now.
# It used to be $BOARD_HOME/supervise.lock, which was right when each board had
# its own tick. With one tick for every board, two cron fires that resolved
# different boards would take two different locks, both see no tick, and both
# start one -- two ticks dispatching into the same slots, which is the exact
# failure this lock exists to prevent.
SUPERVISE_LOCK="${SUPERVISE_LOCK:-$FOREMAN_HOME/supervise.lock}"

# The tick's own control plane, and it must be foreman's rather than inherited.
#
# Claude Code resolves MCP servers PER PROJECT, keyed on the working directory.
# The tick runs from the install directory and serves every board, so it inherits
# no target's servers -- measured on a real host on 2026-09-01, where the Linear
# server was configured against one checkout and the tick, started elsewhere,
# reported "No MCP servers configured" and could not move a single card. It read
# the board correctly and then had no write path at all.
#
# Inheriting the working directory's servers would be worse, not better: which
# servers the board may use would then depend on which directory it happened to
# start in, and a target repository could hand the tick a server of its choosing.
# One file, owned by this installation, next to the credential it already owns.
MCP_CONFIG="${MCP_CONFIG:-$FOREMAN_HOME/mcp.json}"
MCP_ARGS=()
[[ -r "$MCP_CONFIG" ]] && MCP_ARGS=(--mcp-config "$MCP_CONFIG")

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

# The usage block in this file's own header is the only copy. A second one in a
# here-doc drifts the day a mode is added, and the operator who just mistyped a
# flag is then shown the older of the two.
usage() { sed -n 's/^#   \(supervise\.sh.*\)/  \1/p' "${BASH_SOURCE[0]}"; }

# Refuse an argument this script does not know, rather than running it.
# `MODE="${1:-run}"` on its own sent every typo -- `--restrat` -- into run mode,
# which starts or restarts a tick the operator was not asking about. The flags
# most likely to be mistyped are the two that change the most.
case "$MODE" in
  run|--status|--stop|--restart) ;;
  *)
    printf 'foreman: supervise.sh: unrecognised argument %s\n' "$MODE" >&2
    usage >&2
    exit 2
    ;;
esac

# How often a drain or a start-confirmation re-reads the registry. A grain, not
# a policy: the bounds it is counted against are TICK_DRAIN_SECONDS and
# TICK_START_TIMEOUT_SECONDS, which are the knobs an operator sets.
POLL_SECONDS=3

# The next wait: the grain, or whatever is left of the bound when that is less.
# Sleeping the grain unclamped makes a bound the operator set to 1 take 3, so a
# restart tuned tight for a test or an incident waits three times as long as it
# was told to and reports the number it was told, not the number it waited.
poll_step() { # <seconds already waited> <bound>
  local left=$(( $2 - $1 ))
  if [[ "$left" -lt "$POLL_SECONDS" ]]; then printf '%s' "$left"; else printf '%s' "$POLL_SECONDS"; fi
}

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

# Read the registry into INFO, STATE, IDLE, AGE and ID. Returns 1 and sets
# nothing when the registry cannot be read.
#
# `inspect` must not be allowed to fail the script or to look like "no agent".
#
# Two ways that went wrong. With `set -o pipefail`, a non-zero `claude agents`
# made this assignment fail and killed the watchdog before it logged anything --
# the same silent stand-down the lock fix removed. And an unreadable registry
# produced an empty object, which the run-mode decision reads as "no tick agent
# exists" and answers by starting one. That is the worst outcome this script can
# produce: a second loop agent beside a healthy one, two ticks dispatching into
# the same slots.
#
# "I could not tell" is therefore its own answer, and every caller answers it
# differently. Run and --stop stand down. A drain stops the tick anyway, because
# stopping it is safe. A start-confirmation keeps polling until it times out,
# because a restart may never report success on evidence it does not have.
read_registry() {
  local info
  info="$(inspect)" || return 1
  [[ -n "${info//[[:space:]]/}" ]] || return 1
  INFO="$info"
  STATE="$(field "$INFO" state)"
  IDLE="$(field "$INFO" idle_minutes)"
  AGE="$(field "$INFO" age_hours)"
  ID="$(field "$INFO" id)"
}

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
    log "DRY RUN: would start $TICK_AGENT_NAME: $prompt (model=$TICK_MODEL cwd=$INSTALL_ROOT mcp=${MCP_ARGS[1]:-none})"
    return 0
  fi
  # `--permission-mode` is non-variadic and sits immediately before the prompt,
  # for the same reason dispatch.sh does it: a variadic flag here eats the prompt
  # and produces an agent that starts and then waits at an empty prompt forever.
  #
  # `exec 9>&-` FIRST, inside this subshell only: fd 9 is the flock on
  # supervise.lock, opened with a plain `exec 9>...` below, which bash does not
  # mark close-on-exec. Left open, `claude --bg`'s own process -- and, through
  # it, the DETACHED agent process that outlives `claude --bg` returning --
  # inherits the fd and the flock with it. That agent runs for hours, so the
  # lock would then read as held by a live process for exactly that long, and
  # every supervise.sh fire in between reads `flock -n 9` failing as "another
  # supervisor holds the lock" and stands down -- a watchdog that silently
  # never runs again after its first successful start, on a lock nothing is
  # actually contending for. Closing it here, in a subshell, drops it only for
  # `claude` and whatever it forks; the parent script's own fd 9 (and the
  # flock on it) is untouched and still released the ordinary way, when this
  # script's own process exits.
  ( exec 9>&-
    # The tick serves every board, so there is no single repository to start it
    # in. It runs from the install and cds per board inside its own slices.
    #
    # ORDER IS LOAD-BEARING, same rule dispatch.sh documents: `--mcp-config` is
    # VARIADIC, so anything after it is eaten as another config path. Keep the
    # non-variadic `--permission-mode` immediately before the prompt.
    cd "$INSTALL_ROOT" && claude --bg \
      --name "$TICK_AGENT_NAME" \
      --model "$TICK_MODEL" \
      ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
      --permission-mode bypassPermissions \
      "$prompt" >/dev/null )
  log "started $TICK_AGENT_NAME: $prompt"
}

# Every live per-card agent on this machine, one "<name><TAB><state>" per line.
# A card agent is any `foreman/` name in the registry that is not the tick.
#
# A restart must leave all of them running, which is only true because
# dispatch.sh parents each one to the shared `claude daemon` rather than to the
# tick. They are listed before and after so an operator can read the log and see
# for themselves that the restart touched nothing it should not have.
card_agents() {
  claude agents --json --all 2>/dev/null | python3 -c '
import json,sys
tick=sys.argv[1]
# Same refusal as inspect(), for a different reason: an unreadable or non-list
# registry that printed nothing would read as "no cards were in flight", which
# tells the operator a restart was harmless when it may have run beside a dozen
# live builds.
try: agents=json.load(sys.stdin)
except Exception: sys.exit(3)
if not isinstance(agents,list): sys.exit(3)
for a in agents:
    if not isinstance(a,dict): continue
    name=a.get("name") or ""
    state=a.get("state") or "?"
    # A stopped agent is not in flight. It is a finished build the sweep has not
    # reaped yet, and listing it would make the second list look identical
    # forever -- exactly the evidence this listing exists to provide.
    if state=="stopped": continue
    if name.startswith("foreman/") and name!=tick: print("%s\t%s"%(name,state))
' "$TICK_AGENT_NAME"
}

log_cards() { # <when> <card_agents listing>
  local when="$1" listing="$2" line
  if [[ -z "${listing//[[:space:]]/}" ]]; then
    log "$when: no card agents are running"
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    log "$when: card agent ${line%%$'\t'*} (${line#*$'\t'})"
  done <<<"$listing"
}

# Wait for the tick to finish the turn it is in, up to TICK_DRAIN_SECONDS.
#
# Stopping it mid-turn is SAFE -- the tick holds no state and its replacement
# re-derives every card's position from Linear, gh and git -- so this is not a
# correctness bound. It exists so a restart does not routinely cut a
# half-finished merge or dispatch in two and leave the next person reading a
# transcript that stops mid-sentence.
drain_tick() {
  if [[ "$STATE" != "working" ]]; then
    log "drain: $TICK_AGENT_NAME is not mid-turn (state=$STATE); nothing to drain"
    return 0
  fi
  local waited=0 step
  while [[ "$waited" -lt "$TICK_DRAIN_SECONDS" ]]; do
    step="$(poll_step "$waited" "$TICK_DRAIN_SECONDS")"
    sleep "$step"
    waited=$(( waited + step ))
    if ! read_registry; then
      log "drain: the agent registry went unreadable after ${waited}s; stopping $TICK_AGENT_NAME anyway"
      return 0
    fi
    if [[ "$STATE" != "working" ]]; then
      log "drain: $TICK_AGENT_NAME finished its turn after ${waited}s"
      return 0
    fi
  done
  log "drain: $TICK_AGENT_NAME is still working after ${TICK_DRAIN_SECONDS}s; stopping it mid-turn, which is safe"
}

# Poll until a tick whose id DIFFERS from the one just stopped is in the
# registry, or die naming the failure.
#
# `claude --bg` returns as soon as the agent is spawned, so the "started" line
# start_agent() prints is not evidence that a tick exists. A restart is the one
# gesture that must not report success on faith: the operator has just been told
# the board is back, so nobody looks again until the next timer fire.
confirm_started() { # <id of the tick that was stopped>
  local old_id="$1" waited=0 step
  while :; do
    # A DIFFERENT id, not merely a present one. `claude stop` is not
    # instantaneous, so the agent just stopped can still be in the registry
    # under the same name, and matching the name alone confirms the corpse.
    if read_registry && [[ -n "$ID" && "$ID" != "None" && "$ID" != "$old_id" ]]; then
      log "confirmed: $TICK_AGENT_NAME is up ($ID) after ${waited}s"
      return 0
    fi
    [[ "$waited" -lt "$TICK_START_TIMEOUT_SECONDS" ]] || break
    step="$(poll_step "$waited" "$TICK_START_TIMEOUT_SECONDS")"
    sleep "$step"
    waited=$(( waited + step ))
  done
  die "$TICK_AGENT_NAME did not appear in the agent registry within ${TICK_START_TIMEOUT_SECONDS}s of starting it; the board is stopped until the next timer fire"
}

# --restart: replace the tick and leave every card agent alone.
#
# The tick is the only thing stopped, by id and by exact name, never by prefix.
# `foreman/tick` is a prefix of nothing, but every per-card name begins
# `foreman/<board>/`, so a prefix stop here would kill every build on the
# machine -- the one failure this whole mode exists to avoid.
restart_tick() {
  local old_id="$ID" before_cards after_cards after_names line name

  if ! before_cards="$(card_agents)"; then
    # Nothing has been stopped yet, so refusing costs the operator only a retry.
    # A restart that cannot say what was in flight is one nobody can audit.
    die "cannot read the card agents out of the registry; refusing to restart the tick blind"
  fi
  log_cards "before restart" "$before_cards"

  if [[ -z "$old_id" || "$old_id" == "None" ]]; then
    # A restart with no tick running is still a restart. Skip the drain and the
    # stop, and say so: an operator who typed --restart because the board looked
    # dead has just learnt why it looked dead.
    log "no $TICK_AGENT_NAME agent was running; starting one"
  elif [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would wait up to ${TICK_DRAIN_SECONDS}s for $TICK_AGENT_NAME ($old_id) to finish its turn"
  else
    drain_tick
  fi

  stop_agent "$old_id"
  start_agent

  if [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would wait up to ${TICK_START_TIMEOUT_SECONDS}s for the replacement $TICK_AGENT_NAME to appear in the registry"
  else
    confirm_started "$old_id"
  fi

  if ! after_cards="$(card_agents)"; then
    log "after restart: could not read the card agents; the replacement tick is up regardless"
    return 0
  fi
  log_cards "after restart" "$after_cards"
  after_names="$(printf '%s\n' "$after_cards" | cut -f1)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%$'\t'*}"
    if ! printf '%s\n' "$after_names" | grep -qxF -- "$name"; then
      # Benign, and said out loud so nobody reads it as collateral damage.
      log "after restart: $name is gone; it finished during the restart, and a build completing is not a disturbance"
    fi
  done <<<"$before_cards"
}

# --status is the ONE mode that reads the registry without the lock, because it
# changes nothing. Making it queue would make the gesture an operator reaches
# for during an incident the one that hangs behind a running start.
if [[ "$MODE" == "--status" ]]; then
  if ! read_registry; then
    # `--status` is documented to answer with JSON on stdout, and something is
    # parsing it. Standing down with a prose log line here made it answer with
    # neither JSON nor a failing exit code, which reads as "there is no agent".
    printf '{"error":"could not read the agent registry"}\n'
    exit 1
  fi
  printf '%s\n' "$INFO"
  exit 0
fi

# Serialise the whole mutating gesture -- read the registry, decide, stop, start
# -- so two overlapping fires cannot both act on it. Unlike a `--bg` dispatch
# this section is synchronous, so the lock genuinely covers the decision it is
# protecting.
#
# THE LOCK IS TAKEN BEFORE THE REGISTRY IS READ. Do not move it back below the
# read. --stop used to read the registry and call `claude stop` entirely outside
# the lock, so a timer fire could interleave with it: the fire saw a wedged
# tick, stopped it and started a fresh one, while --stop stopped the id it had
# read a moment earlier -- already dead -- and exited 0 with a tick still
# running. "stop ticking" that does not stop ticking, reported as success.
# --restart reads the same registry and would lose the same race.

# Create BOARD_HOME first. Nothing else does before the first tick exists, so on
# a fresh machine the redirect below failed, `flock` then failed on an unopened
# fd, and the `|| true` swallowed both — leaving a watchdog that logged "another
# supervisor holds the lock" and stood down on every single fire, forever. A
# board that never starts and says something reassuring is the worst outcome
# available here, so this no longer tolerates a failure to open the lock.
mkdir -p "$(dirname -- "$SUPERVISE_LOCK")" || die "cannot create $(dirname -- "$SUPERVISE_LOCK")"
exec 9>"$SUPERVISE_LOCK" || die "cannot open $SUPERVISE_LOCK"
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

if ! read_registry; then
  log "could not read the agent registry; standing down rather than guessing"
  exit 0
fi

if [[ "$MODE" == "--stop" ]]; then
  stop_agent "$ID"
  exit 0
fi

if [[ "$MODE" == "--restart" ]]; then
  restart_tick
  exit 0
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
