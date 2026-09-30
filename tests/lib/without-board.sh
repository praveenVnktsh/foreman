#!/usr/bin/env bash
# Sourced, not run: clears the board a test inherits, so the test sees the
# clean environment CI gives it.
#
# dispatch.sh pins FOREMAN_INSTANCE, FOREMAN_CONFIG_INSTANCE and every name in
# FOREMAN_BOARD_EXPORTS into a card agent's environment, and config.sh
# is environment-wins. A test that reads those values takes them for an
# operator's, and fails on a correct build. run-all.sh
# sources this before running anything; a test that reads the environment
# sources it too, so running it directly with `bash` gives the same answer.
#
# The names come from config.sh's declaration, never a copy here: a copy misses
# the next name added there. Parsed, not sourced, because sourcing config.sh
# needs a declared board and CI has none. An empty list would let the leak back
# in without a word, so anything but exactly one non-empty declaration, or a
# name that is not a variable, exits the caller.

without_board_config_sh="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/skills/board/config.sh"
without_board_exports="$(sed -n 's/^FOREMAN_BOARD_EXPORTS="\([^"]*\)"$/\1/p' "$without_board_config_sh" 2>/dev/null)"
if [[ -z "$without_board_exports" || "$without_board_exports" == *$'\n'* ]]; then
  printf 'without-board: cannot read one FOREMAN_BOARD_EXPORTS="..." line from %s\n' "$without_board_config_sh" >&2
  exit 1
fi
for without_board_name in $without_board_exports; do
  if [[ ! "$without_board_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf 'without-board: FOREMAN_BOARD_EXPORTS in %s names %q, not a variable\n' "$without_board_config_sh" "$without_board_name" >&2
    exit 1
  fi
done
# shellcheck disable=SC2086 # the list is split on purpose, each name checked above
unset FOREMAN_INSTANCE FOREMAN_CONFIG_INSTANCE $without_board_exports
unset without_board_config_sh without_board_exports without_board_name
