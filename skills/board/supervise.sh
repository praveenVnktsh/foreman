#!/usr/bin/env bash
# Keep exactly one healthy self-looping board tick agent alive.
#
#   supervise.sh            # cron entry point: start or restart as needed
#   supervise.sh --status   # report what it sees, change nothing
#   supervise.sh --stop     # stop the loop agent and leave it stopped
#   supervise.sh --restart  # replace the tick, leaving in-flight cards alone
#
# THIS SCRIPT NEVER DISPATCHES A CARD. It starts an agent that runs the board
# skill on a loop, and that agent does all board work. The separation is the
# point: a watchdog able to dispatch would double-dispatch the moment it
# misjudged liveness, and misjudging liveness is exactly what a watchdog does
# under load.
#
# ONE TICK PER INSTALLATION, and this file supervises this installation's.
# Everything it runs the harness for goes through "$HARNESS_SH", the adapter
# config.sh picks from the installation's `harness`, so this script knows no
# CLI's flags. Its five verbs are in
# docs/specs/2026-09-14-installations-per-harness-design.md.
#
# Why cron supervises a self-looping agent rather than firing each tick itself:
# a spawn returns as soon as the agent is SPAWNED, not when the tick ends.
# Wrapping that in withlock.py would release the lock a second later while the
# tick still ran, so two cron fires could both pass the lock and both dispatch.
# Cron therefore never starts ticks — only the loop does — and this script's own
# check-and-spawn is synchronous, so a lock does hold across it.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname -- "$(dirname -- "$SKILL_DIR")")"

# WHAT THIS SCRIPT WAS ASKED TO DO, decided before anything else is resolved.
#
# This block sits above the board lookup on purpose. It used to sit below, so on
# a machine with no boards declared -- a fresh install, or one whose boards.toml
# has gone missing -- `supervise.sh --restrat` reached the "no boards declared"
# early exit first and answered a typo with the same reassuring exit 0 a correct
# invocation gets. Whether an argument is spelled correctly has nothing to do
# with how many boards exist, so it is no longer answered by them.
MODE="${1:-run}"

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

# There is ONE tick for this installation, walking every board it serves a
# slice at a time, so this watchdog is no longer run once per board and needs
# no board of its own.
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

log() { printf '%s supervise: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# The lock is INSTALLATION-level, not board-level, and that is load-bearing now.
# It used to be $BOARD_HOME/supervise.lock, which was right when each board had
# its own tick. With one tick for every board, two cron fires that resolved
# different boards would take two different locks, both see no tick, and both
# start one -- two ticks dispatching into the same slots, which is the exact
# failure this lock exists to prevent. A sibling installation has its own home
# and therefore its own lock, which is right: it supervises a different tick.
SUPERVISE_LOCK="${SUPERVISE_LOCK:-$FOREMAN_HOME/supervise.lock}"

# The tick's own control plane, and it must be foreman's rather than inherited.
#
# A harness resolves MCP servers PER PROJECT, keyed on the working directory.
# The tick runs from the install directory and serves every board, so it inherits
# no target's servers -- measured on a real host on 2026-09-01, where the Linear
# server was configured against one checkout and the tick, started elsewhere,
# reported "No MCP servers configured" and could not move a single card. It read
# the board correctly and then had no write path at all.
#
# Inheriting the working directory's servers would be worse, not better: which
# servers the board may use would then depend on which directory it happened to
# start in, and a target repository could hand the tick a server of its choosing.
#
# It lives at the ROOT, beside linear.key, because every installation on this
# machine serves the same Linear workspace through it. A copy per installation
# would be the same file written twice, and the second copy is the one nobody
# updates when the server moves.
MCP_CONFIG="${MCP_CONFIG:-$FOREMAN_ROOT/mcp.json}"
MCP_ARGS=()
[[ -r "$MCP_CONFIG" ]] && MCP_ARGS=(--mcp-config "$MCP_CONFIG")

# Cron runs with PATH=/usr/bin:/bin and no profile. The harness binary the
# adapter runs lives in ~/.local/bin, so without this the watchdog silently
# finds nothing to run and the board simply stops, with a log full of
# "command not found".
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin:$PATH"

# A dead-threshold at or below the interval marks a healthy waiting agent as
# dead and restarts it every pass, which looks like a crash loop and never ticks.
[[ "$TICK_DEAD_MINUTES" -gt "$TICK_INTERVAL_MINUTES" ]] \
  || die "TICK_DEAD_MINUTES ($TICK_DEAD_MINUTES) must exceed TICK_INTERVAL_MINUTES ($TICK_INTERVAL_MINUTES)"


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

field() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) if sys.stdin else "")' "$2" 2>/dev/null || printf 'None'; }

