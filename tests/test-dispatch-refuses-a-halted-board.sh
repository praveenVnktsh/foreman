#!/usr/bin/env bash
# Claim: dispatch.sh refuses to spawn or resume anything for a board whose HALT
# file exists, says the refusal is not the ticket's failure, and exits with its
# own status (3), apart from every other failure (1).
#
# `boardctl halt` writes instances/<board>/HALT, and SKILL.md tells the tick to
# skip a halted board. That was prose: a resume, a fix-dispatch or a hand-run
# dispatch reached a spawn on a board the operator had stopped.
#
# Drives the real dispatch.sh through tests/lib/dispatch-fixture.sh; `claude`
# is the only external boundary stubbed.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

halt="$DISPATCH_HOME/.foreman/instances/demo/HALT"
history="$DISPATCH_HOME/.foreman/instances/demo/cards/HLT-1/history.jsonl"

# A spawn before the halt, so there is an agent a resume could reach.
dispatch_fixture_run --ticket HLT-1 --role build --attempt 1
[[ -s "$DISPATCH_ARGV_LOG" ]] && ok "an unhalted board dispatches" \
  || { bad "an unhalted board dispatches"; dispatch_fixture_show_run_log; }
rows_before="$(wc -l <"$history" | tr -d ' ')"

: >"$halt"

# dispatch_fixture_run as the fixture runs it, printing the exit status the
# fixture swallows. The registry stub keeps answering for the spawned agent.
status_of() {
  local toolchain=() name
  : >"$DISPATCH_ARGV_LOG"
  _dispatch_ensure_toolchain
  for name in $_DISPATCH_TOOLCHAIN; do
    if [[ -n "${!name+set}" ]]; then toolchain+=("$name=${!name}"); fi
  done
  env -i HOME="$DISPATCH_HOME" FOREMAN_INSTANCE=demo FOREMAN_HOME="$DISPATCH_HOME/.foreman" \
    MAX_CONCURRENT=9 HOST_MAX_CONCURRENT=9 PATH="$_DISPATCH_STUB_BIN:$PATH" \
    ${toolchain[@]+"${toolchain[@]}"} \
    "$DISPATCH" "$@" --prompt-file "$DISPATCH_PROMPT" >"$DISPATCH_RUN_LOG" 2>&1
  echo $?
}

rc="$(status_of --ticket HLT-2 --role build --attempt 1)"
[[ ! -s "$DISPATCH_ARGV_LOG" ]] && ok "a halted board spawns nothing" \
  || bad "a halted board spawned: $(tr '\n' ' ' <"$DISPATCH_ARGV_LOG")"
grep -q 'NOT a failure of ticket HLT-2' "$DISPATCH_RUN_LOG" \
  && grep -q 'is halted' "$DISPATCH_RUN_LOG" \
  && ok "the refusal names the halt and spares the ticket" \
  || { bad "the refusal names the halt and spares the ticket"; dispatch_fixture_show_run_log; }
[[ "$rc" == 3 ]] && ok "a halted board refuses with exit 3" || bad "a halted board refused with exit $rc, not 3"

rc="$(status_of --ticket HLT-1 --role build --attempt 1 --resume --reason fix)"
[[ ! -s "$DISPATCH_ARGV_LOG" ]] && ok "a halted board resumes nothing" \
  || bad "a halted board resumed: $(tr '\n' ' ' <"$DISPATCH_ARGV_LOG")"
[[ "$(wc -l <"$history" | tr -d ' ')" == "$rows_before" ]] \
  && ok "and writes nothing to the card's history" \
  || bad "the refused resume wrote history: $(cat "$history")"

rm -f "$halt"
dispatch_fixture_run --ticket HLT-3 --role build --attempt 1
[[ -s "$DISPATCH_ARGV_LOG" ]] && ok "the board dispatches again once HALT is gone" \
  || { bad "the board dispatches again once HALT is gone"; dispatch_fixture_show_run_log; }

[[ "$fail" -eq 0 ]] && printf 'PASS: dispatch refuses a halted board\n'
exit "$fail"
