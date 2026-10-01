#!/usr/bin/env bash
# Reap board worktrees for cards that are finished, and prune dead ones.
#
#   sweep.sh ABC-42 ABC-43        # tickets that are terminal; their exited
#                                 # sessions are forgotten, their idle agents
#                                 # stopped and then forgotten, and their trees
#                                 # and transcripts go
#   sweep.sh --orphans            # this board's trees with no live agent; the
#                                 # harness also reaps exited agents' records
#                                 # older than SWEEP_RETENTION_DAYS
#   sweep.sh --settle ABC-7 ABC-9 # tickets still in flight; every finished
#                                 # turn a later round superseded, and every
#                                 # turn of a card not named, is settled by
#                                 # supersede.py's rule; no tree, transcript,
#                                 # history or slot is touched
#
# The first two modes also reap `refs/$BOARD_NAME_PREFIX/evidence/<pid>` refs left behind by an
# `evidence.sh` that was killed mid-read. Nothing else in the board touches that
# namespace, and a leaked ref pins every object its fetch brought with it. A
# sweep that could not enumerate or could not delete there exits non-zero and
# says so, for the same reason `--orphans` refuses to guess at the agent list:
# "nothing leaked" and "I could not tell" must not be the same output.
#
# `claude -w` creates worktrees LOCKED, so `git worktree prune` never reaps them
# and plain `git worktree remove --force` refuses outright. It takes `-f -f`.
# Nothing else cleans these up, which is why they accumulate by the dozen.
#
# macOS ships bash 3.2: no `mapfile`, no associative arrays. Keep it portable —
# a `mapfile` here fails silently and leaves the live-agent list EMPTY, which
# would make --orphans delete every worktree on the machine.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SKILL_DIR/config.sh"

# Everything below that touches `.claude/worktrees/` -- `remove_tree`'s `git
# worktree remove`, the final `git worktree prune` -- has to run while holding
# `$REPO/.git/board-worktree.lock`, the SAME lock dispatch.sh takes around its
# own `git worktree add`. This used to take the lock around `true`: acquired,
# `true` ran and exited instantly, released, all before any worktree was
# touched -- proving nothing except that the lockfile was momentarily free.
# `git worktree add` (dispatch.sh) and `git worktree remove`/`prune` (this
# script) racing on the same `.git/worktrees` metadata is exactly what the
# lock exists to prevent, and it was not preventing it.
#
# Re-executing this SAME script as the command withlock.py guards -- rather
# than inlining the mutating body as a `bash -c '...'` string the way
# dispatch.sh does -- keeps every function below exactly as written, with no
# quoting hazard from embedding 150 lines of shell inside a string literal.
# `_FOREMAN_SWEEP_LOCKED` is the re-entry guard: unset on the first (real)
# invocation, set on the re-exec, so the second pass falls through instead of
# taking the lock again.
if [[ -z "${_FOREMAN_SWEEP_LOCKED:-}" ]]; then
  status=0
  env _FOREMAN_SWEEP_LOCKED=1 \
    "$SKILL_DIR/withlock.py" "$REPO/.git/board-worktree.lock" 120 \
    -- "$SKILL_DIR/sweep.sh" "$@" || status=$?
  # 75 is withlock.py's own EX_TEMPFAIL, meaning ONLY "the lock was still held
  # after the timeout" -- anything else is the sweep itself failing while
  # holding the lock, and reporting that as "lock is held" would hide a real
  # failure (a bad worktree, a `die` from inside) behind a contention message
  # that was never true.
  if [[ "$status" -eq 75 ]]; then
    die "repository lock is held; skipping sweep this tick"
  fi
  exit "$status"
fi

# Delete <path> and everything under it, and say so on stderr when it cannot.
#
# A toolchain can leave a tree that `rm -rf` refuses: Go writes its module cache
# read-only, so the first `rm -rf` of a build's scratch failed, and under
# `set -e` that one failure ended the whole sweep -- every later worktree,
# scratch dir and leaked ref stayed. So a refused delete is retried once the
# tree is writable again, and one that still fails is named, held in
# remove_status for the exit code, and the sweep goes on.
remove_status=0
force_remove() { # <path>
  rm -rf "$1" 2>/dev/null && return 0
  # Best effort: the retry below is what decides, and says so when it fails.
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1" && return 0
  printf 'foreman: could not remove %s (see above); it stays for a later sweep\n' "$1" >&2
  remove_status=1
  return 1
}

