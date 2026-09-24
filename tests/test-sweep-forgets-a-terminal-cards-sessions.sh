#!/usr/bin/env bash
# Claim: sweeping a terminal card forgets its exited sessions without stopping
# them, stops its idle agents and then forgets them, and frees their worktrees in
# the same sweep. `--orphans` never stops or forgets, but ages exited rows out
# after SWEEP_RETENTION_DAYS, and their trees follow on the next orphan pass.
#
# Measured 2026-09-23 on Claude Code 2.1.280, on the production host: a
# finished `claude --bg` agent EXITS. Its row stays `done` (or `stopped`,
# `blocked`, `failed`) with `pid: null`. `claude stop <id>` on such a row
# prints `stopped <id>`, exits 0 and changes nothing. `claude rm <id>` removes
# the row and `~/.claude/jobs/<id>`, and leaves the git worktree and the
# transcripts under `~/.claude/projects`. Before the fix, ticket mode re-issued
# a stop on every exited `done` row for 30s, reported "did not land", and
# exited 1 on every board on every pass. `--orphans` reaped nothing, because
# the claude adapter's reap was a no-op. One board piled up 72 trees, 261G.
#
# The scoping rules are the ones the sweep already lives by:
# - only this instance's agents, by name prefix, so two boards sharing a
#   machine cannot stop or forget each other's sessions;
# - an exited row (no pid, not working) is forgotten; an idle row (a pid,
#   `done` or `blocked`) is stopped first; a `working` agent is left alone,
#   because the caller's judgment that the card is terminal may be stale;
# - a transcript directory goes only when the session ran in one of this
#   instance's own throwaway worktrees. Anywhere else is shared with whoever
#   else worked there, so that directory stays and the sweep says so;
# - `--orphans` never stops or forgets a session, because a card that is not
#   yet terminal may still be diagnosed from its transcript (reconcile.py's
#   `death`) or resumed into it. Its reap takes only exited rows past the
#   retention window.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"; target="$work/target"
mkdir -p "$target"
git init -q -b main "$target"
fixture_board_toml "$target"
fixture_add_board "$home" alpha "$target"
fixture_add_board "$home" beta "$target"

wt() { printf '%s/.claude/worktrees/foreman-%s-%s\n' "$target" "$1" "$2"; }
# The slug Claude Code files a transcript under: `/` and `.` become `-`.
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

# startedAt is epoch milliseconds, as `claude agents --json` reports it.
now_ms=$(( $(date +%s) * 1000 ))
day_ms=$(( 24 * 60 * 60 * 1000 ))

# The stubbed `claude` is the external boundary, and it behaves as 2.1.280 was
# measured to. Its registry is one file per agent under STUB_REGISTRY,
# `<name><TAB><state><TAB><cwd><TAB><pid or null><TAB><startedAt>`.
# - `agents --json --all` renders it.
# - `stop <id>` moves a row that has a pid to `stopped` with no pid, there and
#   in its record under ~/.claude/jobs. On a row with no pid it does nothing
#   and exits 0. STUB_STOP_IS_IGNORED makes every stop do nothing.
# - `rm <id>` deletes the row and its ~/.claude/jobs record, and leaves the
#   worktree and the transcripts.
# Nothing here asserts on the stub; the assertions are on what the sweep left
# on disk and what it said.
export STUB_REGISTRY="$work/registry" STUB_JOBS="$home/.claude/jobs"
mkdir -p "$STUB_REGISTRY"
jobs="$STUB_JOBS"; projects="$home/.claude/projects"
# agent <id> <name> <state> <pid|null> <cwd> [startedAt] -- one background
# session as Claude Code holds it: a registry row, a record, and a transcript
# directory. It started now unless told otherwise.
agent() {
  local started="${6:-$now_ms}"
  mkdir -p "$jobs/$1" "$projects/$(slug "$5")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$5" "$4" "$started" > "$STUB_REGISTRY/$1"
  printf '{"state":"%s","pid":%s,"name":"%s","cwd":"%s","sessionId":"%s-sid"}\n' \
    "$3" "$4" "$2" "$5" "$1" > "$jobs/$1/state.json"
  printf '{"type":"summary"}\n' > "$projects/$(slug "$5")/$1-sid.jsonl"
}
listed() { [[ -f "$STUB_REGISTRY/$1" ]]; }
registry_state() { cut -f2 "$STUB_REGISTRY/$1"; }
registry_pid() { cut -f4 "$STUB_REGISTRY/$1"; }

