#!/usr/bin/env bash
# Claim: `sweep.sh --settle <in-flight tickets>` stops a card's turn-complete
# agent once a later role or attempt of the same card has been spawned, and
# every turn-complete agent of a card no longer in flight. It forgets what it
# stopped once exited, except the build a fix round would resume. It never
# touches a working agent, the tick, another board, or a session foreman did not
# name, and it removes no transcript, worktree or slot.
#
# skills/board/supersede.py's header has the measurement, and why a live card's
# newest build row is neither stopped nor forgotten: the fix round resumes it
# by name, in the worktree that row keeps safe from `--orphans`.
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
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
t0=$(( $(date +%s) * 1000 ))

# The stubbed `claude`, as 2.1.280 was measured to behave; the registry is one
# file per agent, `<name><TAB><state><TAB><cwd><TAB><pid or null><TAB><startedAt>`.
# `stop` moves a row with a pid to `stopped` with none; `rm` deletes the row;
# `--bg --resume <session>` records the session it was asked to resume.
export STUB_REGISTRY="$work/registry" STUB_RESUMED="$work/resumed"
mkdir -p "$STUB_REGISTRY"
projects="$home/.claude/projects"
# agent <id> <name> <state> <pid|null> <cwd> <startedAt>
agent() {
  mkdir -p "$projects/$(slug "$5")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$5" "$4" "$6" > "$STUB_REGISTRY/$1"
  printf '{"type":"summary"}\n' > "$projects/$(slug "$5")/$1-sid.jsonl"
}
listed() { [[ -f "$STUB_REGISTRY/$1" ]]; }
state_of() { cut -f2 "$STUB_REGISTRY/$1"; }
pid_of() { cut -f4 "$STUB_REGISTRY/$1"; }
untouched() { listed "$1" && [[ "$(state_of "$1")" == "$2" && "$(pid_of "$1")" == "$3" ]]; }

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
    IFS=$'\t' read -r name state cwd pid started < "$f"
    [[ "$pid" == null ]] && exit 0
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" stopped "$cwd" null "$started" > "$f" ;;
  rm)
    row "$2"
    rm -f "$f"
    printf 'removed %s\n' "$2" ;;
  --bg)
    [[ "$2" == --resume ]] || { printf 'stub claude: unexpected %s\n' "$*" >&2; exit 2; }
    printf '%s\n' "$3" > "$STUB_RESUMED" ;;
  *) printf 'stub claude: unexpected %s\n' "$*" >&2; exit 2 ;;
esac
exit 0
STUB
chmod +x "$stub/claude"
export PATH="$stub:$PATH"

# ABC-1, in flight: its plan finished and its build has been spawned.
agent p1 foreman/alpha/ABC-1/plan-1    done    5101 "$(wt alpha ABC-1-plan-1)" "$t0"
agent b1 foreman/alpha/ABC-1/build-1   working 5102 "$(wt alpha ABC-1)"        $(( t0 + 1000 ))
# ABC-2, in flight: build-1 exited and was forked by a fix-round resume; the
# fork is idle and review-1 has been spawned since. The fork is what the next
# fix round resumes, so it is left as it is; the old row is never resumed.
agent o2 foreman/alpha/ABC-2/build-1   done    null "$(wt alpha ABC-2)"        "$t0"
agent f2 foreman/alpha/ABC-2/build-1   done    5202 "$(wt alpha ABC-2)"        $(( t0 + 1000 ))
agent r2 foreman/alpha/ABC-2/review-1  done    5203 "$(wt alpha ABC-2-review-1)" $(( t0 + 2000 ))
# ABC-3, in flight: two slots of one review round. A sibling is not a successor.
agent a3 foreman/alpha/ABC-3/review-1a done    5301 "$(wt alpha ABC-3-review-1a)" "$t0"
agent c3 foreman/alpha/ABC-3/review-1b working 5302 "$(wt alpha ABC-3-review-1b)" $(( t0 + 1000 ))
# ABC-9 is out of flight -- Done, or Needs Human waiting on a person -- and
# ticket-mode sweep never ran for it.
agent p9 foreman/alpha/ABC-9/plan-1    done    5901 "$(wt alpha ABC-9-plan-1)" "$t0"
agent b9 foreman/alpha/ABC-9/build-1   done    5902 "$(wt alpha ABC-9)"        $(( t0 + 1000 ))
agent r9 foreman/alpha/ABC-9/review-1  done    null "$(wt alpha ABC-9-review-1)" $(( t0 + 2000 ))
# Nothing of these is alpha's card agent.
agent tk foreman/tick                  done    6001 "$target"                  "$t0"
agent op operator-session              done    6002 "$target"                  "$t0"
agent bt foreman/beta/ABC-1/plan-1     done    6003 "$(wt beta ABC-1-plan-1)"  "$t0"
agent cl foreman/alpha/cleanup/cleanup-202609300000 done 6004 "$(wt alpha cleanup)" "$t0"
mkdir -p "$(wt alpha ABC-1-plan-1)" "$(wt alpha ABC-2)" "$(wt alpha ABC-9)"

cards="$home/.foreman/instances/alpha/cards"
mkdir -p "$cards/ABC-1" "$cards/ABC-2" "$cards/ABC-9"
sweep() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha \
    bash "$root/skills/board/sweep.sh" "$@" 2>&1
}

# --- a dry run changes nothing ------------------------------------------------
out="$(BOARD_DRY_RUN=1 sweep --settle ABC-1 ABC-2 ABC-3)"
untouched p1 done 5101 && untouched f2 done 5202 && untouched p9 done 5901 && listed o2 && listed r9 \
  && ok "a dry run stops and forgets nothing" \
  || bad "a dry run stopped or forgot an agent: $out"

