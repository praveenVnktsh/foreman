#!/usr/bin/env bash
# Claim: sweeping a terminal card stops its idle agents and forgets its
# sessions, so they stop lingering in `claude agents --all` and in the
# operator's session list.
#
# Two things kept every card's sessions alive forever. A background agent
# idles at `done` when its turn ends (reconcile.py's PHASE table records the
# measurement) and nothing in the board ever asked it to stop, so a merged
# card's build agent sat at `done` with its worktree guarded as live. And an
# agent that did stop left its record under `~/.claude/jobs/<id>/` -- what
# `claude agents --all` lists a session from, and no subcommand removes it --
# and its transcripts under `~/.claude/projects/`. The worktree, scratch and
# branch were reaped; the plan, build and review sessions of every card ever
# built stayed.
#
# THE STUB BELOW USED TO LIE ABOUT THE BOUNDARY, and this test passed on the
# lie while the sweep deadlocked on every real machine. It was written against
# a measurement taken 2026-09-13 on Claude Code 2.1.228 -- `claude stop` writes
# `state: stopped` into the record -- so the stub rewrote both the registry row
# and `~/.claude/jobs/<id>/state.json`. Measured again 2026-09-22: `claude stop
# <id>` prints "stopped <id>", exits 0, and rewrites NOTHING. The record stays
# `done`, so a sweep reading `state != "stopped"` read every finished agent as
# live: it stopped the agents, waited out AGENT_STOP_TIMEOUT_SECONDS, reported
# that the stop had not landed, and left every tree "for a later sweep" that
# failed identically. One board reached 72 worktrees and 261G, the disk hit
# 96%, preflight's MIN_FREE_REPO_MB gate failed, and NO board on the machine
# could dispatch at all. The stub now does what the CLI does: it prints, and it
# changes nothing.
#
# So the PID is what tells a finished agent from a live one, and the stub
# carries it: a resident process reports a pid, and an agent whose process has
# exited reports `null`. It is corroboration for a state that already says the
# turn is over, never the test on its own -- a `working` agent keeps its
# worktree whatever its pid says, and so does a state this board does not know.
#
# The scoping rules are the ones the sweep already lives by:
# - only this instance's agents, by name prefix, so two boards sharing a
#   machine cannot stop or forget each other's sessions;
# - only `done` and `blocked` agents are stopped, and a record is forgotten
#   only once its agent is finished: `stopped`, or one of those two idle states
#   with no pid. A `working` agent is left alone, the tie-goes-to-leaving-it
#   rule --orphans applies to worktrees, because the caller's judgment that the
#   card is terminal may be stale;
# - a transcript directory goes only when the session ran in one of this
#   instance's own throwaway worktrees. Anywhere else is shared with whoever
#   else worked there, so that directory stays and the sweep says so;
# - ticket mode only. `--orphans` never stops or forgets a session, and never
#   reaps a `done` agent's worktree, because a card that is not yet terminal
#   may still be diagnosed from its transcript (reconcile.py's `death`) or
#   RESUMED INTO that worktree.
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
# agent under STUB_REGISTRY, `<name><TAB><state><TAB><pid><TAB><cwd>`; `claude
# agents --json --all` renders it, and `claude stop <id>` prints one line and
# leaves it exactly as it was, which is what the real CLI does. Nothing here
# asserts on the stub; the assertions are on what the sweep left on disk.
export STUB_REGISTRY="$work/registry" STUB_JOBS="$home/.claude/jobs"
mkdir -p "$STUB_REGISTRY"
jobs="$STUB_JOBS"; projects="$home/.claude/projects"
# agent <id> <name> <state> <pid> <cwd> -- one background session as Claude
# Code holds it: a registry row, a record, and a transcript directory.
#
# <pid> is a number while the agent's process is resident and the JSON literal
# `null` once it has exited. It is written unquoted into both the registry row
# and the record, so a finished agent reaches the sweep reporting no pid, the
# way a real one does. NO FIELD IS EVER EMPTY: a TAB is IFS whitespace, so the
# stub's `IFS=$'\t' read` would collapse the two around an empty pid into one
# and shift the cwd into its place.
agent() {
  mkdir -p "$jobs/$1" "$projects/$(slug "$5")"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$STUB_REGISTRY/$1"
  printf '{"state":"%s","name":"%s","pid":%s,"cwd":"%s","sessionId":"%s-sid"}\n' \
    "$3" "$2" "$4" "$5" "$1" > "$jobs/$1/state.json"
  printf '{"type":"summary"}\n' > "$projects/$(slug "$5")/$1-sid.jsonl"
}