agent aaaa1111 foreman/alpha/ABC-1/build-1    done    null  "$(wt alpha ABC-1)"
agent aaaa2222 foreman/alpha/ABC-1/review-1a  failed  null  "$(wt alpha ABC-1-review-1a)"
agent aaaa3333 foreman/alpha/ABC-1/plan-1     done    4101  "$target"
agent aaaa4444 foreman/alpha/ABC-1/review-1b  blocked null  "$(wt alpha ABC-1-review-1b)"
agent bbbb1111 foreman/alpha/ABC-2/build-1    working 4201  "$(wt alpha ABC-2)"
agent cccc1111 foreman/beta/ABC-1/build-1     done    null  "$(wt beta ABC-1)"
agent dddd1111 foreman/tick                   done    4401  "$target"
agent eeee1111 foreman/alpha/ABC-10/build-1   done    null  "$(wt alpha ABC-10)"
printf '{"type":"summary"}\n' > "$projects/$(slug "$target")/operator.jsonl"
mkdir -p "$(wt alpha ABC-1)" "$(wt alpha ABC-1-review-1b)" "$(wt alpha ABC-2)" \
  "$(wt beta ABC-1)" "$(wt alpha ABC-10)"

stub="$work/bin"; mkdir -p "$stub"
cat > "$stub/claude" <<'STUB'
#!/usr/bin/env bash
row() { f="$STUB_REGISTRY/$1"; [[ -f "$f" ]] || { printf 'no such session %s\n' "$1" >&2; exit 1; }; }
case "$1" in
  agents)
    printf '['; sep=''
    for f in "$STUB_REGISTRY"/*; do
      [[ -f "$f" ]] || continue
      id="$(basename "$f")"
      IFS=$'\t' read -r name state cwd pid started < "$f"
      printf '%s{"id":"%s","name":"%s","state":"%s","cwd":"%s","pid":%s,"startedAt":%s,"sessionId":"%s-sid"}' \
        "$sep" "$id" "$name" "$state" "$cwd" "$pid" "$started" "$id"
      sep=','
    done
    printf ']\n' ;;
  stop)
    row "$2"
    printf 'stopped %s\n' "$2"
    [[ -n "${STUB_STOP_IS_IGNORED:-}" ]] && exit 0
    IFS=$'\t' read -r name state cwd pid started < "$f"
    [[ "$pid" == null ]] && exit 0
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" stopped "$cwd" null "$started" > "$f"
    if [[ -f "$STUB_JOBS/$2/state.json" ]]; then
      python3 -c '
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["state"]="stopped"; d["pid"]=None; json.dump(d, open(p,"w"))
' "$STUB_JOBS/$2/state.json"
    fi ;;
  rm)
    row "$2"
    rm -f "$f"
    rm -rf "${STUB_JOBS:?}/$2"
    printf 'removed %s\n' "$2" ;;
  *) printf 'stub claude: unexpected %s\n' "$*" >&2; exit 2 ;;
esac
exit 0
STUB
chmod +x "$stub/claude"
export PATH="$stub:$PATH"

cards="$home/.foreman/instances/alpha/cards"
mkdir -p "$cards/ABC-1" "$cards/ABC-2"
sweep() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha \
    bash "$root/skills/board/sweep.sh" "$@" 2>&1
}

# --- dry run first: it must change nothing and say what it would do ----------
out="$(BOARD_DRY_RUN=1 sweep ABC-1 ABC-2)"
listed aaaa1111 && listed aaaa2222 && listed aaaa4444 \
  && [[ "$(registry_state aaaa3333)" == "done" && "$(registry_pid aaaa3333)" == 4101 ]] \
  && [[ -d "$jobs/aaaa1111" && -d "$projects/$(slug "$(wt alpha ABC-1)")" && -d "$(wt alpha ABC-1)" ]] \
  && ok "a dry run stops and forgets nothing" \
  || bad "a dry run stopped an agent or removed a session: $out"
grep -q 'DRY RUN: would stop session foreman/alpha/ABC-1/plan-1' <<<"$out" \
  && ok "a dry run names the idle agent it would stop" \
  || bad "dry run output does not name the agent to stop: $out"
grep -q 'DRY RUN: would forget session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && grep -q 'DRY RUN: would forget session foreman/alpha/ABC-1/review-1a' <<<"$out" \
  && ok "a dry run names the exited sessions it would forget" \
  || bad "dry run output does not name the sessions to forget: $out"

# --- the real sweep ----------------------------------------------------------
out="$(sweep ABC-1 ABC-2)" || { bad "sweep.sh ABC-1 ABC-2 exited non-zero: $out"; exit "$fail"; }

! listed aaaa1111 && ! listed aaaa2222 && ! listed aaaa4444 \
  && [[ ! -d "$jobs/aaaa1111" && ! -d "$jobs/aaaa2222" && ! -d "$jobs/aaaa4444" ]] \
  && ok "a terminal card's exited sessions are forgotten, done, failed and blocked alike" \
  || bad "ABC-1's exited sessions are still listed or still have records: $out"
grep -q 'forgot session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ok "the sweep says which session it forgot" \
  || bad "the sweep did not report forgetting ABC-1's build session: $out"
# The bug this pins: a stop on an exited row changes nothing, so a sweep that
# stops one waits out the timeout and says "did not land".
! grep -q 'stopping session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ! grep -q 'did not land' <<<"$out" \
  && ok "an exited session is forgotten without being stopped" \
  || bad "the sweep stopped an exited session: $out"

! listed aaaa3333 && [[ ! -d "$jobs/aaaa3333" ]] \
  && grep -q 'stopping session foreman/alpha/ABC-1/plan-1' <<<"$out" \
  && grep -q 'forgot session foreman/alpha/ABC-1/plan-1' <<<"$out" \
  && ok "an idle agent is stopped, then forgotten once it has exited" \
  || bad "ABC-1's idle plan agent was not stopped and forgotten: $out"

[[ ! -d "$(wt alpha ABC-1)" && ! -d "$(wt alpha ABC-1-review-1b)" ]] \
  && ok "so their worktrees, guarded until then as live, are reaped in the same sweep" \
  || bad "ABC-1's worktrees survived although their sessions were forgotten: $out"
[[ ! -d "$projects/$(slug "$(wt alpha ABC-1)")" && ! -d "$projects/$(slug "$(wt alpha ABC-1-review-1a)")" \
   && ! -d "$projects/$(slug "$(wt alpha ABC-1-review-1b)")" ]] \
  && ok "their transcripts go with them" \
  || bad "ABC-1's transcripts survived the sweep: $out"

[[ -f "$projects/$(slug "$target")/operator.jsonl" && -f "$projects/$(slug "$target")/aaaa3333-sid.jsonl" ]] \
  && ok "but a transcript directory the plan run shares with the operator is left alone" \
  || bad "the sweep removed transcripts from the repository's own directory: $out"
grep -q -- "$(slug "$target")" <<<"$out" \
  && ok "and the sweep says so" \
  || bad "the sweep left the shared transcript directory without saying why: $out"

[[ "$(registry_state bbbb1111)" == "working" && -d "$jobs/bbbb1111" && -d "$(wt alpha ABC-2)" ]] \
  && ok "a working agent is neither stopped nor forgotten, even for a ticket named on the command line" \
  || bad "ABC-2's working agent was stopped or forgotten: $out"
grep -q 'leaving session foreman/alpha/ABC-2/build-1' <<<"$out" \
  && ok "and the sweep says it is leaving it" \
  || bad "the sweep left ABC-2's session without saying so: $out"

listed cccc1111 && [[ -d "$jobs/cccc1111" && -d "$(wt beta ABC-1)" ]] \
  && ok "another instance's exited session for the same ticket key is not touched" \
  || bad "instance beta's ABC-1 session was forgotten by alpha's sweep: $out"
[[ "$(registry_state dddd1111)" == "done" && "$(registry_pid dddd1111)" == 4401 && -d "$jobs/dddd1111" ]] \
  && ok "the tick is not a card's agent and is not touched" \
  || bad "the tick was stopped or forgotten: $out"
listed eeee1111 && [[ -d "$jobs/eeee1111" && -d "$(wt alpha ABC-10)" ]] \
  && ok "ABC-1 does not match ABC-10" \
  || bad "ABC-10's session was forgotten by a sweep of ABC-1: $out"

# card_holds_slot reads the LAST line of history.jsonl, so whatever the sweep
# records about forgotten sessions has to land before the `released` marker.
tail -n1 "$cards/ABC-1/history.jsonl" | grep -q '"action":"released"' \
  && ok "the released marker is still the card's last word" \
  || bad "the last history line is no longer 'released': $(tail -n1 "$cards/ABC-1/history.jsonl")"
grep '"action":"forgot"' "$cards/ABC-1/history.jsonl" | grep -q '"sessions":4' \
  && ok "the card's history records that its four sessions were forgotten" \
  || bad "no 'forgot' entry for four sessions in ABC-1's history: $(cat "$cards/ABC-1/history.jsonl")"

# A second sweep of the same card is ordinary and must be a no-op.
out="$(sweep ABC-1)" || { bad "second sweep of ABC-1 exited non-zero: $out"; exit "$fail"; }
! grep -q -e 'forgot session' -e 'stopping session' <<<"$out" \
  && listed cccc1111 && listed eeee1111 \
  && ok "sweeping an already-forgotten card exits zero and does nothing" \
  || bad "a second sweep of ABC-1 stopped or forgot something: $out"

# --- a stop that never lands leaves the session and says so -------------------
agent hhhh1111 foreman/alpha/ABC-5/build-1 done 4501 "$(wt alpha ABC-5)"
mkdir -p "$(wt alpha ABC-5)" "$cards/ABC-5"
out="$(STUB_STOP_IS_IGNORED=1 AGENT_STOP_TIMEOUT_SECONDS=1 sweep ABC-5)"
status=$?
[[ "$status" -ne 0 ]] \
  && ok "a stop that does not land makes the sweep exit non-zero" \
  || bad "the sweep exited zero although ABC-5's agent never stopped: $out"
listed hhhh1111 && [[ -d "$jobs/hhhh1111" && -d "$(wt alpha ABC-5)" ]] \
  && ok "and the agent's record and worktree are left for a later sweep" \
  || bad "the sweep reaped ABC-5 although its agent never stopped: $out"
grep -q 'did not land' <<<"$out" \
  && ok "and the sweep says which stop did not land" \
  || bad "no message about the stop that did not land: $out"
tail -n1 "$cards/ABC-5/history.jsonl" | grep -q '"action":"released"' \
  && ok "the slot is still released, since the card is terminal regardless" \
  || bad "ABC-5's slot was not released: $(cat "$cards/ABC-5/history.jsonl")"
# Out of the way of the orphan passes below, which would otherwise see a
# stuck idle agent they are right to leave.
rm -f "$STUB_REGISTRY/hhhh1111"; rm -rf "$jobs/hhhh1111" "$(wt alpha ABC-5)"

# --- --orphans never stops or forgets; its reap ages exited rows out -----------
agent ffff1111 foreman/alpha/ABC-3/build-1 done null "$(wt alpha ABC-3)" $(( now_ms - 1 * day_ms ))
agent gggg1111 foreman/alpha/ABC-4/build-1 done null "$(wt alpha ABC-4)" $(( now_ms - 31 * day_ms ))
agent iiii1111 foreman/alpha/ABC-6/build-1 done 4601 "$(wt alpha ABC-6)" $(( now_ms - 31 * day_ms ))
mkdir -p "$(wt alpha ABC-3)" "$(wt alpha ABC-4)" "$(wt alpha ABC-6)"
out="$(sweep --orphans)" || { bad "sweep.sh --orphans exited non-zero: $out"; exit "$fail"; }
listed ffff1111 && [[ -d "$jobs/ffff1111" && -d "$projects/$(slug "$(wt alpha ABC-3)")" && -d "$(wt alpha ABC-3)" ]] \
  && ok "--orphans leaves an exited session younger than 30 days, and protects its tree" \
  || bad "--orphans forgot ABC-3's session or reaped its tree: $out"
! listed gggg1111 && [[ ! -d "$jobs/gggg1111" ]] \
  && grep -q 'removed agent record gggg1111' <<<"$out" \
  && ok "--orphans reaps an exited session 31 days old, and says so" \
  || bad "--orphans left ABC-4's 31-day-old exited session: $out"
[[ "$(registry_state iiii1111)" == "done" && "$(registry_pid iiii1111)" == 4601 && -d "$(wt alpha ABC-6)" ]] \
  && ok "--orphans neither stops nor reaps a done agent that still has a pid, however old" \
  || bad "--orphans stopped or reaped ABC-6's idle agent: $out"

out="$(sweep --orphans)" || { bad "second sweep.sh --orphans exited non-zero: $out"; exit "$fail"; }
[[ ! -d "$(wt alpha ABC-4)" ]] \
  && ok "the reaped session's tree goes on the following --orphans" \
  || bad "ABC-4's tree survived the orphan pass after its row was reaped: $out"
[[ -d "$(wt alpha ABC-3)" && -d "$(wt alpha ABC-6)" ]] && listed ffff1111 && listed iiii1111 \
  && ok "and that pass still leaves the young exited session and the idle agent" \
  || bad "the second orphan pass took ABC-3 or ABC-6: $out"

# --- no jobs directory at all is nothing to read, not an error ----------------
agent jjjj1111 foreman/alpha/ABC-7/build-1 done null "$(wt alpha ABC-7)"
mkdir -p "$(wt alpha ABC-7)" "$cards/ABC-7"
rm -rf "$jobs"
out="$(sweep ABC-7)" || { bad "sweep with no ~/.claude/jobs exited non-zero: $out"; exit "$fail"; }
! listed jjjj1111 && [[ ! -d "$(wt alpha ABC-7)" ]] \
  && ok "a machine with no ~/.claude/jobs still forgets and reaps through the adapter" \
  || bad "the sweep with no ~/.claude/jobs left ABC-7's session or tree: $out"

exit "$fail"