# One JSON object describing THE tick, or an empty object.
#
# "The tick" is the newest agent of our name that is NOT stopped, and only when
# there is none, the newest overall -- so an operator reading --status sees the
# agent that is actually running the board, and a stopped corpse with a later
# startedAt cannot masquerade as it. Picking the newest regardless of state was
# a real fault, not a cosmetic one: a live tick-0 behind a stopped tick-1 made
# run mode take its "the tick is stopped" branch and start a SECOND live tick.
#
# `live_ticks` counts them, because one is the only correct number and every
# caller has to be able to see that it is wrong.
#
# Health is judged on the transcript's mtime, the same evidence reconcile.py
# uses, because `state` alone cannot tell "waiting for the next tick" from
# "wedged mid-turn". WHERE that transcript is belongs to the harness, so the
# adapter is asked rather than the path being composed here: each of the three
# keeps its session somewhere different, and a path built here would be right
# for one installation and silently absent for its siblings -- which reads as
# "idle forever", the state run mode answers by replacing a healthy tick.
inspect() {
  local rows
  rows="$(tick_rows)" || return 3
  printf '%s\n' "$rows" | python3 -c '
import json,sys,time
rows=[l.split("\t") for l in sys.stdin.read().split("\n") if l]
if not rows:
    print("{}"); raise SystemExit
# A resume forks and inherits the name, so several may share it.
live=[r for r in rows if r[2]=="yes"]
r=max(live or rows, key=lambda r: int(r[4]))
started=int(r[4])
print(json.dumps({
  "id":r[0], "sessionId":r[5], "state":r[1],
  "idle_minutes": None if r[3]=="None" else float(r[3]),
  "age_hours": round((time.time()-started/1000)/3600,2) if started else None,
  "live_ticks": len(live),
}))
'
}

# EVERY agent named $TICK_AGENT_NAME, one row per line, tab-separated:
#
#   <id>  <state>  <alive: yes|no>  <idle minutes, or None>  <startedAt ms>  <sessionId>
#
# THE TICK IS A SET, and every gesture that changes it acts on the whole set.
# inspect() above collapses that set to one agent, which is what an operator
# wants to read and the wrong thing to stop: a restart that stopped only the
# agent inspect() named left every other live one running and reported success.
# Several agents can genuinely share the name -- inspect() records that
# `--bg --resume` forks inherit it, and run mode used to manufacture the state
# itself -- so this is the list every mutating path works from, and the ONE
# place that decides whether a row is alive.
#
# ALIVE IS NOT "NOT STOPPED". Measured 2026-09-14: a row from ten days earlier
# sat in the registry with `state: working`, no pid, and a transcript silent
# for 14112 minutes. A restart stopped the real tick, found that row, asked it
# to stop eight times over 30 seconds, and refused to start a replacement
# beside "a tick that is still live"; every timer fire after it did the same,
# and the board ran no tick until an operator archived the row by hand. A stop
# cannot land on a process that does not exist, so a row like that is a corpse,
# not a tick, and is neither waited for nor counted.
#
# The rule is deliberately narrow. sweep.sh records why a bare "no pid" test is
# dangerous -- the day a live agent is listed without one, that test kills it
# -- so a row is a corpse only when it has no pid AND its transcript is known
# and has been silent longer than TICK_DEAD_MINUTES, or is gone and the row is
# older than that. A row with a pid is alive whatever its transcript says; the
# wedged branch below handles it, by stopping a process that exists. A row
# whose transcript cannot be located (no cwd or session id) is alive: nothing
# is known against it.
#
# The rows come from the adapter's list, and each transcript path from its
# transcript verb, for the reason inspect() gives. On codex and opencode a row
# never reaches the corpse rule: that adapter owns the pid and already lists a
# row whose process is gone as stopped.
tick_rows() {
  "$HARNESS_SH" list 2>/dev/null | python3 -c '
import json,os,subprocess,sys,time
want, dead_minutes, harness = sys.argv[1], float(sys.argv[2]), sys.argv[3]
# Exit non-zero on an unreadable registry rather than returning nothing, which
# the caller cannot tell apart from "no agents are running" -- and which it
# would answer by starting a second loop agent.
try: agents=json.load(sys.stdin)
except Exception: sys.exit(3)
# A registry that is not a LIST is not an empty one. `for a in agents` over a
# future {"agents": [...]} wrapper iterates its KEYS, matches nothing, prints
# nothing and exits 0 -- which this script cannot tell from "no tick agent
# exists" and answers by starting a second loop agent beside a healthy one.
# Same check as reconcile.load_agents(), in the copy that can double-dispatch.
if not isinstance(agents,list): sys.exit(3)
now=time.time()
for a in agents:
    if not isinstance(a,dict) or a.get("name")!=want: continue
    cwd=a.get("cwd") or ""; sid=a.get("sessionId") or ""
    started=a.get("startedAt") or 0
    idle=None; transcript=None
    if cwd and sid:
        # The adapter says where this harness keeps the transcript. An answer it
        # cannot give leaves the transcript unknown, and an unknown transcript is
        # never evidence of death.
        try:
            p=subprocess.run([harness,"transcript",cwd,sid],capture_output=True,text=True,timeout=15).stdout.strip()
        except (OSError,subprocess.SubprocessError):
            p=""
        if p:
            transcript=os.path.exists(p)
            if transcript: idle=round((now-os.path.getmtime(p))/60,1)
    alive=a.get("state")!="stopped"
    if alive and not a.get("pid") and transcript is not None:
        silent = idle is not None and idle > dead_minutes
        gone = not transcript and started and (now-started/1000)/60 > dead_minutes
        if silent or gone: alive=False
    print("%s\t%s\t%s\t%s\t%s\t%s"%(a.get("id") or "?", a.get("state") or "?",
          "yes" if alive else "no", "None" if idle is None else idle, started, sid))
' "$TICK_AGENT_NAME" "$TICK_DEAD_MINUTES" "$HARNESS_SH"
}

