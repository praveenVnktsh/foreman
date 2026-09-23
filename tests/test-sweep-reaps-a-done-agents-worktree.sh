#!/usr/bin/env bash
# Claim: a terminal card whose agent is `done` with no pid has its worktree,
# scratch, record and transcripts reaped by THAT sweep, and the sweep exits
# zero without waiting out AGENT_STOP_TIMEOUT_SECONDS.
#
# Measured 2026-09-22, and this is the incident the whole file exists for. A
# finished Claude background agent idles at `state: "done"` with `pid: null`
# once its process exits, and `claude stop <id>` prints "stopped <id>" and
# exits 0 WITHOUT rewriting ~/.claude/jobs/<id>/state.json. The record stays
# `done` forever. The sweep read `state != "stopped"` as "alive", so every
# terminal card's tree was left "for a later sweep" that failed identically:
# 72 worktrees and 261G on one board, the disk at 96%, preflight's free-disk
# gate failing, and no board on the machine able to dispatch at all. Each
# ticket sweep also burned the full stop timeout first and then exited
# non-zero, because the stop it was waiting on can never change the state it
# was watching.
#
# THE STUB IS THE POINT. `claude stop` here changes nothing -- not the registry
# row, not the record. A stub that flips the state to `stopped` on stop is the
# false model that let this bug ship, and every assertion built on one is green
# by construction.
#
# The predicate under test, and the three ways it must still say "leave it":
#   finished = state == "stopped", OR state is one the caller named idle AND
#              the agent reports no pid.
# So a `working` agent survives, a `done` agent that STILL HOLDS A PID survives
# (its process is up, whatever the record says), and a state this code does not
# know survives. The pid is corroboration for a state that already says the
# turn is over; it is never the test on its own.
#
# And `--orphans` passes NO idle states, so it does not reap a `done` agent's
# tree at all. That card may not be terminal, and dispatch.sh resumes an agent
# INTO its worktree ("worktree $WORKTREE is gone; cannot resume"). Reaping
# there would turn this fix into a worse bug.
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

board_home="$home/.foreman/instances/alpha"
wt() { printf '%s/.claude/worktrees/foreman-alpha-%s\n' "$target" "$1"; }
# Asked of bin/tmp-dir.sh rather than spelled again here: config.sh derives the
# scratch root the same way, and two spellings of one path agree only until one
# of them is edited.
tmp_root="$(BOARD_HOME="$board_home" "$root/bin/tmp-dir.sh" --root)"
scratch() { printf '%s/foreman-alpha-%s\n' "$tmp_root" "$1"; }
# The slug Claude Code files a transcript under: `/` and `.` become `-`.
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

jobs="$home/.claude/jobs"; projects="$home/.claude/projects"
export STUB_REGISTRY="$work/registry"
mkdir -p "$STUB_REGISTRY"

# agent <id> <name> <state> <pid|null> <ticket> -- one background session as
# Claude Code holds it, plus the worktree and scratch foreman cut for it: a
# registry row, a record under ~/.claude/jobs/<id>/, and a transcript directory
# under ~/.claude/projects/<slug>/.
agent() {
  local id="$1" name="$2" state="$3" pid="$4" cwd
  cwd="$(wt "$5")"
  mkdir -p "$jobs/$id" "$projects/$(slug "$cwd")" "$cwd" "$(scratch "$5")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$state" "$cwd" "$pid" > "$STUB_REGISTRY/$id"
  printf '{"state":"%s","name":"%s","cwd":"%s","pid":%s,"sessionId":"%s-sid"}\n' \
    "$state" "$name" "$cwd" "$pid" "$id" > "$jobs/$id/state.json"
  printf '{"type":"summary"}\n' > "$projects/$(slug "$cwd")/$id-sid.jsonl"
}

