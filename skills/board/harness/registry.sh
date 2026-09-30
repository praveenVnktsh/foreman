#!/usr/bin/env bash
# The one adapter every reader talks to, across harnesses.
#
#   registry.sh list                          every agent, from every harness
#   registry.sh stop <id>                     stop the agent, on its harness
#   registry.sh forget <id>                   delete one finished agent's record
#   registry.sh reap <older-than-seconds>     reap finished agents, every harness
#   registry.sh transcript <cwd> <session>    the transcript's path
#   registry.sh resume [--harness H] --name N ...
#                                             the harness that owns agent N,
#                                             or H when the caller names it
#   registry.sh spawn|check|skills-dir|skill-prompt ...
#                                             the installation's own harness
#
# AN INSTALLATION MAY SPAWN ON MORE THAN ONE HARNESS. A stage's candidates can
# name a harness (`opencode:foundry/gpt-5.6-sol`), so an installation that
# falls back across CLIs leaves agents in more than one registry: Codex and
# OpenCode share `harness/detached.sh`'s `$FOREMAN_HOME/agents`, and Claude
# keeps its own daemon. Readers used to call `$HARNESS_SH list`, one adapter,
# and would have seen only the harness that happened to be named there.
#
# config.sh sets `HARNESS_SH` to this file, so every reader gets the merged
# view by asking for it in exactly the shape it already asked in. The verbs
# that select a HARNESS rather than an agent -- spawn, check, skills-dir,
# skill-prompt -- are the installation's default harness, because there is no
# agent yet to say which one. dispatch.sh resolves the spawn's harness itself,
# per candidate, and does not come through here.
#
# `resume` names an agent, so it goes to the harness that owns it. It used to
# go to the default harness, and a build that fell back to a second harness
# was then resumed on the first: `no agent named N to resume`, or worse, a
# Codex session id handed to OpenCode.
#
# `FOREMAN_HARNESSES` is the set to merge, `FOREMAN_DEFAULT_HARNESS` the one
# that answers the harness-shaped verbs. config.sh computes both from the
# stage candidates.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

default="${FOREMAN_DEFAULT_HARNESS:-}"
[[ -n "$default" ]] || {
  printf 'foreman: registry.sh needs FOREMAN_DEFAULT_HARNESS; source skills/board/config.sh first\n' >&2
  exit 1
}
adapters="${FOREMAN_HARNESSES:-$default}"

verb="${1:-}"
[[ -n "$verb" ]] || { printf 'foreman: registry.sh needs a verb\n' >&2; exit 1; }
shift

adapter_for() { printf '%s/%s.sh' "$DIR" "$1"; }

# Every adapter's listing into <file>, one `<harness> <json list>` line each.
#
# AN UNREADABLE REGISTRY IS NOT AN EMPTY ONE. If any adapter in the set fails
# to list -- a daemon mid-restart, a CLI mid-upgrade, a corrupt record -- this
# refuses rather than reporting the agents it could read. The old
# single-adapter path refused for the same reason, and a merged list that
# dropped the failed harness would start a second agent beside a live one it
# could not see.
collect_listings() { # <file>
  local harness sh out
  : >"$1"
  for harness in $adapters; do
    sh="$(adapter_for "$harness")"
    [[ -x "$sh" ]] || continue
    if ! out="$("$sh" list)"; then
      printf 'foreman: harness %s could not read its agent registry\n' "$harness" >&2
      return 1
    fi
    printf '%s %s\n' "$harness" "$out" >>"$1"
  done
}

# The listings as (harness, row) pairs, first harness first. Printed by a
# function for the reason detached.sh gives for its own python.
listings_py() {
  cat <<'PY'
import json, sys


def tagged_rows(path):
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            harness, _, listing = line.partition(" ")
            try:
                batch = json.loads(listing)
            except ValueError as exc:
                sys.exit("foreman: an agent registry is not readable JSON: %s" % exc)
            if not isinstance(batch, list):
                sys.exit("foreman: an agent registry is not a JSON list")
            for row in batch:
                if isinstance(row, dict):
                    yield harness, row
PY
}

case "$verb" in
  list)
    # Each adapter prints one JSON array. Merge and dedupe by id: Codex and
    # OpenCode read the same detached registry, so without this every agent
    # would appear once per harness that shares it.
    tmp="$(mktemp)" || exit 1
    collect_listings "$tmp" || { rm -f "$tmp"; exit 1; }
    python3 -c "$(listings_py)"'
rows = {}
for _harness, row in tagged_rows(sys.argv[1]):
    rows[row.get("id") or id(row)] = row