# The ids in a listing that are alive, one per line.
live_tick_ids() { # <tick_rows listing>
  printf '%s\n' "$1" | awk -F'\t' '$1 != "" && $3 == "yes" { print $1 }'
}

# Name every corpse in the registry, once per fire, so an operator reading the
# log can see the row and archive it. Ignoring it silently would hide a
# registry that is wrong, which is the second half of what went wrong: the row
# had been there for ten days before a restart tripped over it.
log_corpse_ticks() {
  local rows
  rows="$(tick_rows)" || return 0
  printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $2 != "stopped" && $3 == "no" { print $1 "\t" $2 "\t" $4 }' \
  | while IFS=$'\t' read -r id state idle; do
      log "ignoring $TICK_AGENT_NAME ($id): the registry says $state, but it has no pid and its transcript is ${idle}m silent or gone; a stop cannot land on a process that does not exist. Archive the row."
    done
}

# Read the registry into INFO, STATE, IDLE, AGE and ID. Returns 1 and sets
# nothing when the registry cannot be read.
#
# `inspect` must not be allowed to fail the script or to look like "no agent".
#
# Two ways that went wrong. With `set -o pipefail`, a non-zero registry read
# made this assignment fail and killed the watchdog before it logged anything --
# the same silent stand-down the lock fix removed. And an unreadable registry
# produced an empty object, which the run-mode decision reads as "no tick agent
# exists" and answers by starting one. That is the worst outcome this script can
# produce: a second loop agent beside a healthy one, two ticks dispatching into
# the same slots.
#
# "I could not tell" is therefore its own answer, and every caller answers it
# differently. Run mode stands down, because a timer fire that does nothing is
# safe and the next one re-reads. --stop and --restart refuse, because nothing
# retries an operator's gesture. A drain stops the tick anyway, because stopping
# it is safe. The stop- and start-confirmations keep polling until they time
# out, because neither may report success on evidence it does not have.
read_registry() {
  local info
  info="$(inspect)" || return 1
  [[ -n "${info//[[:space:]]/}" ]] || return 1
  INFO="$info"
  STATE="$(field "$INFO" state)"
  IDLE="$(field "$INFO" idle_minutes)"
  AGE="$(field "$INFO" age_hours)"
  ID="$(field "$INFO" id)"
  LIVE_TICKS="$(field "$INFO" live_ticks)"
  [[ "$LIVE_TICKS" != "None" ]] || LIVE_TICKS=0
}