# Scratch lives beside the worktree and dies with it. It is reaped HERE, by the
# sweep, and never by the agent itself: an agent only cleans up if it gets to
# exit on its own terms, and the ones that most need cleaning are the ones
# killed mid-command — a full disk, a quota, an OOM. Two build attempts killed
# mid-command by a full-disk incident on one card would each have cleaned up
# nothing.
remove_agent_tmp() {
  local tmp="$1"
  [[ -d "$tmp" ]] || return 0
  case "$tmp" in
    "$AGENT_TMP_ROOT"/"$BOARD_WORKTREE_PREFIX"-*) ;;
    *) die "refusing to remove $tmp — not an agent scratch dir" ;;
  esac
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    printf 'DRY RUN: would remove scratch %s (%s)\n' "$tmp" "$(du -sh "$tmp" 2>/dev/null | cut -f1)"
    return 0
  fi
  force_remove "$tmp" || return 0
  printf 'removed scratch %s\n' "$tmp"
}

remove_tree() {
  local path="$1" branch
  [[ -d "$path" ]] || remove_agent_tmp "$(agent_tmp_for "$path")"
  [[ -d "$path" ]] || return 0
  case "$path" in
    "$REPO"/.claude/worktrees/"$BOARD_WORKTREE_PREFIX"-*) ;;
    *) die "refusing to remove $path — not a foreman worktree" ;;
  esac
  remove_agent_tmp "$(agent_tmp_for "$path")"
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    printf 'DRY RUN: would remove worktree %s (branch %s)\n' "$path" "${branch:-detached}"
    return 0
  fi
  if ! git -C "$REPO" worktree remove -f -f "$path" 2>/dev/null; then
    force_remove "$path" || return 0
  fi
  # Only ever delete a local branch this skill created.
  case "$branch" in
    "$BOARD_NAME_PREFIX"/*) git -C "$REPO" branch -D "$branch" 2>/dev/null || true ;;
  esac
  printf 'removed %s\n' "$path"
}

# How long a finished agent's leavings are kept. Thirty days is already the
# retention this sweep applies to reviews at the bottom of this file, and an
# agent's record, log and wrapper are the same kind of thing: regenerable
# evidence of a run that is over, read by a human for as long as anyone is still
# asking what happened. One number, so the two cannot drift apart.
SWEEP_RETENTION_DAYS=30

# What the harness left behind for every agent it ever spawned.
#
# codex.sh and opencode.sh have no agent registry, so detached.sh writes three
# files per spawn under $FOREMAN_HOME/agents — <id>.json, <id>.log and <id>.sh —
# and until this existed nothing ever deleted them. That is unbounded disk, and
# worse: `list` globs and JSON-parses every record ever written, and `list` is
# read on every dispatch gate, every sweep, every watch-agents poll and every
# supervise fire. The cost of asking "is this agent alive" rose with the age of
# the installation.
#
# claude.sh answers the same verb by running `claude rm` on every exited row
# (no pid, not working) whose name starts with AGENT_NAME_ROOT and that started
# more than SWEEP_RETENTION_DAYS ago. It used to be a no-op, on the belief that
# Claude Code aged its own rows out. Measured 2026-09-23 on 2.1.280, it does
# not: an exited row stays `done` with no pid until something removes it, and
# live_worktrees protects that row's tree for as long as the row is listed. One
# board piled up 72 trees, 261G. This runs after the tree loop above, so a
# reaped row's tree goes on the NEXT orphan pass, once the row is gone.
#
# The adapter decides which agents are finished — it owns that rule for `list`
# too — and prints the ids it took. This function only says so in the sweep's
# voice, and only ever deletes through the adapter.
#
# BOARD_DRY_RUN is passed explicitly: `config.sh` does not export it, and the
# adapter is a separate process, so an inherited-by-accident dry run would
# delete on a run the operator asked to be told about.
reap_agent_records() {
  local ids id
  if ! ids="$(env BOARD_DRY_RUN="$BOARD_DRY_RUN" \
      "$HARNESS_SH" reap "$(( SWEEP_RETENTION_DAYS * 24 * 60 * 60 ))")"; then
    printf 'foreman: %s reap exited non-zero; finished agents keep their records, logs and wrappers\n' \
      "$HARNESS_SH" >&2
    return 1
  fi
  while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ -n "$BOARD_DRY_RUN" ]]; then
      printf 'DRY RUN: would remove agent record %s\n' "$id"
    else
      printf 'removed agent record %s\n' "$id"
    fi
  done <<<"$ids"
}

# Leaked `refs/$BOARD_NAME_PREFIX/evidence/<pid>` refs, from `evidence.sh` invocations that
# were killed between their fetch and their `update-ref -d`.
#
# `evidence.sh` traps HUP, INT and TERM and deletes its own ref, so this exists
# for SIGKILL, which cannot be trapped. Nothing else touches that namespace:
# `git fetch --prune` prunes `refs/remotes/`, `dispatch.sh` prunes worktrees,
# and `git gc --prune=now` keeps a leaked ref along with every object it pins.
# The window is the fetch, which is the slow part of an evidence read, so this
# is the ordinary way a stopped tick leaves litter rather than a rare one.
#
# Keyed on the pid the ref is named for, because a read that is still running
# owns its ref and must keep it: a live pid is left alone. Pid reuse only ever
# DELAYS a reap to the sweep after the reusing process exits, which is the safe
# direction to be wrong in. A ref whose last component is not a number belongs
# to no process that can be asked, so it goes.
#
# This is the LAST defence against that leak — `evidence.sh` traps what it can,
# and this catches the SIGKILL it cannot — so it may not fail quietly. A reap
# that cannot enumerate the namespace, or cannot delete a ref in it, returns
# non-zero and says which on stderr; the caller turns that into a non-zero
# sweep. Swallowing it made "no leaks" and "could not check for leaks" the same
# output, and a permissions problem or a corrupt ref would then pin objects
# forever while every sweep reported success.
#
# Enumeration is captured rather than piped in through a process substitution
# for exactly that reason: `< <(git for-each-ref ...)` discards git's exit
# status, so a failed listing arrives as an empty one and reads as "clean".
# A failed delete does not abort the loop — the other leaked refs are still
# worth reaping — it is recorded and reported at the end.
reap_evidence_refs() {
  local ref pid refs failed=0
  if ! refs="$(git -C "$REPO" for-each-ref --format='%(refname)' "refs/$BOARD_NAME_PREFIX/evidence/*")"; then
    printf 'foreman: could not list refs/%s/evidence/* in %s; leaked evidence refs went unchecked\n' \
      "$BOARD_NAME_PREFIX" "$REPO" >&2
    return 1
  fi
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    pid="${ref##*/}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    if [[ -n "$BOARD_DRY_RUN" ]]; then
      printf 'DRY RUN: would delete leaked evidence ref %s\n' "$ref"
      continue
    fi
    if git -C "$REPO" update-ref -d "$ref"; then
      printf 'removed leaked evidence ref %s\n' "$ref"
    else
      printf 'foreman: could not delete leaked evidence ref %s; it still pins every object its fetch brought\n' \
        "$ref" >&2
      failed=1
    fi
  done <<<"$refs"
  return "$failed"
}

