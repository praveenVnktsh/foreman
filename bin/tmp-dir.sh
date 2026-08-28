#!/usr/bin/env bash
# Where a checkout's test scratch goes. One derivation, printed for its callers.
#
#   ops/tmp-dir.sh              the scratch dir paired with the checkout this
#                               script is committed to
#   ops/tmp-dir.sh <worktree>   the scratch dir paired with that worktree
#   ops/tmp-dir.sh --root       the root those live under
#
# `/tmp` on the dev host is a tmpfs sized at half of RAM under a per-user quota
# that refuses writes around 5.5GB, so it is RAM that competes with the agents
# doing the work: one `just test-all` leaves ~725MB of test vaults under it, two
# builds died with EDQUOT mid-run, and 2.1GB of stale vaults were found sitting
# in memory on 2026-08-02. The root disk has 336GB.
#
# This file exists because that path had two authors. The `justfile` computed it
# for the TMPDIR its test recipes export, the board's `config.sh` computed it
# again for the scratch it creates at dispatch and reaps in `sweep.sh`, and the
# two agreed only because two hardcoded strings happened to match -- under
# *different* environment variables, so overriding either moved the writes
# without moving the reaper and nothing failed. The scratch would simply have
# accumulated forever, which is the failure mode this whole path exists to stop.
#
# Prints only; it never creates anything. Callers mkdir, because a TMPDIR
# pointing at a directory that does not exist makes `tempfile` raise rather than
# fall back -- and because the reaper must be able to name a directory that is
# already gone. Nor does it require its argument to exist: `sweep.sh` asks for
# the scratch belonging to a worktree precisely when that worktree is missing.
#
# See design/build_system.md.

set -euo pipefail

root="${FOREMAN_TMP_ROOT:-${BOARD_HOME:-$HOME/.foreman}/tmp}"

case "${1:-}" in
  --root)
    printf '%s\n' "$root"
    ;;
  "")
    # Keyed on this script's own checkout, never on the environment. Each board
    # agent works in its own git worktree carrying its own copy of this file, so
    # the worktree it sits in is the one per-agent fact that cannot go stale. A
    # background agent inherits its environment from the shared `claude daemon`
    # rather than from whatever spawned it -- measured 2026-08-02, when a
    # reviewer and an unrelated ticket's build both reported the same TICKET.
    printf '%s/%s\n' "$root" \
      "$(basename -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)")"
    ;;
  -*)
    printf 'tmp-dir.sh: unknown option %s\n' "$1" >&2
    exit 2
    ;;
  *)
    # Named for the worktree, so a sweep that reaps the worktree can reap the
    # scratch without tracking anything.
    printf '%s/%s\n' "$root" "$(basename -- "$1")"
    ;;
esac