# Ask ONE tick to stop. stop_ticks() is the only caller and owns both the dry
# run and the proof that it worked.
stop_agent() {
  local id="$1"
  [[ -n "$id" && "$id" != "None" ]] || return 0
  # `|| true` because a non-zero exit here is not the answer. A stop is
  # asynchronous, it exits non-zero on an agent that was already gone, and it
  # can fail outright against a daemon that is restarting. What the tick
  # actually did is read back out of the registry by stop_ticks(), which is also
  # what re-issues this, so the line says what was ASKED and never that it
  # worked -- it used to log "stopped foreman/tick" over a stop that exited 1
  # and changed nothing, which is how a second tick came to be started beside a
  # live one.
  "$HARNESS_SH" stop "$id" >/dev/null 2>&1 \
    || log "stop $id exited non-zero; the confirmation below decides whether the tick went away"
  log "asked $TICK_AGENT_NAME ($id) to stop"
}

start_agent() {
  # THE LOOP IS THE ADAPTER'S CONCERN. `--loop-minutes` says the tick repeats
  # and how often, and each harness honours it the way it can: Claude loops
  # inside one session, so its adapter ignores the number, and the detached
  # harnesses re-run the prompt in detached.sh because their command returns
  # when the turn ends. Spelling the loop here instead is what went wrong
  # before: this script said `/loop ${TICK_INTERVAL_MINUTES}m /board`, which is
  # fixed-interval cron mode and never arms the agent Monitor, so the durable
  # path was the polling design the event-driven board had already replaced
  # while SKILL.md described the new one.
  local prompt prompt_file rc=0
  prompt="$("$HARNESS_SH" skill-prompt board --loop-minutes "$TICK_INTERVAL_MINUTES")"
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would start $TICK_AGENT_NAME: $prompt (model=$TICK_MODEL cwd=$INSTALL_ROOT mcp=${MCP_ARGS[1]:-none})"
    return 0
  fi
  # The adapter takes the prompt as a FILE, so that no harness's argument
  # parsing can swallow it -- the flag-order rule that used to live here, and
  # the agent-at-an-empty-prompt-box it prevents, are now in
  # skills/board/harness/claude.sh's header.
  prompt_file="$(mktemp "${TMPDIR:-/tmp}/foreman-tick-prompt.XXXXXX")" \
    || die "cannot create a temporary file for the tick prompt"
  printf '%s\n' "$prompt" >"$prompt_file"
  # `exec 9>&-` FIRST, inside this subshell only: fd 9 is the flock on
  # supervise.lock, opened with a plain `exec 9>...` below, which bash does not
  # mark close-on-exec. Left open, the adapter's own process -- and, through
  # it, the DETACHED agent process that outlives the spawn returning --
  # inherits the fd and the flock with it. That agent runs for hours, so the
  # lock would then read as held by a live process for exactly that long, and
  # every supervise.sh fire in between reads `flock -n 9` failing as "another
  # supervisor holds the lock" and stands down -- a watchdog that silently
  # never runs again after its first successful start, on a lock nothing is
  # actually contending for. Closing it here, in a subshell, drops it only for
  # the adapter and whatever it forks; the parent script's own fd 9 (and the
  # flock on it) is untouched and still released the ordinary way, when this
  # script's own process exits.
  #
  # The tick serves every board, so there is no single repository to start it
  # in. It runs from the install and cds per board inside its own slices.
  #
  # `--remote-control` is asked for HERE, at every start, because it belongs to
  # one session: a tick switched on by hand with `/remote-control` drops out of
  # the operator's app the next time this script replaces it, silently.
  ( exec 9>&-
    "$HARNESS_SH" spawn \
      --name "$TICK_AGENT_NAME" \
      --cwd "$INSTALL_ROOT" \
      --model "$TICK_MODEL" \
      --prompt-file "$prompt_file" \
      ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
      --remote-control \
      --skip-permissions \
      --loop-minutes "$TICK_INTERVAL_MINUTES" >/dev/null ) || rc=$?
  # Removed whatever happened: the adapter reads the file before it spawns, so
  # after this nothing needs it, and a failed spawn would otherwise leave one
  # behind in TMPDIR on every fire.
  rm -f "$prompt_file"
  [[ "$rc" -eq 0 ]] \
    || die "the $HARNESS adapter refused to start $TICK_AGENT_NAME (exit $rc); no tick is running"
  log "started $TICK_AGENT_NAME: $prompt"
}