# --- the real pass ------------------------------------------------------------
out="$(sweep --settle ABC-1 ABC-2 ABC-3)" || bad "sweep.sh --settle exited non-zero: $out"

! listed p1 \
  && ok "a finished plan is stopped and forgotten once its card's build is spawned" \
  || bad "ABC-1's plan-1 is still listed ($(cat "$STUB_REGISTRY/p1" 2>/dev/null)): $out"
untouched b1 working 5102 \
  && ok "the working build that superseded it is untouched" \
  || bad "ABC-1's working build was stopped or forgotten: $out"

! listed o2 \
  && ok "a build row a newer fork of the same name replaced is forgotten" \
  || bad "ABC-2's old build-1 row is still listed: $out"
untouched f2 done 5202 \
  && ok "a live card's newest build row is neither stopped nor forgotten: the fix round resumes it" \
  || bad "ABC-2's current build-1 row was stopped or forgotten: $(cat "$STUB_REGISTRY/f2" 2>/dev/null) $out"
untouched r2 done 5203 \
  && ok "the card's newest agent has no successor and is left idling" \
  || bad "ABC-2's review-1, which nothing superseded, was touched: $out"

untouched a3 done 5301 && untouched c3 working 5302 \
  && ok "a review slot is not superseded by its sibling slot of the same round" \
  || bad "ABC-3's review-1a was stopped by its sibling slot: $out"

! listed p9 && ! listed r9 \
  && ok "a card out of flight has its finished agents settled without a ticket-mode sweep" \
  || bad "ABC-9's plan or review is still listed: $out"
untouched b9 done 5902 \
  && ok "but its resumable build is neither stopped nor forgotten: a person may send the card back" \
  || bad "ABC-9's resumable build was stopped or forgotten: $(cat "$STUB_REGISTRY/b9" 2>/dev/null) $out"

untouched tk done 6001 && ok "the tick is untouched" || bad "the tick was stopped or forgotten: $out"
untouched op done 6002 && ok "a session foreman did not name is untouched" \
  || bad "the operator's own session was stopped or forgotten: $out"
untouched bt done 6003 && ok "another board's agent for the same ticket key is untouched" \
  || bad "beta's ABC-1 plan was stopped by alpha: $out"
untouched cl done 6004 && ok "the scheduled cleanup's agent is not a card's and is untouched" \
  || bad "the cleanup agent was stopped or forgotten: $out"

[[ -f "$projects/$(slug "$(wt alpha ABC-1-plan-1)")/p1-sid.jsonl" \
   && -f "$projects/$(slug "$(wt alpha ABC-2)")/o2-sid.jsonl" \
   && -f "$projects/$(slug "$(wt alpha ABC-2)")/f2-sid.jsonl" ]] \
  && ok "no transcript is removed, not even a forgotten session's" \
  || bad "the settle pass removed transcripts: $out"
[[ -d "$(wt alpha ABC-1-plan-1)" && -d "$(wt alpha ABC-2)" ]] \
  && ok "no worktree is removed" \
  || bad "the settle pass removed a worktree: $out"
! grep -q . "$cards"/*/history.jsonl 2>/dev/null \
  && ok "no card history is written and no slot released" \
  || bad "the settle pass wrote card history: $(cat "$cards"/*/history.jsonl)"

# --- the kept build still resumes --------------------------------------------
printf 'fix it\n' > "$work/prompt.md"
if env HOME="$home" bash "$root/skills/board/harness/claude.sh" resume \
    --name foreman/alpha/ABC-2/build-1 --cwd "$(wt alpha ABC-2)" --prompt-file "$work/prompt.md" >/dev/null 2>"$work/err" \
   && [[ "$(cat "$STUB_RESUMED" 2>/dev/null)" == f2-sid ]]; then
  ok "a fix round resumes the kept build's session by name"
else
  bad "resuming ABC-2's build-1 failed: $(cat "$work/err") resumed=$(cat "$STUB_RESUMED" 2>/dev/null)"
fi

# --- and the worktree it resumes in survives an orphan pass -------------------
out="$(sweep --orphans)" || bad "sweep.sh --orphans exited non-zero: $out"
[[ -d "$(wt alpha ABC-2)" ]] \
  && ok "the orphan pass after it leaves the live card's build worktree" \
  || bad "--orphans reaped ABC-2's build worktree after the settle pass: $out"
[[ -d "$(wt alpha ABC-9)" ]] \
  && ok "and the build worktree of a card out of flight" \
  || bad "--orphans reaped ABC-9's build worktree after the settle pass: $out"

# --- a second pass has nothing to do -----------------------------------------
out="$(sweep --settle ABC-1 ABC-2 ABC-3)" || bad "a second sweep.sh --settle exited non-zero: $out"
untouched f2 done 5202 && untouched b9 done 5902 && untouched r2 done 5203 \
  && ok "a second pass settles nothing new and keeps the resumable builds" \
  || bad "a second pass changed the kept rows: $out"

# --- an unreadable registry is not an empty one ------------------------------
printf 'not json\n' > "$STUB_REGISTRY/zz"
out="$(sweep --settle ABC-1 ABC-2 ABC-3)" \
  && bad "sweep.sh --settle exited zero on an unreadable registry: $out" \
  || ok "an unreadable registry makes the settle pass exit non-zero"
untouched r2 done 5203 \
  && ok "and it stops nothing" \
  || bad "the settle pass acted on a registry it could not read: $out"

exit "$fail"
