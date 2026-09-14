#!/usr/bin/env bash
# Claim: sweeping a terminal card stops its idle agents and forgets its
# sessions, so they stop lingering in `claude agents --all` and in the
# operator's session list.
#
# Two things kept every card's sessions alive forever. A background agent
# idles at `done` when its turn ends (reconcile.py's PHASE table records the
# measurement) and nothing in the board ever asked it to stop, so a merged
# card's build agent sat at `done` with its worktree guarded as "not (yet)
# stopped". And an agent that did stop left its record under
# `~/.claude/jobs/<id>/` -- what `claude agents --all` lists a stopped agent
# from; measured 2026-09-13 on Claude Code 2.1.228, where `claude stop` writes
# `state: stopped` there and no subcommand removes it -- and its transcripts
# under `~/.claude/projects/`. The worktree, scratch and branch were reaped; the
# plan, build and review sessions of every card ever built stayed.
#
# The scoping rules are the ones the sweep already lives by:
# - only this instance's agents, by name prefix, so two boards sharing a
#   machine cannot stop or forget each other's sessions;
# - only `done` and `blocked` agents are stopped, and only `stopped` records
#   are forgotten: a `working` agent is left alone, the tie-goes-to-leaving-it
#   rule --orphans applies to worktrees, because the caller's judgment that the
#   card is terminal may be stale;
# - a transcript directory goes only when the session ran in one of this
#   instance's own throwaway worktrees. Anywhere else is shared with whoever
#   else worked there, so that directory stays and the sweep says so;
# - ticket mode only. `--orphans` never stops or forgets a session, because a
#   card that is not yet terminal may still be diagnosed from its transcript
#   (reconcile.py's `death`) or resumed into it.
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

# The stubbed `claude` is the external boundary. Its registry is one file per
# agent under STUB_REGISTRY, `<name><TAB><state><TAB><cwd>`; `claude agents
# --json --all` renders it, and `claude stop <id>` moves that agent to
# `stopped` there AND in its record under ~/.claude/jobs, which is what the
# real daemon does. Nothing here asserts on the stub; the assertions are on
# what the sweep left on disk.
export STUB_REGISTRY="$work/registry" STUB_JOBS="$home/.claude/jobs"
mkdir -p "$STUB_REGISTRY"
jobs="$STUB_JOBS"; projects="$home/.claude/projects"
# agent <id> <name> <state> <cwd> -- one background session as Claude Code
# holds it: a registry row, a record, and a transcript directory.
agent() {
  mkdir -p "$jobs/$1" "$projects/$(slug "$4")"
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$STUB_REGISTRY/$1"
  printf '{"state":"%s","name":"%s","cwd":"%s","sessionId":"%s-sid"}\n' "$3" "$2" "$4" "$1" \
    > "$jobs/$1/state.json"
  printf '{"type":"summary"}\n' > "$projects/$(slug "$4")/$1-sid.jsonl"
}
registry_state() { cut -f2 "$STUB_REGISTRY/$1"; }

agent aaaa1111 foreman/alpha/ABC-1/build-1    done    "$(wt alpha ABC-1)"
agent aaaa2222 foreman/alpha/ABC-1/review-1a  stopped "$(wt alpha ABC-1-review-1a)"
agent aaaa3333 foreman/alpha/ABC-1/plan-1     done    "$target"
agent aaaa4444 foreman/alpha/ABC-1/review-1b  blocked "$(wt alpha ABC-1-review-1b)"
agent bbbb1111 foreman/alpha/ABC-2/build-1    working "$(wt alpha ABC-2)"
agent cccc1111 foreman/beta/ABC-1/build-1     done    "$(wt beta ABC-1)"
agent dddd1111 foreman/tick                   done    "$target"
agent eeee1111 foreman/alpha/ABC-10/build-1   done    "$(wt alpha ABC-10)"
printf '{"type":"summary"}\n' > "$projects/$(slug "$target")/operator.jsonl"
mkdir -p "$(wt alpha ABC-1)" "$(wt alpha ABC-2)"