# EVERY per-card agent of THIS INSTALLATION, stopped ones included, one
# "<name><TAB><state>" per line. A card agent is any `foreman/$NAME_SCOPE`
# name in the registry that is not the tick.
#
# The installation segment is what keeps a sibling's builds out of this
# listing. Two installations share one registry on a Claude machine, and a
# restart that reported a sibling's card agents would tell the operator this
# gesture had touched agents it cannot even stop.
#
# The legacy installation has no segment, so its prefix is `foreman/` and a
# scoped Claude sibling's card agents do appear in its listing. That is a
# display only: nothing here stops by prefix, and the tick is stopped by id.
#
# A restart must leave all of them running, which is only true because
# dispatch.sh parents each one to the harness rather than to the tick. They are
# listed before and after so an operator can read the log and see for
# themselves that the restart touched nothing it should not have.
#
# STOPPED ROWS ARE KEPT even though log_cards() does not print them. They used
# to be filtered out here, which erased the difference between an agent that
# left the registry and one that is sitting in it stopped -- so the after-restart
# report could only ever say "gone", and said it about an agent the restart had
# stopped as readily as about one that finished. Filtering is a display concern
# and belongs where the display is.
card_agents() {
  "$HARNESS_SH" list 2>/dev/null | python3 -c '
import json,sys
tick,prefix=sys.argv[1],sys.argv[2]
# Same guard as tick_rows(), for a different reason: an unreadable registry
# that arrived here as an empty listing would read as "no cards were in
# flight", which tells the operator a restart was harmless when it may have run
# beside a dozen live builds.
try: agents=json.load(sys.stdin)
except Exception: sys.exit(3)
if not isinstance(agents,list): sys.exit(3)
for a in agents:
    if not isinstance(a,dict): continue
    name=a.get("name") or ""
    state=a.get("state") or "?"
    if name.startswith(prefix) and name!=tick: print("%s\t%s"%(name,state))
' "$TICK_AGENT_NAME" "foreman/$NAME_SCOPE"
}

# Print the card agents that are IN FLIGHT. A stopped one is a finished build
# the sweep has not reaped yet; printing it would make the second listing look
# identical to the first forever, which is exactly the evidence this listing
# exists to provide.
log_cards() { # <when> <card_agents listing>
  local when="$1" listing="$2" line printed=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "${line#*$'\t'}" != "stopped" ]] || continue
    log "$when: card agent ${line%%$'\t'*} (${line#*$'\t'})"
    printed="yes"
  done <<<"$listing"
  [[ -n "$printed" ]] || log "$when: no card agents are running"
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

# Ask EVERY live tick to stop, and keep asking until the registry says none is
# left. Returns 0 when they are all gone and 1 when any survives the bound.
#
# It never dies. What to do about a tick that will not stop differs between an
# operator's gesture, which nothing retries, and a timer fire, which retries in
# TICK_INTERVAL_MINUTES -- so the decision belongs to the caller.
#
# THE STOP IS RE-ISSUED ON EVERY POLL, not once at the top. A stop is
# asynchronous and it can fail outright, and the agent whose stop is slowest to
# land is exactly the wedged one run mode exists to replace, so a single attempt
# followed by a wait gave up on the one case that matters most.
#
# EVERY live tick, not the one inspect() named. Stopping only that one left any
# other live agent of the same name running, and the caller then started a
# replacement beside it -- two ticks running this installation's board loop
# against one machine-wide HOST_MAX_CONCURRENT, which is the double-dispatch this script
# exists to prevent.
stop_ticks() {
  local waited=0 step listing ids id attempted=""
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would stop every live $TICK_AGENT_NAME ($(surviving_tick_ids)) and wait up to ${TICK_STOP_TIMEOUT_SECONDS}s for the registry to agree"
    return 0
  fi
  while :; do
    if listing="$(tick_rows)"; then
      ids="$(live_tick_ids "$listing")"
      if [[ -z "${ids//[[:space:]]/}" ]]; then
        [[ -z "$attempted" ]] || log "confirmed: no $TICK_AGENT_NAME agent is running after ${waited}s"
        return 0
      fi
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        stop_agent "$id"
        attempted="yes"
      done <<<"$ids"
    fi
    # An unreadable registry is not "they are all gone". It keeps polling, and
    # the caller decides what the timeout means.
    [[ "$waited" -lt "$TICK_STOP_TIMEOUT_SECONDS" ]] || break
    step="$(poll_step "$waited" "$TICK_STOP_TIMEOUT_SECONDS")"
    sleep "$step"
    waited=$(( waited + step ))
  done
  return 1
}