# Exits non-zero if the agent list could not be read at all. That distinction
# matters: "no agents are alive" and "I could not tell" must not look the same.
#
# A finished agent's tree is released by its ROW going, never by its pid going.
# Ticket mode forgets a terminal card's exited rows before it reads this again,
# and --orphans' reap removes exited rows past the retention window. Either way
# the row is absent from `list`, so its cwd is not printed here. An absent row
# is one a harness verb removed on purpose; an absent pid is only a field the
# registry did not report, and the rule inside says why that is not death.
live_worktrees() {
  "$HARNESS_SH" list 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read()
if not raw.strip(): sys.exit(3)
try: agents=json.loads(raw)
except Exception: sys.exit(3)
# Protect unless PROVABLY dead. Deleting a live agents working directory
# destroys unpushed work and kills it with no diagnosable error; leaving a dead
# tree costs disk until the next sweep. Those costs are nowhere near equal, so
# anything not positively "stopped" is treated as live.
#
# Do NOT reintroduce a `pid` requirement here. A background agent reports a pid
# only while it is running and drops it once stopped, so `pid and not stopped`
# happens to be right today — but it makes absence of a field mean death, and
# the day a live agent is listed without one this deletes the tree under it.
for a in agents:
    if a.get("state") != "stopped":
        print(a.get("cwd",""))
' || return 1
  dispatching_worktrees
}

