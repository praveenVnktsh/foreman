#!/usr/bin/env bash
# Reap board worktrees for cards that are finished, and prune dead ones.
#
#   sweep.sh MUR-42 MUR-43        # tickets that are terminal; their trees go
#   sweep.sh --orphans            # board-* trees with no live agent
#
# Either way it also reaps `refs/foreman/<instance>/evidence/<pid>` refs left behind by an
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
    "$AGENT_TMP_ROOT"/foreman-"$INSTANCE"-*) ;;
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
    "$REPO"/.claude/worktrees/foreman-"$INSTANCE"-*) ;;
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
    foreman/"$INSTANCE"/*) git -C "$REPO" branch -D "$branch" 2>/dev/null || true ;;
  esac
  printf 'removed %s\n' "$path"
}

# Leaked `refs/foreman/<instance>/evidence/<pid>` refs, from `evidence.sh` invocations that
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
  if ! refs="$(git -C "$REPO" for-each-ref --format='%(refname)' "refs/foreman/$INSTANCE/evidence/*")"; then
    printf 'foreman: could not list refs/foreman/%s/evidence/* in %s; leaked evidence refs went unchecked\n' \
      "$INSTANCE" "$REPO" >&2
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
  claude agents --json --all 2>/dev/null | python3 -c '
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

"$SKILL_DIR/withlock.py" "$REPO/.git/board-worktree.lock" 120 -- true \
  || die "repository lock is held; skipping sweep this tick"

if [[ "${1:-}" == "--orphans" ]]; then
  LIVE_FILE="$(mktemp)"
  trap 'rm -f "$LIVE_FILE"' EXIT
  if ! live_worktrees >"$LIVE_FILE"; then
    die "could not read live agents; refusing to sweep orphans"
  fi
  for path in "$REPO"/.claude/worktrees/foreman-"$INSTANCE"-*/; do
    [[ -d "$path" ]] || continue
    path="${path%/}"
    grep -Fxq "$path" "$LIVE_FILE" || remove_tree "$path"
  done
  # Scratch whose worktree is already gone. The loop above only visits trees
  # that still exist, so a worktree reaped by an earlier sweep leaves its
  # scratch behind forever — which is precisely the accumulation this exists to
  # stop. Keyed on the worktree the scratch is named for, and still refusing to
  # act when that worktree is a live agent's cwd.
  for tmp in "$AGENT_TMP_ROOT"/foreman-"$INSTANCE"-*/; do
    [[ -d "$tmp" ]] || continue
    tmp="${tmp%/}"
    wt="$REPO/.claude/worktrees/$(basename "$tmp")"
    [[ -d "$wt" ]] && continue
    grep -Fxq "$wt" "$LIVE_FILE" && continue
    remove_agent_tmp "$tmp"
  done
else
  [[ $# -gt 0 ]] || die "usage: sweep.sh <TICKET...> | --orphans"
  for ticket in "$@"; do
    remove_tree "$(worktree_path "$ticket")"
    for extra in "$REPO"/.claude/worktrees/foreman-"$INSTANCE"-"$ticket"-*/; do
      [[ -d "$extra" ]] && remove_tree "${extra%/}"
    done
  done
fi

[[ -n "$BOARD_DRY_RUN" ]] || git -C "$REPO" worktree prune

# Held rather than propagated on the spot, so a reap that fails still leaves the
# rest of the sweep done: the review prune below is cheap, unrelated, and would
# otherwise stop running for as long as the ref problem lasts.
reap_status=0
reap_evidence_refs || reap_status=$?

# Reviews are regenerable; history.jsonl is the card's audit trail and stays.
find "$BOARD_HOME"/cards/*/reviews -type f -mtime +30 -delete 2>/dev/null || true

[[ "$reap_status" -eq 0 ]] \
  || die "could not reap leaked evidence refs (see above); refs/foreman/$INSTANCE/evidence/* is unswept"