# The live tick ids still in the registry, space-separated, for an error message.
surviving_tick_ids() {
  local listing
  listing="$(tick_rows)" || { printf 'unknown (the registry is unreadable)'; return 0; }
  live_tick_ids "$listing" | tr '\n' ' ' | sed 's/ *$//'
}

# Poll until the registry holds EXACTLY ONE live tick and it is not one of the
# ids just stopped, or die naming the failure.
#
# A spawn returns as soon as the agent is registered, so the "started" line
# start_agent() prints is not evidence that a tick exists. A restart is the one
# gesture that must not report success on faith: the operator has just been told
# the board is back, so nobody looks again until the next timer fire.
#
# EXACTLY ONE, not "one that is not the id we stopped". A registry holding two
# live ticks satisfied that weaker test with a SURVIVOR: it reported
# `confirmed: foreman/tick is up (tick-0)` while the replacement had never
# spawned at all, and the operator who had just pulled new install code was told
# the restart worked. One is the only correct number of ticks on a machine, so
# it is the number this checks.
confirm_started() { # <space-separated ids that were stopped>
  local stopped_ids="$1" waited=0 step listing live live_count survivors
  while :; do
    if listing="$(tick_rows)"; then
      live="$(live_tick_ids "$listing")"
      live_count="$(printf '%s' "$live" | grep -c . || true)"
      if [[ "$live_count" -eq 1 ]] \
         && ! printf '%s\n' "$stopped_ids" | tr ' ' '\n' | grep -qxF -- "$live"; then
        log "confirmed: $TICK_AGENT_NAME is up ($live) after ${waited}s"
        return 0
      fi
    fi
    [[ "$waited" -lt "$TICK_START_TIMEOUT_SECONDS" ]] || break
    step="$(poll_step "$waited" "$TICK_START_TIMEOUT_SECONDS")"
    sleep "$step"
    waited=$(( waited + step ))
  done
  survivors="$(surviving_tick_ids)"
  if [[ -n "${survivors//[[:space:]]/}" ]]; then
    die "after starting a replacement, $TICK_AGENT_NAME is live as: $survivors. One is the only correct number, and this is not one. Stop the extras by id before the machine dispatches twice into one HOST_MAX_CONCURRENT."
  fi
  die "$TICK_AGENT_NAME did not appear in the agent registry within ${TICK_START_TIMEOUT_SECONDS}s of starting it; the board is stopped until the next timer fire"
}

