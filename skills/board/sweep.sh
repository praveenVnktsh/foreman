#!/usr/bin/env bash
# Reap board worktrees for cards that are finished, and prune dead ones.
#
#   sweep.sh ABC-42 ABC-43        # tickets that are terminal; their idle agents
#                                 # are stopped, and their trees and sessions go
#   sweep.sh --orphans            # board-* trees with no live agent
#
# Either way it also reaps `refs/$BOARD_NAME_PREFIX/evidence/<pid>` refs left behind by an
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
  rm -rf "$tmp"
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
  git -C "$REPO" worktree remove -f -f "$path" 2>/dev/null || rm -rf "$path"
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
# the installation. claude.sh answers this verb with a no-op, because its
# registry is Claude's own.
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
'
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
release_slot() {
  local ticket="$1"
  [[ -n "$BOARD_DRY_RUN" ]] && { printf 'DRY RUN: would release the slot for %s\n' "$ticket"; return 0; }
  card_log "$ticket" '{"action":"released","by":"sweep"}'
}

# Stop a terminal card's idle agents, so the rest of the sweep can reap them.
#
# A background agent does not exit when its turn ends. It idles at `done` with
# its pid intact (reconcile.py's PHASE table records the measurement), and
# nothing in the board ever asked it to stop: the tick stops a stalled or a
# blocked agent and no other. So a merged card's build agent sat at `done`
# forever, its worktree protected by the liveness guard as "not (yet)
# stopped", its row kept by `claude agents --all`, and the operator's session
# list grew by a plan, a build and every reviewer per card.
#
# Only `done` and `blocked`. `done` is a turn that finished, and a terminal
# card's turn has nothing left to say; `blocked` is a prompt nobody will
# answer. A `working` agent is left alone, on the reasoning ticket mode leaves a
# working agent's worktree: the caller's judgment that the card is terminal may
# be stale, raced or wrong, and a stop it did not need costs a build.
# forget_sessions then names the working session and leaves it.
#
# A stop is asynchronous and can fail, so it is re-issued on every
# poll and the registry, never the exit code, says when it landed -- the loop
# supervise.sh runs for the tick, bounded by AGENT_STOP_TIMEOUT_SECONDS. An
# agent still not stopped at the bound is left, named on stderr, and held in
# `stop_status` for the exit code. "A session lingers" must not read as a clean
# sweep.
stop_status=0
# Every agent of these tickets that is safe to stop: "<id><TAB><name>" per
# line. Exits non-zero when the registry cannot be read, which the caller must
# not confuse with "nothing to stop".
stoppable_agents() { # <name prefix...>
  "$HARNESS_SH" list 2>/dev/null | python3 -c '
import json,sys
prefixes=sys.argv[1:]
try: agents=json.loads(sys.stdin.read())
except ValueError: sys.exit(3)
if not isinstance(agents,list): sys.exit(3)
for a in agents:
    if not isinstance(a,dict): continue
    name=a.get("name") or ""
    if not any(name.startswith(p) for p in prefixes): continue
    if a.get("state") not in ("done","blocked"): continue
    print("%s\t%s"%(a.get("id") or "", name))
' "$@"
}

stop_card_agents() { # <ticket...>
  local prefixes=() ticket listing id name waited=0 asked="" poll_seconds=2
  for ticket in "$@"; do prefixes+=("$(card_agents_prefix "$ticket")"); done
  while :; do
    if ! listing="$(stoppable_agents ${prefixes[@]+"${prefixes[@]}"})"; then
      printf 'foreman: could not read the agent registry; stopping no session\n' >&2
      stop_status=1
      return 0
    fi
    [[ -n "${listing//[[:space:]]/}" ]] || return 0
    if [[ -n "$BOARD_DRY_RUN" ]]; then
      while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && printf 'DRY RUN: would stop session %s (%s)\n' "$name" "$id"
      done <<<"$listing"
      return 0
    fi
    if [[ "$waited" -ge "$AGENT_STOP_TIMEOUT_SECONDS" ]]; then
      while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && printf 'foreman: leaving session %s (%s) -- the stop did not land in %ss\n' \
          "$name" "$id" "$AGENT_STOP_TIMEOUT_SECONDS" >&2
      done <<<"$listing"
      stop_status=1
      return 0
    fi
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" ]] || continue
      case " $asked " in
        *" $id "*) ;;
        *) printf 'stopping session %s (%s)\n' "$name" "$id"; asked="$asked $id" ;;
      esac
      # The registry below decides whether this landed; the exit code cannot.
      "$HARNESS_SH" stop "$id" >/dev/null 2>&1 || true
    done <<<"$listing"
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
}

