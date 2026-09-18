#!/usr/bin/env bash
# A stage whose model is rate-limited falls back one tier and keeps
# dispatching, instead of voiding every card that needs it on every pass.
#
# On 2026-09-16 the plan stage stayed on a rate-limited PLAN_MODEL=fable for 11
# hours: every plan agent died at once, and every pass re-dispatched the next
# one onto the same limited model. skills/board/fallback.py is what dispatch.sh
# now asks for the model; which tier it picks, and the floor and cooldown rules
# behind that, are test-fallback-picks-the-next-tier.sh's claim, driving
# fallback.py directly. This test drives dispatch.sh instead, and proves three
# things fallback.py cannot prove about itself: dispatch.sh actually calls it
# for a fresh spawn, the spawn record it writes carries both the model it ran
# on and the model the role would have run on with no rate limit, and it says
# so on stderr when the two differ.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

check_model() { # description expected-repr
  local desc="$1" want="$2" got
  got="$(dispatch_fixture_model)"
  if [[ -z "$got" ]]; then
    bad "$desc: the dispatch never reached \`claude --bg --model\`"
    dispatch_fixture_show_run_log
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected --model $want, got $got"
  fi
}

# mark_limited <model> -- writes the exact stamp a tick's own
# `fallback.py mark` would, straight into this fixture's FOREMAN_HOME, so a
# dispatch that follows reads state a real rate-limit death would have left
# behind. Nothing here is stubbed: `mark` and the dispatch below share the
# same real fallback.py and the same real stamp file.
mark_limited() {
  env -i PATH="$PATH" FOREMAN_HOME="$DISPATCH_HOME/.foreman" \
    "$repo_root/skills/board/fallback.py" mark "$1" >/dev/null
}

history_for() { printf '%s/.foreman/instances/demo/cards/%s/history.jsonl\n' "$DISPATCH_HOME" "$1"; }

# spawn_has <ticket> <needle> -- whether <ticket>'s NEWEST spawn entry
# contains <needle> verbatim. Newest, not "any": a ticket dispatched twice in
# this file carries both attempts in one history.jsonl, and only the latest is
# ever this assertion's business.
spawn_has() {
  local ticket="$1" needle="$2" file
  file="$(history_for "$ticket")"
  [[ -f "$file" ]] && grep '"action":"spawn"' "$file" | tail -1 | grep -qF "$needle"
}

show_history() { # ticket
  local file
  file="$(history_for "$1")"
  [[ -f "$file" ]] && cat "$file" >&2
}

dispatch_fixture_run --ticket PRA-1 --role plan --attempt 1
check_model "with no stamps, a plan dispatch runs on fable" "'fable'"
if spawn_has PRA-1 '"model":"fable"' && spawn_has PRA-1 '"first_choice":"fable"'; then
  ok "the spawn entry carries model fable and first_choice fable"
else
  bad "the spawn entry carries model fable and first_choice fable"
  show_history PRA-1
fi
# No fallback happened, so there is nothing to say about it.
if grep -q 'rate-limited' "$DISPATCH_RUN_LOG"; then
  bad "an unlimited first choice prints no rate-limit warning"
else
  ok "an unlimited first choice prints no rate-limit warning"
fi

mark_limited fable

dispatch_fixture_run --ticket PRA-2 --role plan --attempt 1
check_model "with fable rate-limited, a plan dispatch runs on opus" "'opus'"
if spawn_has PRA-2 '"model":"opus"' && spawn_has PRA-2 '"first_choice":"fable"'; then
  ok "the spawn entry carries model opus and first_choice fable"
else
  bad "the spawn entry carries model opus and first_choice fable"
  show_history PRA-2
fi
if grep -q 'plan model fable is rate-limited until' "$DISPATCH_RUN_LOG" &&
   grep -q 'running on opus' "$DISPATCH_RUN_LOG"; then
  ok "stderr names the limited model, until when, and what it dispatched on instead"
else
  bad "stderr names the limited model, until when, and what it dispatched on instead"
  dispatch_fixture_show_run_log
fi

# A board that would rather wait than run its plan stage below fable declares
# exactly this floor. fable is still the only stamp on file, so the walk has
# nowhere allowed to go and the dispatch still spawns on fable -- the floor,
# not a fallback -- which is what lets the board void exactly as it does today.
export PLAN_FLOOR=fable
dispatch_fixture_run --ticket PRA-3 --role plan --attempt 1
check_model "with PLAN_FLOOR=fable and fable still limited, a plan dispatch stays on fable" "'fable'"
if spawn_has PRA-3 '"model":"fable"' && spawn_has PRA-3 '"first_choice":"fable"'; then
  ok "the floored spawn entry carries model fable and first_choice fable"
else
  bad "the floored spawn entry carries model fable and first_choice fable"
  show_history PRA-3
fi
unset PLAN_FLOOR

[[ "$fail" -eq 0 ]] && printf 'PASS: dispatch spawns on the fallback tier\n'
exit "$fail"