# --restart: replace the tick and leave every card agent alone.
#
# Only agents named exactly $TICK_AGENT_NAME are stopped, by id, never by
# prefix. `foreman/<installation>/tick` is a prefix of nothing, but every
# per-card name begins `foreman/<installation>/<board>/`, so a prefix stop here
# would kill every build this installation has in flight -- the one failure
# this whole mode exists to avoid.
restart_tick() {
  local before_cards after_cards stopped_ids

  if ! before_cards="$(card_agents)"; then
    # Nothing has been stopped yet, so refusing costs the operator only a retry.
    # A restart that cannot say what was in flight is one nobody can audit.
    die "cannot read the card agents out of the registry; refusing to restart the tick blind"
  fi
  log_cards "before restart" "$before_cards"

  # Every live tick, not the one inspect() named, because every live tick has to
  # be gone before a replacement may start.
  stopped_ids="$(surviving_tick_ids)"

  if [[ -z "${stopped_ids//[[:space:]]/}" ]]; then
    # A restart with no tick running is still a restart. Skip the drain and the
    # stop, and say so: an operator who typed --restart because the board looked
    # dead has just learnt why it looked dead.
    log "no $TICK_AGENT_NAME agent was running; starting one"
  elif [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would wait up to ${TICK_DRAIN_SECONDS}s for $TICK_AGENT_NAME ($stopped_ids) to finish its turn"
  else
    drain_tick
  fi

  # Nothing is started until the registry says every tick is gone. Refusing here
  # leaves the machine with exactly the ticks it already had, which is the safe
  # failure: the board keeps ticking, the operator is told the restart did not
  # happen, and a retry costs nothing.
  stop_ticks \
    || die "$TICK_AGENT_NAME is still live as: $(surviving_tick_ids), ${TICK_STOP_TIMEOUT_SECONDS}s after being asked to stop. Refusing to start a second tick beside it. Stop it by id and run this again."

  start_agent

  if [[ -n "$BOARD_DRY_RUN" ]]; then
    log "DRY RUN: would wait up to ${TICK_START_TIMEOUT_SECONDS}s for the replacement $TICK_AGENT_NAME to appear in the registry"
    return 0
  fi
  confirm_started "$stopped_ids"

  if ! after_cards="$(card_agents)"; then
    log "after restart: could not read the card agents; the replacement tick is up regardless"
    return 0
  fi
  log_cards "after restart" "$after_cards"
  report_card_changes "$before_cards" "$after_cards" "$stopped_ids"
}

# Say what happened to each card agent that was in flight before the restart.
#
# IT REPORTS WHAT IT SAW AND NEVER WHY. This used to conclude "it finished
# during the restart, and a build completing is not a disturbance" about any
# agent missing from the second listing. Nothing in the registry can tell a
# build that completed from one something stopped -- both end up stopped and
# then reaped -- so the one piece of evidence the operator was told to read
# rather than trust was printing reassurance over exactly the collateral damage
# it exists to catch.
#
# What this script can state as fact is which ids it asked the adapter to stop,
# because it issued them. That is the line an operator can act on.
report_card_changes() { # <before listing> <after listing> <tick ids stopped>
  local before="$1" after="$2" stopped_ids="$3" line name was now
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%$'\t'*}"
    was="${line#*$'\t'}"
    [[ "$was" != "stopped" ]] || continue
    now="$(card_state "$after" "$name")"
    [[ "$now" != "$was" ]] || continue
    log "after restart: card agent $name went from $was to $now. This restart asked only $TICK_AGENT_NAME to stop (${stopped_ids:-none}), so it did not stop this agent; check the card if you did not expect that."
  done <<<"$before"
}