agent aaaa1111 foreman/alpha/ABC-1/build-1    done    null   "$(wt alpha ABC-1)"
agent aaaa2222 foreman/alpha/ABC-1/review-1a  stopped null   "$(wt alpha ABC-1-review-1a)"
agent aaaa3333 foreman/alpha/ABC-1/plan-1     done    null   "$target"
agent aaaa4444 foreman/alpha/ABC-1/review-1b  blocked null   "$(wt alpha ABC-1-review-1b)"
agent bbbb1111 foreman/alpha/ABC-2/build-1    working 424201 "$(wt alpha ABC-2)"
agent cccc1111 foreman/beta/ABC-1/build-1     done    null   "$(wt beta ABC-1)"
agent dddd1111 foreman/tick                   done    null   "$target"
agent eeee1111 foreman/alpha/ABC-10/build-1   done    null   "$(wt alpha ABC-10)"
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
      IFS=$'\t' read -r name state pid cwd < "$f"
      printf '%s{"id":"%s","name":"%s","state":"%s","pid":%s,"cwd":"%s"}' \
        "$sep" "$(basename "$f")" "$name" "$state" "$pid" "$cwd"
      sep=','
    done
    printf ']\n' ;;
  # Print and exit 0, and touch neither the registry row nor the record. A stop
  # that changes nothing is the ORDINARY case on Claude Code, not a fault
  # injected for one assertion, so there is no switch to turn it off.
  stop)
    printf 'stopped %s\n' "$2" ;;
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
[[ -d "$jobs/aaaa1111" && -d "$jobs/aaaa2222" && -d "$(wt alpha ABC-1)" \
   && -d "$projects/$(slug "$(wt alpha ABC-1)")" ]] \
  && ok "a dry run stops and forgets nothing" \
  || bad "a dry run reaped a worktree or removed a session: $out"
grep -q 'DRY RUN: would stop session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ok "a dry run names the agent it would stop" \
  || bad "dry run output does not name the agent to stop: $out"
grep -q 'DRY RUN: would forget session foreman/alpha/ABC-1/review-1a' <<<"$out" \
  && ok "a dry run names the session it would forget" \
  || bad "dry run output does not name the session to forget: $out"

# --- the real sweep ----------------------------------------------------------
out="$(sweep ABC-1 ABC-2)" || { bad "sweep.sh ABC-1 ABC-2 exited non-zero: $out"; exit "$fail"; }

grep -q 'stopping session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && grep -q 'stopping session foreman/alpha/ABC-1/review-1b' <<<"$out" \
  && ok "a terminal card's done and blocked agents are asked to stop" \
  || bad "ABC-1's idle agents were not asked to stop: $out"
[[ ! -d "$(wt alpha ABC-1)" ]] \
  && ok "and its worktree is reaped in the same sweep, although the record still reads done" \
  || bad "ABC-1's worktree survived although its agent had finished: $out"
[[ ! -d "$jobs/aaaa1111" && ! -d "$jobs/aaaa2222" && ! -d "$jobs/aaaa4444" ]] \
  && ok "its done, blocked and long-stopped records are all forgotten" \
  || bad "ABC-1's session records survived the sweep: $out"
[[ ! -d "$projects/$(slug "$(wt alpha ABC-1)")" && ! -d "$projects/$(slug "$(wt alpha ABC-1-review-1a)")" ]] \
  && ok "their transcripts go with them" \
  || bad "ABC-1's transcripts survived the sweep: $out"
grep -q 'forgot session foreman/alpha/ABC-1/build-1' <<<"$out" \
  && ok "the sweep says which session it forgot" \
  || bad "the sweep did not report forgetting ABC-1's build session: $out"

[[ ! -d "$jobs/aaaa3333" ]] \
  && ok "a session that ran outside a foreman worktree still loses its record" \
  || bad "ABC-1's plan record survived: $out"
