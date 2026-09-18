#!/usr/bin/env bash
# The one adapter every reader talks to, across harnesses.
#
#   registry.sh list                          every agent, from every harness
#   registry.sh stop <id>                     stop the agent, on its harness
#   registry.sh reap <older-than-seconds>     reap finished agents, every harness
#   registry.sh transcript <cwd> <session>    the transcript's path
#   registry.sh spawn|resume|check|skills-dir|skill-prompt ...
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
# that select a HARNESS rather than an agent -- spawn, resume, check,
# skills-dir, skill-prompt -- are the installation's default harness, because
# there is no agent yet to say which one. dispatch.sh resolves the spawn's
# harness itself, per candidate, and does not come through here.
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

case "$verb" in
  list)
    # Each adapter prints one JSON array. Merge and dedupe by id: Codex and
    # OpenCode read the same detached registry, so without this every agent
    # would appear once per harness that shares it.
    tmp="$(mktemp)" || exit 1
    : >"$tmp"
    # AN UNREADABLE REGISTRY IS NOT AN EMPTY ONE. If any adapter in the set
    # fails to list -- a daemon mid-restart, a CLI mid-upgrade, a corrupt
    # record -- this refuses rather than reporting the agents it could read.
    # The old single-adapter path refused for the same reason, and a merged
    # list that dropped the failed harness would start a second agent beside a
    # live one it could not see.
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      if ! out="$("$sh" list)"; then
        rm -f "$tmp"
        printf 'foreman: harness %s could not read its agent registry\n' "$harness" >&2
        exit 1
      fi
      printf '%s\n' "$out" >>"$tmp"
    done
    python3 - "$tmp" <<'PY'
import json, sys
rows = {}
with open(sys.argv[1]) as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            batch = json.loads(line)
        except ValueError as exc:
            sys.exit("foreman: an agent registry is not readable JSON: %s" % exc)
        if not isinstance(batch, list):
            sys.exit("foreman: an agent registry is not a JSON list")
        for row in batch:
            rows[row.get("id") or id(row)] = row
print(json.dumps(sorted(rows.values(), key=lambda r: r.get("startedAt") or 0)))
PY
    rm -f "$tmp"
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
  reap)
    [[ $# -eq 1 ]] || { printf 'foreman: registry.sh reap takes older-than-seconds\n' >&2; exit 1; }
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      "$sh" reap "$1" 2>/dev/null || true
    done
    ;;
  transcript)
    [[ $# -eq 2 ]] || { printf 'foreman: registry.sh transcript takes <cwd> <session>\n' >&2; exit 1; }
    for harness in $adapters; do
      sh="$(adapter_for "$harness")"
      [[ -x "$sh" ]] || continue
      if out="$("$sh" transcript "$1" "$2" 2>/dev/null)"; then
        printf '%s\n' "$out"
        exit 0
      fi
    done
    printf 'foreman: no harness has a transcript for session %s\n' "$2" >&2
    exit 1
    ;;
  *)
    # spawn, resume, check, skills-dir, skill-prompt: the harness-shaped verbs.
    exec "$(adapter_for "$default")" "$verb" "$@"
    ;;
esac