# The worktrees a dispatch is still cutting or bootstrapping, one per line.
#
# Its agent is not registered yet, so the registry cannot protect the tree, and
# a bootstrap can run for minutes. dispatch.sh holds a marker named for the
# worktree and carrying its own pid (config.sh's dispatch_marker_for); the tree
# is live while that pid is. A marker whose pid is gone was left by a killed
# dispatch, protects nothing, and is removed. Hidden files are temporaries
# dispatch.sh is still writing, so the glob skips them.
dispatching_worktrees() {
  local marker pid
  for marker in "$(dispatch_marker_dir)"/*; do
    [[ -f "$marker" ]] || continue
    pid="$(head -n 1 "$marker" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s/.claude/worktrees/%s\n' "$REPO" "$(basename -- "$marker")"
    elif [[ -z "$BOARD_DRY_RUN" ]]; then
      rm -f "$marker"
    fi
  done
}

# Release the card's concurrency slot, here rather than in prose.
#
# `config.sh` already predicted this failure where it explains
# HOST_SLOT_STALE_MINUTES: "A slot releasable ONLY by an LLM remembering one
# specific line violates that ... would otherwise wedge dispatch on EVERY
# instance on this machine forever." Measured on 2026-09-01: a card merged, its
# history recorded `merged`, no `released` marker was ever written, and the board
# went on counting five held slots with nothing running.
#
# Ticket-mode sweep is the right place because it is already the code path for
# "this card is terminal, clean up after it". The caller only ever names a
# ticket here once the card has finished, so reaping its worktree and releasing
# its slot are the same event, and one of them was being left to memory.
#
# The marker means "this card no longer holds a slot", NOT "this card
# succeeded" -- both board-failed exits release exactly as much as Done does.
# Writing it twice is harmless: `card_holds_slot` reads the LAST entry, so a
# second release is a no-op rather than a corruption.
#
# NOT WHILE AN AGENT OF THE CARD STILL RUNS. The sweep leaves a working agent
# alone, and leaves an idle one whose stop did not land; either still uses the
# machine. Releasing its slot anyway let the next dispatch run beside it, one
# past the ceiling. The slot is kept, the sweep says why, and a later sweep of
# the card -- or HOST_SLOT_STALE_MINUTES -- releases it once the agent is gone.
release_slot() {
  local ticket="$1"
  if card_has_live_agent "$ticket"; then
    printf 'foreman: keeping the slot for %s -- an agent of the card is still running (see above)\n' \
      "$ticket" >&2
    return 0
  fi
  [[ -n "$BOARD_DRY_RUN" ]] && { printf 'DRY RUN: would release the slot for %s\n' "$ticket"; return 0; }
  card_log "$ticket" '{"action":"released","by":"sweep"}'
}

# Whether the registry still lists an agent of <ticket> that is running: idle
# or anything else, i.e. not exited. A registry that cannot be read answers yes,
# because a slot released under a live agent is the failure this guards.
card_has_live_agent() { # <ticket>
  local listing kind rest
  listing="$(card_sessions "$(card_agents_prefix "$1")")" || return 0
  while IFS="$FIELD_SEP" read -r kind rest; do
    case "$kind" in idle|other) return 0 ;; esac
  done <<<"$listing"
  return 1
}

# Settle a terminal card's sessions: stop the idle ones, forget the exited ones.
#
# Measured 2026-09-23 on Claude Code 2.1.280, on the production host (claude.sh
# records the detail): a finished `claude --bg` agent EXITS. Its row stays
# `done` with `pid: null`. The registry held 162 done, 54 stopped, 2 blocked and
# 1 failed rows with no pid, against one idle `done` row and one `working` row
# that had one. `claude stop` on an exited row prints `stopped <id>`, exits 0
# and changes nothing.
#
# This used to stop every `done` or `blocked` row and wait for the registry to
# say `stopped`. On an exited row that never came, so every terminal card spent
# 30s re-issuing stops, reported "did not land", and the sweep exited 1 on every
# board on every pass. It also forgot a session by deleting
# `~/.claude/jobs/<id>/` itself, which Claude Code had stopped listing rows from
# alone, and which never ran on any other harness.
#
# So each of the card's rows is classified by its pid and state:
# - exited (no pid, not working): nothing is running. It is forgotten now,
#   through `"$HARNESS_SH" forget`, which the owning harness answers --
#   `claude rm` for Claude Code, deleting the record files for codex and
#   opencode.
# - idle (a pid, `done` or `blocked`): a turn that finished on a card with
#   nothing left to say, or a prompt nobody will answer. It is stopped, the
#   stop re-issued on every poll, and awaited until its row is exited or gone.
#   Then it is forgotten like any exited row.
# - anything else (`working`, or a pid beside any other state): left and
#   named. The caller's judgment that the card is terminal may be stale, raced
#   or wrong, and a stop it did not need costs a build.
#
# The registry, never an exit code, says when a stop landed -- the loop
# supervise.sh runs for the tick, bounded by AGENT_STOP_TIMEOUT_SECONDS. An idle
# agent still running at the bound is left, named on stderr, and held in
# `stop_status` for the exit code. "A session lingers" must not read as a clean
# sweep. A forget that fails is held in `forget_status` the same way, and costs
# neither the other forgets nor the slot release that follows.
#
# Ticket mode only, for the reason the slot is released here and nowhere else:
# the caller has just judged the card terminal, and a terminal card is the one
# whose sessions have no reader left. `--orphans` never stops or forgets a
# session. A card that is not terminal may still be diagnosed from its
# transcript (reconcile.py's `death`) or resumed into it. `--orphans` ages
# exited rows out through reap_agent_records instead. `--settle` stops and
# forgets only the rows a later round of a live card superseded, and keeps
# every transcript (settle_superseded_sessions says why).
#
# Scoped by name prefix, so it is this instance's sessions for these tickets
# and never a sibling board's, the tick's, or ABC-10's when asked about ABC-1.
stop_status=0
forget_status=0
# The name of every session this sweep forgot, one per line. The history entry
# is written per ticket, after its trees go and before its slot is released.
forgotten_names=""

# Separates the fields card_sessions prints. Not a tab: a tab is whitespace to
# `read`, so two tabs around an empty cwd collapse into one and every later
# field shifts left.
FIELD_SEP=$'\x1f'

# Every row of these tickets' agents, one per line, FIELD_SEP between fields:
# <class> <id> <name> <cwd> <sessionId> <state> <pid>, the class being
# `exited`, `idle` or `other`. Exits non-zero when the registry cannot be read,
# which the caller must not confuse with "no sessions".
#
# `exited` is the rule the adapters' `forget` applies. They check it again and
# refuse a row that does not meet it, so a row misread here is refused rather
# than removed.
card_sessions() { # <name prefix...>
  local agents
  agents="$("$HARNESS_SH" list)" || return 3
  printf '%s' "$agents" | python3 -c '
import json, sys

prefixes = sys.argv[1:]
try:
    agents = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(3)
if not isinstance(agents, list):
    sys.exit(3)

def text(value):
    return "" if value is None else str(value)

for agent in agents:
    if not isinstance(agent, dict):
        continue
    name = agent.get("name") or ""
    if not any(name.startswith(prefix) for prefix in prefixes):
        continue
    pid, state = agent.get("pid"), agent.get("state")
    if pid is None and state != "working":
        kind = "exited"
    elif pid is not None and state in ("done", "blocked"):
        kind = "idle"
    else:
        kind = "other"
    print("\x1f".join([kind, text(agent.get("id")), name, text(agent.get("cwd")),
                       text(agent.get("sessionId")), text(state), text(pid)]))
' "$@"
}

# in_words <space-separated words> <word>
in_words() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# forget_session <id> <name> <cwd> <sessionId>
#
# The transcript's path is asked for BEFORE the forget. A detached harness's
# transcript is its log, which the forget deletes along with the record the
# path is read from.
#
# A transcript no harness has on disk is nothing to remove, not a failure.
# registry.sh exits non-zero when no adapter finds the file -- claude.sh no
# longer answers with a path it only composed -- and a session that exited
# before it wrote anything has none. Counting that as a failed forget failed
# every sweep of such a card.
forget_session() {
  local id="$1" name="$2" cwd="$3" session="$4" transcript=""
  if [[ -n "$cwd" && -z "$session" ]]; then
    printf 'foreman: session %s (%s) has no session id in its row, so its transcripts cannot be found; they stay\n' \
      "$name" "$id" >&2
  fi
  if [[ -n "$cwd" && -n "$session" ]] \
      && ! transcript="$("$HARNESS_SH" transcript "$cwd" "$session" 2>/dev/null)"; then
    printf 'foreman: no harness has a transcript on disk for session %s (%s); there is none to remove\n' \
      "$name" "$id" >&2
    transcript=""
  fi
  forget_row "$id" "$name" || return 0
  if [[ -n "$transcript" ]]; then
    remove_transcripts "$name" "$cwd" "$(dirname "$transcript")"
  fi
}

# forget_row <id> <name> -- remove the session's registry row through its
# harness, and nothing else. Fails, held in forget_status, when the harness
# refuses.
forget_row() {
  local id="$1" name="$2"
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    printf 'DRY RUN: would forget session %s (%s)\n' "$name" "$id"
    return 0
  fi
  if ! "$HARNESS_SH" forget "$id" >/dev/null; then
    printf 'foreman: could not forget session %s (%s) (see above); its record stays\n' "$name" "$id" >&2
    forget_status=1
    return 1
  fi
  printf 'forgot session %s (%s)\n' "$name" "$id"
  forgotten_names="$forgotten_names$name"$'\n'
}

settle_card_sessions() { # <ticket...>
  local prefixes=() ticket listing kind id name cwd session state pid idle
  local waited=0 forgetting="" left=""
  for ticket in "$@"; do prefixes+=("$(card_agents_prefix "$ticket")"); done
  while :; do
    if ! listing="$(card_sessions ${prefixes[@]+"${prefixes[@]}"})"; then
      printf 'foreman: could not read the agent registry; stopping and forgetting no session\n' >&2
      stop_status=1
      return 0
    fi
    idle=""
    while IFS="$FIELD_SEP" read -r kind id name cwd session state pid; do
      [[ -n "$id" ]] || continue
      case "$kind" in
        exited)
          # Once. A forget that failed leaves the row exited, and asking again
          # on every poll would only repeat the refusal.
          in_words "$forgetting" "$id" && continue
          forgetting="$forgetting $id"
          forget_session "$id" "$name" "$cwd" "$session"
          ;;
        idle)
          idle="$idle$id$FIELD_SEP$name"$'\n'
          ;;
        *)
          in_words "$left" "$id" && continue
          left="$left $id"
          printf 'foreman: leaving session %s (%s) -- it is %s with pid %s; only an idle agent (a pid, done or blocked) is stopped, and only an exited one forgotten\n' \
            "$name" "$id" "${state:-unknown}" "${pid:-none}" >&2
          ;;
      esac
    done <<<"$listing"
    [[ -n "$idle" ]] || return 0
    stop_round "$waited" "$idle" || return 0
    waited=$((waited + STOP_POLL_SECONDS))
  done
}

# How often a stop loop re-reads the registry, in seconds.
STOP_POLL_SECONDS=2
# The id of every session a stop loop has announced, so each is named once.
stop_announced=""

# stop_round <seconds waited so far> <rows, one "<id>FIELD_SEP<name>" per line>
#
# One poll of a stop loop: stop every row, then sleep STOP_POLL_SECONDS. The
# stop is re-issued on every poll, because the registry read by the caller, not
# the exit code, says when it landed. Returns 1 when the loop is over instead:
# on a dry run, which only names what it would stop, and at the
# AGENT_STOP_TIMEOUT_SECONDS bound, which names every row still running and
# holds the failure in stop_status.
stop_round() {
  local waited="$1" rows="$2" id name
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    while IFS="$FIELD_SEP" read -r id name; do
      [[ -n "$id" ]] && printf 'DRY RUN: would stop session %s (%s)\n' "$name" "$id"
    done <<<"$rows"
    return 1
  fi
  if [[ "$waited" -ge "$AGENT_STOP_TIMEOUT_SECONDS" ]]; then
    while IFS="$FIELD_SEP" read -r id name; do
      [[ -n "$id" ]] && printf 'foreman: leaving session %s (%s) -- the stop did not land in %ss\n' \
        "$name" "$id" "$AGENT_STOP_TIMEOUT_SECONDS" >&2
    done <<<"$rows"
    stop_status=1
    return 1
  fi
  while IFS="$FIELD_SEP" read -r id name; do
    [[ -n "$id" ]] || continue
    if ! in_words "$stop_announced" "$id"; then
      printf 'stopping session %s (%s)\n' "$name" "$id"
      stop_announced="$stop_announced $id"
    fi
    "$HARNESS_SH" stop "$id" >/dev/null 2>&1 || true
  done <<<"$rows"
  sleep "$STOP_POLL_SECONDS"
}

# Settle the finished turns a live card no longer needs: `--settle` mode.
#
# A finished turn idles with its pid and about 300 MB until something stops it,
# and ticket mode reaches a card only once it is terminal. supersede.py's header
# has the measurement.
#
# supersede.py owns the rule for which rows are settled and how. It reads the
# registry and prints one line per row: `stop` (idle, settle it), `forget`
# (exited, and nothing will resume it) or `keep` (its card may still resume
# it -- a resume needs the row, and the row must not be `stopped`, or
# --orphans reaps the tree the resume runs in). Each poll runs
# it again, so a row stopped here turns up as `forget` or `keep` once its stop
# lands. The stop loop is ticket mode's, bounded the same way.
#
# A forget here removes the registry row and NEVER the transcripts. A
# transcript directory belongs to the worktree, not to one session: build-1 and
# the fork a `--resume` of it created write to the same one. Removing it with
# the superseded build-1 row would delete the transcript of the fork the card
# resumes next. Ticket mode removes transcripts once the whole card is terminal.
#
# No worktree, card history or slot is touched. The card is live, so its tree
# is still in use, and its slot is held by the card, not by one session.
settle_status=0
settle_superseded_sessions() { # <in-flight ticket...>
  local listing action id name stopping
  local waited=0 handled=""
  while :; do
    if ! listing="$(superseded_sessions ${1+"$@"})"; then
      printf 'foreman: could not read the agent registry or classify its rows; settling no further session\n' >&2
      settle_status=1
      return 0
    fi
    stopping=""
    while IFS="$FIELD_SEP" read -r action id name; do
      [[ -n "$id" ]] || continue
      case "$action" in
        stop)
          stopping="$stopping$id$FIELD_SEP$name"$'\n'
          ;;
        forget)
          # Once, for the reason settle_card_sessions forgets once.
          in_words "$handled" "$id" && continue
          handled="$handled $id"
          forget_row "$id" "$name" || true
          ;;
        keep)
          in_words "$handled" "$id" && continue
          handled="$handled $id"
          printf 'keeping session %s (%s) -- its card may still resume it\n' \
            "$name" "$id"
          ;;
        *)
          printf 'foreman: supersede.py asked to %s session %s (%s); only stop, forget and keep are known\n' \
            "${action:-(nothing)}" "$name" "$id" >&2
          settle_status=1
          return 0
          ;;
      esac
    done <<<"$listing"
    [[ -n "$stopping" ]] || return 0
    stop_round "$waited" "$stopping" || return 0
    waited=$((waited + STOP_POLL_SECONDS))
  done
}

# The settleable rows of this board, as supersede.py prints them. Exits
# non-zero when the registry cannot be read or its rows cannot be classified,
# which the caller must not confuse with "nothing to settle".
superseded_sessions() { # <in-flight ticket...>
  "$HARNESS_SH" list | "$SKILL_DIR/supersede.py" --prefix "$BOARD_NAME_PREFIX/" --in-flight ${1+"$@"}
}

# Record in the card's history how many of its sessions this sweep forgot.
record_forgotten() { # <ticket>
  local prefix name count=0
  prefix="$(card_agents_prefix "$1")"
  while IFS= read -r name; do
    case "$name" in "$prefix"*) count=$((count + 1)) ;; esac
  done <<<"$forgotten_names"
  [[ "$count" -gt 0 ]] || return 0
  card_log "$1" "$(printf '{"action":"forgot","by":"sweep","sessions":%d}' "$count")"
}

# remove_transcripts <session name> <cwd it ran in> <its transcript directory>
#
# A transcript directory goes only when the session ran in one of this
# instance's throwaway worktrees. A dispatch run by hand from the repository
# root shares that directory with whoever else worked there, so its record
# goes, its transcripts stay, and the sweep says so.
remove_transcripts() {
  local name="$1" cwd="$2" dir="$3"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case "$dir" in
    "$HOME"/.claude/projects/?*) ;;
    # A detached harness's transcript is its log under $FOREMAN_HOME/agents.
    # The adapter's forget already deleted it with the record, and the
    # directory holding it is every agent's, so nothing here is this session's
    # to remove.
    *) return 0 ;;
  esac
  case "$cwd" in
    "$REPO"/.claude/worktrees/"$BOARD_WORKTREE_PREFIX"-*) ;;
    *)
      printf 'foreman: leaving transcripts in %s -- %s ran outside a foreman worktree, so that directory is shared\n' \
        "$dir" "$name" >&2
      return 0
      ;;
  esac
  if [[ -n "$BOARD_DRY_RUN" ]]; then
    printf 'DRY RUN: would remove transcripts %s\n' "$dir"
    return 0
  fi
  force_remove "$dir" || return 0
  printf 'removed transcripts %s\n' "$dir"
}

[[ $# -gt 0 ]] || die "usage: sweep.sh <TICKET...> | --orphans | --settle [IN-FLIGHT-TICKET...]"

# Settle mode does its one job and exits here. It reads no live worktrees, since
# it removes none, and skips the evidence-ref reap, the worktree prune and the
# review prune: the other two modes run on the same pass and own those. It still
# runs under the worktree lock above, so it never forgets a row a ticket-mode
# sweep of the same board is forgetting at the same moment -- the second forget
# would be refused and read as a failure.
if [[ "$1" == "--settle" ]]; then
  shift
  settle_superseded_sessions ${1+"$@"}
  [[ "$settle_status" -eq 0 ]] \
    || die "could not tell which sessions are superseded (see above); some finished turns may still hold their process"
  [[ "$forget_status" -eq 0 ]] \
    || die "could not forget every superseded session (see above); a finished session may still be listed"
  [[ "$stop_status" -eq 0 ]] \
    || die "a superseded session did not stop (see above); it still holds its process until a later sweep"
  exit 0
fi

# Read ONCE, and read the same way, for BOTH modes. This used to be built only
# under --orphans; ticket mode called remove_tree() straight from the caller's
# say-so, with no liveness check of its own. `--orphans`' whole reason to exist
# is that deleting a live agent's working directory "destroys unpushed work and
# kills it with no diagnosable error" and that cost is "nowhere near equal" to
# leaving a dead tree an extra tick -- a reasoning that does not become false
# because the caller named the ticket instead of sweep.sh finding it itself.
# SKILL.md only ever passes tickets it just judged terminal, so this should be
# a no-op in the ordinary case; it is the same defense-in-depth `--orphans`
# already has, for the case where that judgment was stale, raced, or wrong.
LIVE_FILE="$(mktemp)"
trap 'rm -f "$LIVE_FILE"' EXIT
if ! live_worktrees >"$LIVE_FILE"; then
  die "could not read live agents; refusing to sweep"
fi

# remove_tree_unless_live <path> -- remove_tree(), but leave a worktree alone
# if it is a not-provably-stopped agent's cwd, the same guard --orphans uses.
remove_tree_unless_live() {
  local path="$1"
  if grep -Fxq "$path" "$LIVE_FILE"; then
    printf 'foreman: leaving %s -- its agent is not (yet) stopped\n' "$path" >&2
    return 0
  fi
  remove_tree "$path"
}

agent_reap_status=0
if [[ "${1:-}" == "--orphans" ]]; then
  for path in "$REPO"/.claude/worktrees/"$BOARD_WORKTREE_PREFIX"-*/; do
    [[ -d "$path" ]] || continue
    path="${path%/}"
    grep -Fxq "$path" "$LIVE_FILE" || remove_tree "$path"
  done
  # Scratch whose worktree is already gone. The loop above only visits trees
  # that still exist, so a worktree reaped by an earlier sweep leaves its
  # scratch behind forever — which is precisely the accumulation this exists to
  # stop. Keyed on the worktree the scratch is named for, and still refusing to
  # act when that worktree is a live agent's cwd.
  for tmp in "$AGENT_TMP_ROOT"/"$BOARD_WORKTREE_PREFIX"-*/; do
    [[ -d "$tmp" ]] || continue
    tmp="${tmp%/}"
    wt="$REPO/.claude/worktrees/$(basename "$tmp")"
    [[ -d "$wt" ]] && continue
    grep -Fxq "$wt" "$LIVE_FILE" && continue
    remove_agent_tmp "$tmp"
  done
  # Held rather than propagated on the spot, for the reason the evidence-ref
  # reap below is held: the rest of the sweep is unrelated and still worth
  # doing.
  reap_agent_records || agent_reap_status=$?
else
  # The stops and forgets change the answer the liveness read above gave: a
  # forgotten row is absent, so its tree is no longer protected. So it is asked
  # again once they have landed -- and refused again if it cannot be read, for
  # the reason it was refused the first time.
  settle_card_sessions "$@"
  if ! live_worktrees >"$LIVE_FILE"; then
    die "could not read live agents after settling the cards' sessions; refusing to sweep"
  fi
  for ticket in "$@"; do
    remove_tree_unless_live "$(worktree_path "$ticket")"
    for extra in "$REPO"/.claude/worktrees/"$BOARD_WORKTREE_PREFIX"-"$ticket"-*/; do
      [[ -d "$extra" ]] && remove_tree_unless_live "${extra%/}"
    done
    # Before the release, so `released` stays the card's last history line --
    # card_holds_slot reads only that one.
    record_forgotten "$ticket"
    release_slot "$ticket"
  done
fi

[[ -n "$BOARD_DRY_RUN" ]] || git -C "$REPO" worktree prune

# Held rather than propagated on the spot, so a reap that fails still leaves the
# rest of the sweep done: the review prune below is cheap, unrelated, and would
# otherwise stop running for as long as the ref problem lasts.
reap_status=0
reap_evidence_refs || reap_status=$?

# Reviews are regenerable; history.jsonl is the card's audit trail and stays.
find "$BOARD_HOME"/cards/*/reviews -type f -mtime +"$SWEEP_RETENTION_DAYS" -delete 2>/dev/null || true

[[ "$agent_reap_status" -eq 0 ]] \
  || die "could not reap finished agent records (see above); $HARNESS_SH left them in place"

[[ "$reap_status" -eq 0 ]] \
  || die "could not reap leaked evidence refs (see above); refs/$BOARD_NAME_PREFIX/evidence/* is unswept"
[[ "$forget_status" -eq 0 ]] \
  || die "could not forget every exited session of these cards (see above); a finished session may still be listed"
[[ "$stop_status" -eq 0 ]] \
  || die "a terminal card's agent did not stop (see above); its worktree, record and transcripts are left for a later sweep"
[[ "$remove_status" -eq 0 ]] \
  || die "could not remove every tree this sweep reaped (see above); they are left for a later sweep"
