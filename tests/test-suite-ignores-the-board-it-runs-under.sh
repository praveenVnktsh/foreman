#!/usr/bin/env bash
# Claim: the six tests that read a board's values pass in an environment that
# holds one, the way every card agent's does -- through tests/run-all.sh, and
# run directly with `bash`.
#
# dispatch.sh pins FOREMAN_INSTANCE, FOREMAN_CONFIG_INSTANCE and every name in
# FOREMAN_BOARD_EXPORTS into a card agent's environment (PRA-517). Measured
# 2026-09-25: with those inherited, run-all.sh exited 1 on a correct build
# (PRA-575). Measured 2026-09-28: the six tests named below failed run directly,
# because only run-all.sh cleared the board (PRA-586). Each now sources
# tests/lib/without-board.sh. CI runs with a clean environment, so only this
# test shows the leak there.
set -uo pipefail

# This test runs run-all.sh, so a run-all.sh that ignores the names it is given
# runs this test again, forever. Refuse the second level instead.
if [[ -n "${SUITE_IGNORES_BOARD_NESTED:-}" ]]; then
  printf 'FAIL run-all.sh ran a test it was not named\n' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# A stale board: every name dispatch pins, pointing somewhere no test expects.
stale_home="$work/.foreman/instances/stale"
mkdir -p "$stale_home" "$work/stale-repo"
stale_env=(
  FOREMAN_INSTANCE=stale
  FOREMAN_CONFIG_INSTANCE=stale
  REPO="$work/stale-repo"
  KEY_FILE="$work/.foreman/stale.key"
  INSTANCE=stale
  INSTANCE_HOME="$stale_home"
  BOARD_HOME="$stale_home"
  BOARD_NAME_PREFIX=stale-prefix
  BOARD_WORKTREE_PREFIX=stale-worktree
)

# The list above must cover config.sh's, or a name added there goes untested.
declared="$(sed -n 's/^FOREMAN_BOARD_EXPORTS="\([^"]*\)"$/\1/p' "$repo_root/skills/board/config.sh")"
[[ -n "$declared" ]] || bad "could not read FOREMAN_BOARD_EXPORTS from config.sh"
for name in $declared; do
  case " ${stale_env[*]} " in
    *" $name="*) ;;
    *) bad "the stale board leaves $name unset; add it here" ;;
  esac
done

env_reading_tests=(
  test-tmp-dir.sh
  test-config-resolves-instance.sh
  test-brief-uses-the-contract.sh
  test-preflight-fetches-only-to-gate.sh
  test-sweep-reaps-leaked-evidence-refs.sh
  test-evidence-reads-are-fresh.sh
)

out="$work/run-all.out"
if env "${stale_env[@]}" SUITE_IGNORES_BOARD_NESTED=1 bash "$repo_root/tests/run-all.sh" \
    "${env_reading_tests[@]}" >"$out" 2>&1; then
  ok "run-all.sh passes the six env-reading tests under a stale board"
else
  bad "run-all.sh failed under a stale board's environment"
  grep -E 'FAIL|^==' "$out" >&2
fi

# An agent iterating on one test runs it the usual way, not through run-all.sh.
# Each must clear the board itself, or it fails on a correct build.
for name in "${env_reading_tests[@]}"; do
  out="$work/direct-$name.out"
  if env "${stale_env[@]}" bash "$repo_root/tests/$name" >"$out" 2>&1; then
    ok "$name passes run directly under a stale board"
  else
    bad "$name failed run directly under a stale board"
    grep -E 'FAIL|contract:' "$out" >&2
  fi
done

# A named test that does not exist must refuse, not pass having run nothing.
if SUITE_IGNORES_BOARD_NESTED=1 bash "$repo_root/tests/run-all.sh" test-no-such-test.sh >/dev/null 2>&1; then
  bad "run-all.sh passed naming a test that does not exist"
else
  ok "run-all.sh refuses a test name it cannot find"
fi

exit "$fail"