# The state of one card agent in a listing, or "gone" when it is not there.
card_state() { # <card_agents listing> <agent name>
  local found
  found="$(printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print $2; exit }')"
  printf '%s' "${found:-gone}"
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
# read. --stop used to read the registry and issue its stops entirely outside
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
#
# RUN MODE TAKES IT OR STANDS DOWN; AN OPERATOR'S GESTURE WAITS FOR IT. A timer
# fire that skips one turn loses nothing, because the next fire is
# TICK_INTERVAL_MINUTES away and re-reads everything. Nothing re-runs a
# `--stop` or a `--restart`, so standing down on those exited 0 without doing
# the thing that was asked: an operator running
# `git -C ~/.foreman/install pull && supervise.sh --restart` five seconds after
# a timer fire took the lock saw the whole chain report success while the tick
# kept running the pre-pull skill. The window is not narrow -- a repair fire
# holds the lock through its own stop, and another operator's restart holds it
# for the drain, stop and start bounds together -- so these wait rather than
# fail on contact, and refuse only once TICK_LOCK_WAIT_SECONDS is gone.
LOCK_RC=0
if [[ "$MODE" == "run" ]]; then
  flock -n 9 || LOCK_RC=$?
else
  log "waiting up to ${TICK_LOCK_WAIT_SECONDS}s for the supervise lock"
  flock -w "$TICK_LOCK_WAIT_SECONDS" 9 || LOCK_RC=$?
fi
if [[ $LOCK_RC -eq 1 ]]; then
  if [[ "$MODE" == "run" ]]; then
    log "another supervisor holds the lock; standing down"
    exit 0
  fi
  die "another supervisor still holds $SUPERVISE_LOCK after ${TICK_LOCK_WAIT_SECONDS}s, so $MODE did not run. The tick is unchanged. Run $MODE again once that supervisor finishes."
elif [[ $LOCK_RC -ne 0 ]]; then
  die "flock failed with exit $LOCK_RC; refusing to run unlocked"
fi

# An unreadable registry is its own answer, and the modes answer it differently.
#
# RUN MODE stands down. It is a timer fire, doing nothing is safe, and the next
# fire re-reads a registry that is transiently unreadable -- a daemon
# restarting, a CLI mid-upgrade.
#
# --stop AND --restart REFUSE. An operator typed them, both mean "change the
# tick", and neither has anything to retry them: run mode stands down on this
# same condition, and once the registry reads again it finds a healthy tick and
# does nothing. Exiting 0 here told the operator who had just pulled new install
# code that the restart worked, while the old tick kept running the old skill
# indefinitely. That is the outcome restart_tick()'s own refusal to restart
# blind exists to prevent, answered one line earlier with exit 0.
if ! read_registry; then
  if [[ "$MODE" == "run" ]]; then
    log "could not read the agent registry; standing down rather than guessing"
    exit 0
  fi
  die "cannot read the agent registry, so $MODE cannot say which tick to act on; the old tick is still running and nothing retries this. Run $MODE again once the registry reads."
fi

if [[ "$MODE" == "--stop" ]]; then
  # EVERY live tick, and proof that each one went. Stopping the single agent
  # inspect() named left any other live agent of the same name ticking, and
  # said `confirmed ... is stopped` about the one it did stop -- "stop ticking"
  # that does not stop ticking, reported as success.
  stop_ticks \
    || die "$TICK_AGENT_NAME is still live as: $(surviving_tick_ids), ${TICK_STOP_TIMEOUT_SECONDS}s after being asked to stop. The board is still ticking."
  exit 0
fi

if [[ "$MODE" == "--restart" ]]; then
  restart_tick
  exit 0
fi

# Replace the tick: stop every live one, prove they are gone, then start one.
#
# A timer fire NEVER DIES HERE. The next fire is TICK_INTERVAL_MINUTES away and
# re-enters whichever branch sent it here, re-issuing the stop, so this is a
# retry and not a give-up. Dying instead marked foreman.service failed every ten
# minutes and fixed nothing -- and the tick whose stop is slowest to land is the
# wedged one this branch exists for. What it must never do is start a
# replacement beside a tick that is still running.
repair_tick() {
  if stop_ticks; then
    start_agent
    return 0
  fi
  log "ERROR: $TICK_AGENT_NAME is still live as: $(surviving_tick_ids), ${TICK_STOP_TIMEOUT_SECONDS}s after being asked to stop. Starting no replacement beside it; the next fire asks again. Stop it by id if this repeats."
}

# Reasons to (re)start, most specific first. Each prints why, because a watchdog
# that restarts silently is indistinguishable from one that does nothing.
#
# THE FIRST QUESTION IS HOW MANY TICKS ARE LIVE, not what the newest one is
# doing. Two live ticks dispatch twice into one machine-wide
# HOST_MAX_CONCURRENT, so that is a fault to repair and not a state to judge the
# health of -- and this branch is what makes the count self-heal instead of
# needing an operator to notice.
log_corpse_ticks
if [[ "$LIVE_TICKS" -gt 1 ]]; then
  log "$LIVE_TICKS $TICK_AGENT_NAME agents are live ($(surviving_tick_ids)); one is the only correct number"
  repair_tick
elif [[ -z "$ID" || "$ID" == "None" ]]; then
  log "no $TICK_AGENT_NAME agent exists"
  start_agent
elif [[ "$LIVE_TICKS" -eq 0 ]]; then
  # inspect() falls back to the newest agent when none is live, so this is the
  # corpse of the last tick and its state is the reason the board stopped.
  log "$TICK_AGENT_NAME is not running (newest is $ID, state=$STATE)"
  start_agent
elif [[ "$STATE" == "working" && "$IDLE" != "None" ]] \
     && awk "BEGIN{exit !($IDLE > $TICK_STALL_MINUTES)}"; then
  log "$TICK_AGENT_NAME wedged: mid-turn and silent for ${IDLE}m (> ${TICK_STALL_MINUTES}m)"
  repair_tick
elif [[ "$IDLE" != "None" ]] && awk "BEGIN{exit !($IDLE > $TICK_DEAD_MINUTES)}"; then
  log "$TICK_AGENT_NAME loop stopped rescheduling: idle ${IDLE}m (> ${TICK_DEAD_MINUTES}m)"
  repair_tick
elif [[ "$AGE" != "None" ]] && awk "BEGIN{exit !($AGE > $TICK_MAX_AGE_HOURS)}"; then
  log "recycling $TICK_AGENT_NAME to bound context: age ${AGE}h (> ${TICK_MAX_AGE_HOURS}h)"
  repair_tick
else
  log "$TICK_AGENT_NAME healthy (state=$STATE idle=${IDLE}m age=${AGE}h)"
fi