[[ -f "$projects/$(slug "$target")/operator.jsonl" && -f "$projects/$(slug "$target")/aaaa3333-sid.jsonl" ]] \
  && ok "but a transcript directory it shares with the operator is left alone" \
  || bad "the sweep removed transcripts from the repository's own directory: $out"
grep -q -- "$(slug "$target")" <<<"$out" \
  && ok "and the sweep says so" \
  || bad "the sweep left the shared transcript directory without saying why: $out"

[[ -d "$jobs/bbbb1111" && -d "$(wt alpha ABC-2)" ]] \
  && ok "a working agent is neither stopped nor forgotten, even for a ticket named on the command line" \
  || bad "ABC-2's working agent was stopped or forgotten: $out"
grep -q 'leaving session foreman/alpha/ABC-2/build-1' <<<"$out" \
  && ok "and the sweep says it is leaving it" \
  || bad "the sweep left ABC-2's session without saying so: $out"

[[ -d "$jobs/cccc1111" ]] \
  && ok "another instance's agent for the same ticket key is not touched" \
  || bad "instance beta's ABC-1 agent was forgotten by alpha's sweep: $out"
[[ -d "$jobs/dddd1111" ]] \
  && ok "the tick is not a card's agent and is not touched" \
  || bad "the tick was forgotten: $out"
[[ -d "$jobs/eeee1111" ]] \
  && ok "ABC-1 does not match ABC-10" \
  || bad "ABC-10's agent was forgotten by a sweep of ABC-1: $out"

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
agent ffff1111 foreman/alpha/ABC-3/build-1 stopped null "$(wt alpha ABC-3)"
agent gggg1111 foreman/alpha/ABC-4/build-1 done    null "$(wt alpha ABC-4)"
mkdir -p "$(wt alpha ABC-4)"
out="$(sweep --orphans)" || { bad "sweep.sh --orphans exited non-zero: $out"; exit "$fail"; }
[[ -d "$jobs/ffff1111" && -d "$projects/$(slug "$(wt alpha ABC-3)")" ]] \
  && ok "--orphans leaves a stopped session's record and transcript for reconcile to read" \
  || bad "--orphans forgot ABC-3's session: $out"
[[ -d "$jobs/gggg1111" ]] \
  && ok "--orphans leaves a done agent's record alone: its card may not be terminal" \
  || bad "--orphans forgot ABC-4's session: $out"
[[ -d "$(wt alpha ABC-4)" ]] \
  && ok "and leaves its worktree, which a card that is not terminal is resumed into" \
  || bad "--orphans reaped the worktree of a done agent whose card may still be built: $out"

# --- a stop that never lands leaves the session and says so -------------------
# This agent KEEPS ITS PID: its turn reads `done` but its process is still
# resident, so no stop of it can land and the sweep must say so. A stop that
# changes nothing is normal here (see the header); a process that is still up
# at the bound is not.
agent hhhh1111 foreman/alpha/ABC-5/build-1 done 424205 "$(wt alpha ABC-5)"
mkdir -p "$(wt alpha ABC-5)" "$cards/ABC-5"
out="$(AGENT_STOP_TIMEOUT_SECONDS=1 sweep ABC-5)"
status=$?
[[ "$status" -ne 0 ]] \
  && ok "a stop that does not land makes the sweep exit non-zero" \
  || bad "the sweep exited zero although ABC-5's agent never stopped: $out"
[[ -d "$jobs/hhhh1111" && -d "$(wt alpha ABC-5)" ]] \
  && ok "and the agent's record and worktree are left for a later sweep" \
  || bad "the sweep reaped ABC-5 although its agent never stopped: $out"
grep -q 'foreman/alpha/ABC-5/build-1.*did not land' <<<"$out" \
  && ok "and the sweep names the session whose stop did not land" \
  || bad "no message naming the stop that did not land: $out"
tail -n1 "$cards/ABC-5/history.jsonl" | grep -q '"action":"released"' \
  && ok "the slot is still released, since the card is terminal regardless" \
  || bad "ABC-5's slot was not released: $(cat "$cards/ABC-5/history.jsonl")"

# --- no jobs directory at all is nothing to forget, not an error --------------
rm -rf "$jobs"
out="$(sweep ABC-1)" || { bad "sweep with no ~/.claude/jobs exited non-zero: $out"; exit "$fail"; }
ok "a machine with no session records sweeps as before"

exit "$fail"