# The external boundary, and it behaves the way Claude Code measured
# 2026-09-22 behaves: `stop` prints, exits 0, and rewrites NOTHING. Nothing
# below asserts on this stub; every assertion is on what the sweep left on
# disk.
stub="$work/bin"; mkdir -p "$stub"
cat > "$stub/claude" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  agents)
    printf '['; sep=''
    for f in "$STUB_REGISTRY"/*; do
      [[ -f "$f" ]] || continue
      IFS=$'\t' read -r name state cwd pid < "$f"
      printf '%s{"id":"%s","name":"%s","state":"%s","cwd":"%s","pid":%s}' \
        "$sep" "$(basename "$f")" "$name" "$state" "$cwd" "$pid"
      sep=','
    done
    printf ']\n' ;;
  stop)
    printf 'stopped %s\n' "$2" ;;
esac
exit 0
STUB
chmod +x "$stub/claude"
export PATH="$stub:$PATH"

sweep() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha \
    bash "$root/skills/board/sweep.sh" "$@" 2>&1
}

# A pid nothing on this machine is using. It is never signalled -- the sweep
# reads it as a field, not as a process -- so its only job is to be truthy.
UP=424242

agent fin00001 foreman/alpha/ABC-1/build-1 done    null  ABC-1
agent wrk00001 foreman/alpha/ABC-2/build-1 working null  ABC-2
agent pid00001 foreman/alpha/ABC-3/build-1 done    "$UP" ABC-3
agent unk00001 foreman/alpha/ABC-4/build-1 paused  null  ABC-4
agent orp00001 foreman/alpha/ABC-5/build-1 done    null  ABC-5

# --- the finished agent, and the three that must survive beside it -----------
#
# AGENT_STOP_TIMEOUT_SECONDS is deliberately LARGE. The old sweep waited all of
# it and then failed; this one has a signal it can observe, so it returns on
# the first pass. The elapsed-time assertion below is the claim.
started="$(date +%s)"
out="$(AGENT_STOP_TIMEOUT_SECONDS=60 sweep ABC-1 ABC-2 ABC-4)"
status=$?
elapsed=$(( $(date +%s) - started ))

[[ "$status" -eq 0 ]] \
  && ok "a sweep of a done/pid-null agent's card exits zero" \
  || bad "sweep exited $status although every agent it asked to stop was already finished: $out"
# Twenty seconds is slack for a cold python3 on a loaded machine, not a
# measurement. What it separates is one pass from sixty seconds of polling.
[[ "$elapsed" -lt 20 ]] \
  && ok "and returns at once instead of waiting out AGENT_STOP_TIMEOUT_SECONDS" \
  || bad "the sweep took ${elapsed}s of its 60s stop budget: $out"
grep -q 'did not land' <<<"$out" \
  && bad "the sweep reported a stop that did not land for an agent whose process is gone: $out" \
  || ok "and never reports that the stop did not land"

[[ ! -d "$(wt ABC-1)" ]] \
  && ok "the done/pid-null agent's worktree is reaped by this sweep, not deferred to a later one" \
  || bad "ABC-1's worktree survived although its agent was done with no pid: $out"
[[ ! -d "$(scratch ABC-1)" ]] \
  && ok "its scratch directory goes with it" \
  || bad "ABC-1's scratch directory survived: $out"
[[ ! -d "$jobs/fin00001" ]] \
  && ok "its record is forgotten although the record never said stopped" \
  || bad "ABC-1's record under ~/.claude/jobs survived: $out"
[[ ! -d "$projects/$(slug "$(wt ABC-1)")" ]] \
  && ok "and its transcripts go with the record" \
  || bad "ABC-1's transcripts survived: $out"

[[ -d "$(wt ABC-2)" && -d "$jobs/wrk00001" && -d "$projects/$(slug "$(wt ABC-2)")" ]] \
  && ok "a working agent keeps its worktree, record and transcripts, even for a ticket named on the command line" \
  || bad "ABC-2's working agent was reaped: $out"

[[ -d "$(wt ABC-4)" && -d "$jobs/unk00001" && -d "$projects/$(slug "$(wt ABC-4)")" ]] \
  && ok "an agent in a state this code does not know survives: no pid alone never means death" \
  || bad "ABC-4's paused agent was reaped: $out"

# --- a done agent that still reports a pid: the process is up ----------------
#
# The tie goes to leaving it. The stop is re-issued until the bound, and then
# the sweep leaves the agent, names it, and exits non-zero -- a session that
# lingers must not read as a clean sweep. A one-second bound keeps the test
# quick; the bound itself is not what is under test here.
out="$(AGENT_STOP_TIMEOUT_SECONDS=1 sweep ABC-3)"
status=$?
[[ "$status" -ne 0 ]] \
  && ok "a done agent that still holds a pid makes the sweep exit non-zero" \
  || bad "the sweep exited zero although ABC-3's process is still up: $out"
[[ -d "$(wt ABC-3)" && -d "$jobs/pid00001" && -d "$(scratch ABC-3)" ]] \
  && ok "and its worktree, scratch and record are left alone" \
  || bad "ABC-3's worktree, scratch or record was reaped while its process was up: $out"
grep -q 'foreman/alpha/ABC-3/build-1' <<<"$out" && grep -q 'did not land' <<<"$out" \
  && ok "and the sweep names the session whose stop did not land" \
  || bad "the sweep did not name ABC-3's lingering session: $out"

# --- --orphans still refuses a done agent's tree -----------------------------
out="$(sweep --orphans)"
status=$?
[[ "$status" -eq 0 ]] \
  && ok "--orphans exits zero" \
  || bad "sweep.sh --orphans exited $status: $out"
[[ -d "$(wt ABC-5)" && -d "$(scratch ABC-5)" && -d "$jobs/orp00001" ]] \
  && ok "--orphans does not reap a done/pid-null agent's worktree: its card may not be terminal, and dispatch resumes into it" \
  || bad "--orphans reaped ABC-5's worktree, scratch or record: $out"

exit "$fail"
