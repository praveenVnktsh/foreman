#!/usr/bin/env bash
# With `routing = "project"`, a project-level installation takes every card its
# board's tick hands it, whatever label it carries. There is one installation
# per project, so a `foreman:<name>` label is decoration and must not drop a
# card; under the default label routing the same card is a sibling's and is
# dropped. See docs/specs/2026-09-18-project-level-installs-design.md.
#
# Drives the real queue.py over a pipe. No fixture instance, no git repository.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
queue="$root/skills/board/queue.py"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

args=(--installation claude --default --siblings claude)
card='[{"identifier":"PRA-1","priority":1,"labels":{"nodes":[{"name":"foreman:codex"}]}}]'

out="$(printf '%s' "$card" | "$queue" "${args[@]}" 2>/dev/null)"
[[ -z "$out" ]] && ok "label routing drops a sibling's card" || bad "label routing kept it: $out"

out="$(printf '%s' "$card" | ROUTING=project "$queue" "${args[@]}" 2>&1)"
[[ "$out" == "PRA-1" ]] && ok "project routing keeps a sibling-labelled card" || bad "project routing gave: $out"

# A card labelled for nobody is a sibling's under label routing too, and the
# project installation still owns it.
unlabelled='[{"identifier":"PRA-2","priority":2,"labels":{"nodes":[]}}]'
out="$(printf '%s' "$unlabelled" | ROUTING=project "$queue" "${args[@]}" 2>&1)"
[[ "$out" == "PRA-2" ]] && ok "project routing keeps an unlabelled card" || bad "project routing gave: $out"

exit "$fail"