# Forget a terminal card's finished sessions.
#
# A `claude --bg` agent that stops leaves two things behind that nothing here
# reaped: its record under `~/.claude/jobs/<id>/`, which is what `claude agents
# --all` lists a stopped agent from, and its transcripts under
# `~/.claude/projects/`. Measured 2026-09-13 on Claude Code 2.1.228: `claude
# stop` writes `state: stopped` into the record, no subcommand removes it, and
# removing the directory is what clears the listing. The worktree went, the
# scratch went, the branch went, and every plan, build and review session of
# every card ever built stayed listed as a stopped agent -- and in the
# operator's session list -- forever.
#
# Ticket mode only, for the reason the slot is released here and nowhere else:
# the caller has just judged the card terminal, and a terminal card is the one
# whose sessions have no reader left. `--orphans` never forgets a session. A
# card that is not terminal may still be diagnosed from its transcript
# (reconcile.py's `death`) or resumed into it.
#
# Scoped three ways, each a rule this file already applies to worktrees:
# - by name prefix, so it is this instance's sessions for this ticket and never
#   a sibling board's, the tick's, or ABC-10's when asked about ABC-1;
# - only a session whose record says `stopped`, the tie-goes-to-leaving-it rule
#   --orphans applies to a worktree;
# - a transcript directory goes only when the session ran in one of this
#   instance's throwaway worktrees. A dispatch run by hand from the repository
#   root shares that directory with whoever else worked there, so its record
#   goes, its transcripts stay, and the sweep says so.
#
# The Python lists and the shell removes, so each can be read on its own. A
# listing that fails is held in `forget_status` and reported at the end, the
# way reap_evidence_refs is, so a record this cannot read costs the forgetting
# and never the slot release that follows it.
forget_status=0
forget_sessions() {
  local ticket="$1" jobs_dir="$HOME/.claude/jobs"
  local listing id state name cwd transcripts forgotten=0
  # Claude Code's own records. A codex or opencode agent's record belongs to
  # the adapter, under $FOREMAN_HOME/agents/, and `"$HARNESS_SH" reap` ages it
  # out on the orphan pass; there is no ~/.claude/jobs entry of this card's to
  # forget on those harnesses.
  [[ "$HARNESS" == claude ]] || return 0
  [[ -d "$jobs_dir" ]] || return 0
  if ! listing="$(python3 - "$jobs_dir" "$(card_agents_prefix "$ticket")" <<'PY'
import json, os, re, sys
jobs, prefix = sys.argv[1], sys.argv[2]
failed = 0
for short in sorted(os.listdir(jobs)):
    if not os.path.isdir(os.path.join(jobs, short)):
        continue
    path = os.path.join(jobs, short, "state.json")
    try:
        with open(path) as fh:
            record = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"foreman: could not read {path} ({exc}); leaving that session", file=sys.stderr)
        failed = 1
        continue
    if not isinstance(record, dict):
        print(f"foreman: {path} is not a JSON object; leaving that session", file=sys.stderr)
        failed = 1
        continue
    name = record.get("name") or ""
    if not name.startswith(prefix):
        continue
    cwd = record.get("cwd") or ""
    # Where Claude Code files the session's transcript: the cwd with every `/`
    # and `.` replaced by `-`, the same rule reconcile.py's transcript_path
    # applies.
    transcripts = os.path.join(os.path.expanduser("~/.claude/projects"), re.sub(r"[/.]", "-", cwd)) if cwd else ""
    print("\t".join([short, record.get("state") or "?", name, cwd, transcripts]))
sys.exit(failed)
PY
  )"; then
    forget_status=1
  fi
  while IFS=$'\t' read -r id state name cwd transcripts; do
    [[ -n "$id" ]] || continue
    [[ "$id" != */* && "$id" != .* ]] || die "refusing to remove $jobs_dir/$id -- not a session id"
    if [[ "$state" != "stopped" ]]; then
      printf 'foreman: leaving session %s (%s) -- it is not (yet) stopped\n' "$name" "$id" >&2
      continue
    fi
    if [[ -n "$BOARD_DRY_RUN" ]]; then
      printf 'DRY RUN: would forget session %s (%s)\n' "$name" "$id"
    else
      rm -rf "${jobs_dir:?}/${id:?}"
      printf 'forgot session %s (%s)\n' "$name" "$id"
      forgotten=$((forgotten + 1))
    fi
    remove_transcripts "$name" "$cwd" "$transcripts"
  done <<<"$listing"
  if [[ "$forgotten" -gt 0 ]]; then
    card_log "$ticket" "$(printf '{"action":"forgot","by":"sweep","sessions":%d}' "$forgotten")"
  fi
  return 0
}

# remove_transcripts <session name> <cwd it ran in> <its transcript directory>
remove_transcripts() {
  local name="$1" cwd="$2" dir="$3"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case "$dir" in
    "$HOME"/.claude/projects/?*) ;;
    *) die "refusing to remove $dir -- not a transcript directory" ;;
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
  rm -rf "$dir"
  printf 'removed transcripts %s\n' "$dir"
}

[[ "${1:-}" == "--orphans" || $# -gt 0 ]] || die "usage: sweep.sh <TICKET...> | --orphans"

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
  # The stops change the answer the liveness read above gave, so it is asked
  # again once they have landed -- and refused again if it cannot be read, for
  # the reason it was refused the first time.
  stop_card_agents "$@"
  if ! live_worktrees >"$LIVE_FILE"; then
    die "could not read live agents after stopping the cards' agents; refusing to sweep"
  fi
  for ticket in "$@"; do
    remove_tree_unless_live "$(worktree_path "$ticket")"
    for extra in "$REPO"/.claude/worktrees/"$BOARD_WORKTREE_PREFIX"-"$ticket"-*/; do
      [[ -d "$extra" ]] && remove_tree_unless_live "${extra%/}"
    done
    # Before the release, so `released` stays the card's last history line --
    # card_holds_slot reads only that one.
    forget_sessions "$ticket"
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
  || die "could not read every session record under $HOME/.claude/jobs (see above); a finished session may still be listed"
[[ "$stop_status" -eq 0 ]] \
  || die "a terminal card's agent did not stop (see above); its worktree, record and transcripts are left for a later sweep"