stub="$work/bin"; mkdir -p "$stub"
cat > "$stub/claude" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  agents)
    printf '['; sep=''
    for f in "$STUB_REGISTRY"/*; do
      [[ -f "$f" ]] || continue
      IFS=$'\t' read -r name state cwd < "$f"
      printf '%s{"id":"%s","name":"%s","state":"%s","cwd":"%s"}' "$sep" "$(basename "$f")" "$name" "$state" "$cwd"
      sep=','
    done
    printf ']\n' ;;
  stop)
    [[ -n "${STUB_STOP_IS_IGNORED:-}" ]] && exit 0
    f="$STUB_REGISTRY/$2"; IFS=$'\t' read -r name state cwd < "$f"
    printf '%s\t%s\t%s\n' "$name" stopped "$cwd" > "$f"
    python3 -c '
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["state"]="stopped"; json.dump(d, open(p,"w"))
' "$STUB_JOBS/$2/state.json" ;;
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
[[ "$(registry_state aaaa1111)" == "done" && -d "$jobs/aaaa2222" && -d "$projects/$(slug "$(wt alpha ABC-1)")" ]] \
  && ok "a dry run stops and forgets nothing" \
  || bad "a dry run stopped an agent or removed a session: $out"
grep -q 'DRY RUN: would stop session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ok "a dry run names the agent it would stop" \
  || bad "dry run output does not name the agent to stop: $out"
grep -q 'DRY RUN: would forget session foreman/alpha/ABC-1/review-1a' <<<"$out" \
  && ok "a dry run names the session it would forget" \
  || bad "dry run output does not name the session to forget: $out"

# --- the real sweep ----------------------------------------------------------
out="$(sweep ABC-1 ABC-2)" || { bad "sweep.sh ABC-1 ABC-2 exited non-zero: $out"; exit "$fail"; }

[[ "$(registry_state aaaa1111)" == "stopped" && "$(registry_state aaaa4444)" == "stopped" ]] \
  && ok "a terminal card's done and blocked agents are stopped" \
  || bad "ABC-1's idle agents were not stopped: $out"
[[ ! -d "$(wt alpha ABC-1)" ]] \
  && ok "so its worktree, guarded until then as live, is reaped in the same sweep" \
  || bad "ABC-1's worktree survived although its agent was stopped: $out"
[[ ! -d "$jobs/aaaa1111" && ! -d "$jobs/aaaa2222" && ! -d "$jobs/aaaa4444" ]] \
  && ok "and its stopped records are forgotten, the long-stopped reviewer's included" \
  || bad "ABC-1's session records survived the sweep: $out"
[[ ! -d "$projects/$(slug "$(wt alpha ABC-1)")" && ! -d "$projects/$(slug "$(wt alpha ABC-1-review-1a)")" ]] \
  && ok "their transcripts go with them" \
  || bad "ABC-1's transcripts survived the sweep: $out"
grep -q 'stopping session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && grep -q 'forgot session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ok "the sweep says which session it stopped and forgot" \
  || bad "the sweep did not report stopping and forgetting ABC-1's build session: $out"

[[ ! -d "$jobs/aaaa3333" ]] \
  && ok "a session that ran outside a foreman worktree still loses its record" \
  || bad "ABC-1's plan record survived: $out"
[[ -f "$projects/$(slug "$target")/operator.jsonl" && -f "$projects/$(slug "$target")/aaaa3333-sid.jsonl" ]] \
  && ok "but a transcript directory it shares with the operator is left alone" \
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

[[ "$(registry_state cccc1111)" == "done" && -d "$jobs/cccc1111" ]] \
  && ok "another instance's agent for the same ticket key is not touched" \
  || bad "instance beta's ABC-1 agent was stopped or forgotten by alpha's sweep: $out"
[[ "$(registry_state dddd1111)" == "done" && -d "$jobs/dddd1111" ]] \
  && ok "the tick is not a card's agent and is not touched" \
  || bad "the tick was stopped or forgotten: $out"
[[ "$(registry_state eeee1111)" == "done" && -d "$jobs/eeee1111" ]] \
  && ok "ABC-1 does not match ABC-10" \
  || bad "ABC-10's agent was stopped or forgotten by a sweep of ABC-1: $out"

# card_holds_slot reads the LAST line of history.jsonl, so whatever the sweep
# records about forgotten sessions has to land before the `released` marker.
tail -n1 "$cards/ABC-1/history.jsonl" | grep -q '"action":"released"' \
  && ok "the released marker is still the card's last word" \
  || bad "the last history line is no longer 'released': $(tail -n1 "$cards/ABC-1/history.jsonl")"
grep -q '"action":"forgot"' "$cards/ABC-1/history.jsonl" \
  && ok "the card's history records that its sessions were forgotten" \
  || bad "no 'forgot' entry in ABC-1's history"

# A second sweep of the same card is ordinary and must be a no-op.
out="$(sweep ABC-1)" || { bad "second sweep of ABC-1 exited non-zero: $out"; exit "$fail"; }
ok "sweeping an already-forgotten card exits zero"

# --- --orphans never stops or forgets --------------------------------------------
agent ffff1111 foreman/alpha/ABC-3/build-1 stopped "$(wt alpha ABC-3)"
agent gggg1111 foreman/alpha/ABC-4/build-1 done    "$(wt alpha ABC-4)"
out="$(sweep --orphans)" || { bad "sweep.sh --orphans exited non-zero: $out"; exit "$fail"; }
[[ -d "$jobs/ffff1111" && -d "$projects/$(slug "$(wt alpha ABC-3)")" ]] \
  && ok "--orphans leaves a stopped session's record and transcript for reconcile to read" \
  || bad "--orphans forgot ABC-3's session: $out"
[[ "$(registry_state gggg1111)" == "done" ]] \
  && ok "--orphans leaves a done agent running: its card may not be terminal" \
  || bad "--orphans stopped ABC-4's agent: $out"

# --- a stop that never lands leaves the session and says so -------------------
agent hhhh1111 foreman/alpha/ABC-5/build-1 done "$(wt alpha ABC-5)"
mkdir -p "$(wt alpha ABC-5)" "$cards/ABC-5"
out="$(STUB_STOP_IS_IGNORED=1 AGENT_STOP_TIMEOUT_SECONDS=1 sweep ABC-5)"
status=$?
[[ "$status" -ne 0 ]] \
  && ok "a stop that does not land makes the sweep exit non-zero" \
  || bad "the sweep exited zero although ABC-5's agent never stopped: $out"
[[ -d "$jobs/hhhh1111" && -d "$(wt alpha ABC-5)" ]] \
  && ok "and the agent's record and worktree are left for a later sweep" \
  || bad "the sweep reaped ABC-5 although its agent never stopped: $out"
grep -q 'did not land' <<<"$out" \
  && ok "and the sweep says which stop did not land" \
  || bad "no message about the stop that did not land: $out"
tail -n1 "$cards/ABC-5/history.jsonl" | grep -q '"action":"released"' \
  && ok "the slot is still released, since the card is terminal regardless" \
  || bad "ABC-5's slot was not released: $(cat "$cards/ABC-5/history.jsonl")"

# --- no jobs directory at all is nothing to forget, not an error --------------
rm -rf "$jobs"
out="$(sweep ABC-1)" || { bad "sweep with no ~/.claude/jobs exited non-zero: $out"; exit "$fail"; }
ok "a machine with no session records sweeps as before"

exit "$fail"
