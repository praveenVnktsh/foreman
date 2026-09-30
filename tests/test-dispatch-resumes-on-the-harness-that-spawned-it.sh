#!/usr/bin/env bash
# Claim: `dispatch.sh --resume` resumes an agent on the harness its spawn row
# names, not on the installation's default harness.
#
# A tier may name a harness (`codex:<model>`), so a card's agent can run on
# codex while the installation's default is claude. The resume used to go to
# the default adapter whatever the spawn had used: it looked for the session in
# the wrong registry, and a card that only needed its fix applied went to a
# fresh attempt -- or, with a same-named session there, resumed the wrong one.
#
# The fixture spawns on claude, the default, and its stubbed registry answers
# for the name. Rewriting the spawn row's harness to codex is then the whole
# difference between the two runs: routed by the row, the resume reaches the
# codex adapter, which has no such agent and refuses; routed to the default, it
# reaches `claude --bg --resume` and succeeds.
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

history="$DISPATCH_HOME/.foreman/instances/demo/cards/HRN-1/history.jsonl"
resumed() { grep -qx -- '--resume' "$DISPATCH_ARGV_LOG"; }

dispatch_fixture_run --ticket HRN-1 --role build --attempt 1
grep -q '"harness":"claude"' "$history" && ok "the spawn row records the harness it spawned on" \
  || { bad "the spawn row records the harness it spawned on: $(cat "$history")"; dispatch_fixture_show_run_log; }

dispatch_fixture_resume --ticket HRN-1 --role build --attempt 1 --reason fix
resumed && ok "an agent spawned on the default harness resumes there" \
  || { bad "an agent spawned on the default harness resumes there"; dispatch_fixture_show_run_log; }

sed -i.bak 's/"harness":"claude"/"harness":"codex"/' "$history"
rows_before="$(grep -c '"action":"resume"' "$history")"
dispatch_fixture_resume --ticket HRN-1 --role build --attempt 1 --reason fix
if resumed; then
  bad "an agent whose spawn row names codex was resumed on the default harness, claude"
else
  ok "an agent whose spawn row names codex is not resumed on the default harness"
fi
[[ "$(grep -c '"action":"resume"' "$history")" == "$rows_before" ]] \
  && ok "and the refused resume writes no resume row" \
  || bad "a resume row was written for a resume that never ran: $(tail -1 "$history")"

[[ "$fail" -eq 0 ]] && printf 'PASS: dispatch resumes on the harness that spawned it\n'
exit "$fail"