print(json.dumps(sorted(rows.values(), key=lambda r: r.get("startedAt") or 0)))
' "$tmp" || { rm -f "$tmp"; exit 1; }
    rm -f "$tmp"
    ;;
  resume)
    # `--harness H` first, when the caller already knows the owner: dispatch.sh
    # resolved it at spawn. Otherwise the owner is the harness listing the
    # NEWEST agent of that name, the same newest-wins rule every adapter's own
    # resume applies inside its registry. A detached row names its harness
    # itself, because Codex and OpenCode both list it; any other row belongs to
    # the adapter that listed it. No owner at all goes to the default harness,
    # whose resume then says there is no such agent in its own words.
    if [[ "${1:-}" == "--harness" ]]; then
      [[ $# -ge 2 && -n "$2" ]] || { printf 'foreman: registry.sh resume --harness needs a harness name\n' >&2; exit 1; }
      owner="$2"
      shift 2
    else
      name=""
      prev=""
      for arg in "$@"; do
        [[ "$prev" == "--name" ]] && name="$arg"
        prev="$arg"
      done
      [[ -n "$name" ]] || { printf 'foreman: registry.sh resume needs --name to find the harness that owns the agent\n' >&2; exit 1; }
      tmp="$(mktemp)" || exit 1
      collect_listings "$tmp" || { rm -f "$tmp"; printf 'foreman: cannot tell which harness owns %s\n' "$name" >&2; exit 1; }
      owner="$(python3 -c "$(listings_py)"'
want = sys.argv[2]
best = None
for harness, row in tagged_rows(sys.argv[1]):
    if row.get("name") != want:
        continue
    if best is None or (row.get("startedAt") or 0) > (best[1].get("startedAt") or 0):
        best = (row.get("harness") or harness, row)
print(best[0] if best else "")
' "$tmp" "$name")" || { rm -f "$tmp"; exit 1; }
      rm -f "$tmp"
      [[ -n "$owner" ]] || owner="$default"
    fi
    # A bare name, because it becomes a path beside this file; the record it
    # may have come from is a file anyone with the home can write.
    [[ "$owner" =~ ^[a-z0-9_-]+$ ]] || { printf 'foreman: %s is not a harness name\n' "$owner" >&2; exit 1; }
    sh="$(adapter_for "$owner")"
    [[ -x "$sh" ]] || { printf 'foreman: no harness adapter %s at %s\n' "$owner" "$sh" >&2; exit 1; }
    exec "$sh" resume "$@"
    ;;
  stop)
    [[ $# -eq 1 ]] || { printf 'foreman: registry.sh stop takes one id\n' >&2; exit 1; }
    id="$1"
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      if "$sh" stop "$id" >/dev/null 2>&1; then exit 0; fi
    done
    printf 'foreman: no harness owns agent %s\n' "$id" >&2
    exit 1
    ;;
  forget)
    # Mirrors stop's shape, but the adapter's own stderr is left alone: a
    # refusal (working, missing) is the message sweep.sh shows the operator,
    # not noise to hide. Only one adapter normally owns a given id, so the
    # adapters that do not tend to say nothing rather than "missing".
    [[ $# -eq 1 ]] || { printf 'foreman: registry.sh forget takes one id\n' >&2; exit 1; }
    id="$1"
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      if "$sh" forget "$id"; then exit 0; fi
    done
    printf 'foreman: no harness owns agent %s\n' "$id" >&2
    exit 1
    ;;
  reap)
    # AN ADAPTER THAT FAILS TO REAP IS NOT NOTHING TO REAP. The old loop threw
    # away every adapter's exit code and stderr, so a `claude rm` that failed
    # partway through a reap looked identical to a clean pass -- sweep.sh's
    # ticket-mode caller had no way to tell the operator a session was stuck.
    # Run every adapter regardless, and fail loud if any of them did.
    [[ $# -eq 1 ]] || { printf 'foreman: registry.sh reap takes older-than-seconds\n' >&2; exit 1; }
    failed=0
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      "$sh" reap "$1" || failed=1
    done
    exit "$failed"
    ;;
  transcript)
    # A path that EXISTS wins, whichever harness gives it. claude.sh used to
    # compose its path for any session id at all, so the first harness in the
    # set answered for every agent, and an agent that fell back to Codex was
    # read through a Claude path that never existed: no idle time, and a sweep
    # that removed the wrong directory. Now claude.sh exits non-zero for a
    # file that is not there, and the next harness is asked.
    #
    # Second, a path an adapter vouched for (exit 0) that is not there yet:
    # a detached agent's log, named by its own record.
    #
    # Last, a path an adapter printed while exiting non-zero: where Claude
    # WOULD keep the file. It is printed, and this still exits 1. supervise.sh
    # reads it to see that a registered tick's transcript is gone, which is
    # how it tells a corpse from a tick; reconcile.py and sweep.sh read only
    # the exit code.
    [[ $# -eq 2 ]] || { printf 'foreman: registry.sh transcript takes <cwd> <session>\n' >&2; exit 1; }
    vouched=""
    composed=""
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      if out="$("$sh" transcript "$1" "$2" 2>/dev/null)"; then
        if [[ -n "$out" && -e "$out" ]]; then
          printf '%s\n' "$out"
          exit 0
        fi
        [[ -n "$vouched" ]] || vouched="$out"
      elif [[ -n "$out" && -z "$composed" ]]; then
        composed="$out"
      fi
    done
    if [[ -n "$vouched" ]]; then
      printf '%s\n' "$vouched"
      exit 0
    fi
    printf 'foreman: no harness has a transcript for session %s\n' "$2" >&2
    [[ -z "$composed" ]] || printf '%s\n' "$composed"
    exit 1
    ;;
  *)
    # spawn, check, skills-dir, skill-prompt: the harness-shaped verbs.
    exec "$(adapter_for "$default")" "$verb" "$@"
    ;;
esac
