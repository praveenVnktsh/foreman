#!/usr/bin/env bash
# Claim: claude.sh, codex.sh and opencode.sh answer the same nine verbs the
# same way, so every caller that runs "$HARNESS_SH" gets one contract whatever
# the installation's harness is.
#
# The failure it prevents: an adapter that is almost right. Every script on the
# board reads `list` for liveness, `transcript` for an mtime and `spawn` for a
# session id. An adapter whose `list` never leaves `working` makes `sweep.sh`
# hold worktrees forever; one whose `spawn` prints its own id instead of the
# harness's makes every `resume` start a fresh session and lose the build. Both
# look like a working installation from outside, on the harness nobody watches.
#
# So the script of verbs below is written ONCE and run against all three. A
# claim that holds on Claude and not on Codex is a difference between adapters,
# which is the only thing this test is about.
#
# It drives the real adapters, and detached.sh underneath two of them, against
# stub binaries on PATH -- see tests/lib/harness-stub.sh for what each stub
# stands for. Nothing inside the adapters is stubbed.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"

# shellcheck source=lib/harness-stub.sh
source "$here/lib/harness-stub.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ORIGINAL_HOME="$HOME"
ORIGINAL_PATH="$PATH"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
# $1 name, $2 expected, $3 actual
same() {
  if [[ "$2" == "$3" ]]; then ok "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3" >&2; fail=1; fi
}

# How long a poll waits before it calls a state change lost, and how often it
# looks. Ten seconds because `list` reads a file some OTHER process writes: a
# detached agent notices the marker, exits, and its wrapper records the exit
# some milliseconds later. A fixed sleep instead of a poll is what makes a
# suite slow on a fast machine and flaky on a loaded one.
POLL_TRIES=100
POLL_SECONDS=0.1

# How long the loop test watches, in seconds, and the interval it spawns with.
# 0.02 minutes is 1.2 seconds, so four seconds holds three or four passes --
# comfortably more than one, and short enough to sit in a test suite.
LOOP_MINUTES=0.02
LOOP_WATCH_SECONDS=4

adapter=""
run_adapter() { "$adapter" "$@"; }

# The named field of the newest agent called <name>, out of the adapter's own
# `list`. Newest, because a resume adds a second row under one name on every
# harness, and every consumer in the board reads the latest startedAt.
agent_field() { # <name> <field>
  run_adapter list | python3 -c '
import json, sys

want, field = sys.argv[1], sys.argv[2]
rows = [r for r in json.load(sys.stdin) if r.get("name") == want]
if rows:
    value = max(rows, key=lambda r: r.get("startedAt") or 0).get(field)
    print("" if value is None else value)
' "$1" "$2"
}

wait_for_state() { # <name> <state>
  local tries=0
  while [[ "$tries" -lt "$POLL_TRIES" ]]; do
    [[ "$(agent_field "$1" state)" == "$2" ]] && return 0
    sleep "$POLL_SECONDS"
    tries=$(( tries + 1 ))
  done
  return 1
}

mtime_of() { # <path>
  python3 -c '
import os, sys

try:
    print(os.stat(sys.argv[1]).st_mtime)
except OSError:
    print("")
' "$1"
}

wait_for_mtime_change() { # <path> <mtime>
  local tries=0
  while [[ "$tries" -lt "$POLL_TRIES" ]]; do
    [[ "$(mtime_of "$1")" != "$2" ]] && return 0
    sleep "$POLL_SECONDS"
    tries=$(( tries + 1 ))
  done
  return 1
}

for harness in claude codex opencode; do
  adapter="$root/skills/board/harness/$harness.sh"

  # A fresh home per adapter, so nothing one adapter recorded can answer for
  # another. HOME is where claude.sh puts its transcripts and where all three
  # put their skills-dir; FOREMAN_HOME is where detached.sh keeps agents/.
  home="$work/$harness/home"
  agent_cwd="$work/$harness/worktree"
  mkdir -p "$home" "$agent_cwd"
  harness_stub_install "$work/$harness/bin" "$work/$harness/state"
  export HOME="$home"
  export FOREMAN_HOME="$home/.foreman/stub"
  export PATH="$work/$harness/bin:$ORIGINAL_PATH"
  # The installation this home belongs to. config.sh exports it for every real
  # caller, and codex.sh refuses to write an MCP profile without it rather than
  # guess which installation's credential it is holding.
  export INSTALLATION=stub
  # agents/ up front, because the credential claim below greps the whole
  # directory and claude.sh never creates one.
  mkdir -p "$FOREMAN_HOME/agents"

  prompt="$work/$harness/prompt.md"
  echo "do the thing" >"$prompt"

  spawned="$(run_adapter spawn --name probe --cwd "$agent_cwd" \
    --model stub-model --prompt-file "$prompt" --skip-permissions)"
  if [[ -n "$spawned" ]]; then ok "$harness spawn prints a session id"
  else bad "$harness spawn prints a session id"; fi

  same "$harness list shows the agent it just spawned as working" \
    "working" "$(agent_field probe state)"

  transcript="$(run_adapter transcript "$agent_cwd" "$spawned")"
  if [[ -n "$transcript" ]]; then ok "$harness transcript prints a path for a live session"
  else bad "$harness transcript prints a path for a live session"; fi

  if wait_for_mtime_change "$transcript" "$(mtime_of "$transcript")"; then
    ok "$harness transcript names the file a working agent keeps touching"
  else
    bad "$harness transcript names the file a working agent keeps touching"
  fi

  # Stopped BEFORE the marker exists: an agent that had already finished would
  # read `done` whether or not `stop` did anything, so the claim would be true
  # of an adapter whose `stop` is a no-op.
  run_adapter spawn --name stopper --cwd "$agent_cwd" \
    --model stub-model --prompt-file "$prompt" --skip-permissions >/dev/null
  run_adapter stop "$(agent_field stopper id)"
  if wait_for_state stopper stopped; then ok "$harness stop moves that agent to stopped"
  else bad "$harness stop moves that agent to stopped"; fi

  : >"$HARNESS_STUB_MARKER"
  if wait_for_state probe done; then ok "$harness list shows the agent done once its work ends"
  else bad "$harness list shows the agent done once its work ends"; fi

  # A sweep of a terminal card stops agents that already finished. Afterwards
  # they must list as stopped on every harness, or the sweep waits out its
  # timeout, fails the card, and keeps its worktree as a live agent's.
  run_adapter spawn --name finisher --cwd "$agent_cwd" \
    --model stub-model --prompt-file "$prompt" --skip-permissions >/dev/null
  if wait_for_state finisher done; then
    run_adapter stop "$(agent_field finisher id)" >/dev/null 2>&1 || true
    if wait_for_state finisher stopped; then ok "$harness stop moves a finished agent to stopped"
    else bad "$harness stop left a finished agent at $(agent_field finisher state)"; fi
  else
    bad "$harness finisher never reached done, so stopping a finished agent went untested"
  fi

  same "$harness resume continues the session spawn started" \
    "$spawned" "$(run_adapter resume --name probe --cwd "$agent_cwd" \
      --prompt-file "$prompt" --skip-permissions)"

  if run_adapter check >/dev/null 2>&1; then ok "$harness check exits 0 when its binary runs"
  else bad "$harness check exits 0 when its binary runs"; fi

  # The spend ceiling is the one flag the three adapters do NOT agree on, by
  # design: only Claude Code has one. The claim is the same on every harness --
  # a cap the operator set is never silently dropped -- and it is met two ways:
  # claude passes it through, the other two refuse it by name.
  budget_err="$work/$harness/budget.err"
  if run_adapter spawn --name capped --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" --skip-permissions --max-budget-usd 5 >/dev/null 2>"$budget_err"; then
    if [[ "$harness" == claude ]]; then ok "$harness spawn accepts --max-budget-usd and passes it through"
    else bad "$harness spawn accepted --max-budget-usd, a cap it cannot hold"; fi
  else
    if [[ "$harness" != claude ]] && grep -q "max-budget-usd" "$budget_err"; then
      ok "$harness spawn refuses --max-budget-usd by name"
    else
      bad "$harness spawn --max-budget-usd: $(cat "$budget_err")"
    fi
  fi

  # An unreadable home must never answer "nothing is running". opencode.sh used
  # to default FOREMAN_HOME to $HOME/.foreman, so a caller that had not set one
  # got `[]` and exit 0 -- the single answer that lets supervise.sh start a
  # second tick beside a healthy one and lets dispatch.sh land on a live build.
  # claude.sh is exempt: its registry is `claude agents`, not a home.
  if [[ "$harness" != claude ]]; then
    homeless="$work/$harness/homeless.out"
    if env -u FOREMAN_HOME "$adapter" list >"$homeless" 2>/dev/null; then
      bad "$harness list with no FOREMAN_HOME answered instead of refusing"
    elif [[ -s "$homeless" ]]; then
      bad "$harness list with no FOREMAN_HOME printed on stdout: $(cat "$homeless")"
    else
      ok "$harness list with no FOREMAN_HOME refuses and prints nothing"
    fi
  fi

  # A pid is a recycled number. After a reboot, an OOM kill or a wraparound,
  # the pid in a record left at `working` belongs to something else, and the
  # row used to report `working` forever: the card is never re-dispatched, the
  # worktree is never swept, and `stop` signals a stranger's process group. The
  # record below names a pid that is certainly alive -- this test's own shell --
  # with a start time that is certainly not its own.
  if [[ "$harness" != claude ]]; then
    printf '{"name":"zombie","cwd":"%s","pid":%s,"startedBy":"Thu Jan  1 00:00:00 1970","sessionId":"","startedAt":1,"log":"%s"}\n' \
      "$agent_cwd" "$$" "$agent_cwd/zombie.log" >"$FOREMAN_HOME/agents/zombie.json"
    same "$harness list reads a live pid with a different start time as stopped" \
      "stopped" "$(agent_field zombie state)"
    rm -f "$FOREMAN_HOME/agents/zombie.json"
  fi

  # Neither codex nor opencode can be left to ask a question here: they run
  # from a wrapper with no TTY, so an approval request waits for an answer
  # nobody types while `list` calls the agent `working`. The claim is the same
  # on every harness -- an agent is never left waiting on a prompt -- and it is
  # met two ways: claude has a permission mode that keeps working, the other
  # two refuse the spawn.
  unattended="$work/$harness/unattended.err"
  if run_adapter spawn --name unattended --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" >/dev/null 2>"$unattended"; then
    if [[ "$harness" == claude ]]; then ok "$harness spawn runs without --skip-permissions"
    else bad "$harness spawn without --skip-permissions started an agent that can block"; fi
  else
    # The refusal has to name AGENT_SKIP_PERMISSIONS, the switch the operator
    # actually holds. "spawn failed" sends them to the adapter; naming the
    # variable sends them to the one line they have to change.
    if [[ "$harness" != claude ]] && grep -q AGENT_SKIP_PERMISSIONS "$unattended"; then
      ok "$harness spawn refuses without --skip-permissions, naming the switch that turns it on"
    else
      bad "$harness spawn without --skip-permissions: $(cat "$unattended")"
    fi
  fi

  # The Linear credential lives in an mcp.json server's `env`. codex.sh used to
  # interpolate it into `-c mcp_servers.<name>.env.<KEY>=<value>`, which put it
  # in the codex argv -- readable through /proc/<pid>/cmdline -- and then
  # verbatim into detached.sh's generated wrapper at mode 0644, forever.
  # opencode.sh wrote it into `agents/mcp-<name>-<pid>-<ms>.json` at 0644 and
  # never deleted it. The claim covers both: not in the argv, not under
  # agents/.
  canary="$work/$harness/mcp-canary.json"
  printf '%s\n' \
    '{"mcpServers": {"board": {"command": "npx", "args": ["-y", "some-mcp"], "env": {"BOARD_KEY": "SECRET_CANARY_VALUE"}}}}' \
    >"$canary"
  canary_err="$work/$harness/canary.err"
  if run_adapter spawn --name canary --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" --skip-permissions --mcp-config "$canary" \
      >/dev/null 2>"$canary_err"; then
    if grep -q SECRET_CANARY_VALUE "$HARNESS_STUB_ARGV"; then
      bad "$harness spawn put an mcp.json credential in the harness argv"
    elif grep -rq SECRET_CANARY_VALUE "$FOREMAN_HOME/agents"; then
      bad "$harness spawn wrote an mcp.json credential under $FOREMAN_HOME/agents"
    else
      ok "$harness spawn keeps an mcp.json credential out of the argv and out of agents/"
    fi
  else
    bad "$harness spawn with --mcp-config: $(cat "$canary_err")"
  fi

  # A remote MCP server, the shape a hosted control plane takes. codex.sh used
  # to demand a `command` key, so one remote entry in the shared mcp.json
  # refused every codex spawn on the installation while opencode translated the
  # same entry without complaint.
  remote="$work/$harness/mcp-remote.json"
  printf '%s\n' '{"mcpServers": {"board": {"type": "http", "url": "https://example.invalid/mcp"}}}' >"$remote"
  remote_err="$work/$harness/remote.err"
  if run_adapter spawn --name remoter --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" --skip-permissions --mcp-config "$remote" \
      >/dev/null 2>"$remote_err"; then
    ok "$harness spawn accepts a remote mcp server entry"
  else
    bad "$harness spawn with a remote mcp server: $(cat "$remote_err")"
  fi

  if [[ -n "$(run_adapter skills-dir)" ]]; then ok "$harness skills-dir prints a path"
  else bad "$harness skills-dir prints a path"; fi

  if [[ -n "$(run_adapter skill-prompt board)" ]]; then
    ok "$harness skill-prompt names the board skill in one non-empty line"
  else
    bad "$harness skill-prompt names the board skill in one non-empty line"
  fi

  # The loop, counted from the marker side: every pass now ends at once, so
  # what lands in the runs file is one line per pass and nothing else. Reset
  # first, because every verb above has already run the binary.
  : >"$HARNESS_STUB_RUNS"
  run_adapter spawn --name looper --cwd "$agent_cwd" --model stub-model \
    --prompt-file "$prompt" --skip-permissions --loop-minutes "$LOOP_MINUTES" >/dev/null
  sleep "$LOOP_WATCH_SECONDS"
  passes="$(wc -l <"$HARNESS_STUB_RUNS" | tr -d ' ')"
  # Claude's adapter ignores --loop-minutes on purpose: `/loop` repeats the
  # prompt INSIDE one session, so a wrapper loop here would start a second
  # agent every interval beside the one already looping.
  if [[ "$harness" == claude ]]; then
    same "$harness spawn --loop-minutes runs the harness once, because /loop repeats inside the session" \
      "1" "$passes"
  elif [[ "$passes" -gt 1 ]]; then
    ok "$harness spawn --loop-minutes runs the harness again after the interval"
  else
    printf 'FAIL %s\n  the harness ran %s time(s) in %ss at --loop-minutes %s\n' \
      "$harness spawn --loop-minutes runs the harness again after the interval" \
      "$passes" "$LOOP_WATCH_SECONDS" "$LOOP_MINUTES" >&2
    fail=1
  fi
  # Leave nothing looping behind this iteration: the wrapper outlives this
  # test by design, and a stray loop would keep re-running a stub against a
  # directory the EXIT trap is about to delete.
  run_adapter stop "$(agent_field looper id)" >/dev/null 2>&1 || true

  # Nothing used to delete what a spawn leaves behind. codex and opencode have
  # no registry, so detached.sh writes <id>.json, <id>.log and <id>.sh per spawn
  # under $FOREMAN_HOME/agents, and `list` globs and JSON-parses every record
  # ever written -- on every dispatch gate, every sweep, every watch-agents poll
  # and every supervise fire. Unbounded disk, and a liveness check that got
  # slower for as long as the installation lived. sweep.sh's orphan pass calls
  # this verb; the claims are here because reaping is a property of the adapter
  # contract, and an adapter that reaped a WORKING agent would delete the log it
  # still has open.
  if [[ "$harness" == claude ]]; then
    # Claude's registry is Claude's, and Claude Code ages it out. The verb still
    # has to exist and still has to succeed, so sweep.sh calls one verb on every
    # installation instead of branching on the harness.
    claude_reap="$work/$harness/reap.out"
    if run_adapter reap 0 >"$claude_reap" 2>&1 && [[ ! -s "$claude_reap" ]]; then
      ok "$harness reap exits 0 and prints nothing, because its registry is not a directory it owns"
    else
      bad "$harness reap 0 should exit 0 and print nothing, got: $(cat "$claude_reap")"
    fi
  else
    # A home of its own. Reaping in the shared one would delete the records
    # every claim above just made, and the next claim would then be testing an
    # empty directory.
    export FOREMAN_HOME="$work/$harness/reap-home"
    mkdir -p "$FOREMAN_HOME/agents"

    # The marker is already there, so this agent finishes as soon as it starts.
    run_adapter spawn --name reapable --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" --skip-permissions >/dev/null
    reapable="$(agent_field reapable id)"
    wait_for_state reapable done \
      || bad "$harness reap claims need a done agent; reapable sat at $(agent_field reapable state)"

    # An agent that is certainly working: this test's own shell, with the start
    # time the kernel gave it, which is what makes the pid mean this process and
    # not a later one reusing the number. startedAt 1 puts it far outside every
    # window below, so `working` is the only thing that can save it.
    printf '{"name":"livewire","cwd":"%s","pid":%s,"startedBy":"%s","sessionId":"","startedAt":1,"log":"%s"}\n' \
      "$agent_cwd" "$$" "$(ps -o lstart= -p $$)" "$FOREMAN_HOME/agents/livewire.log" \
      >"$FOREMAN_HOME/agents/livewire.json"
    : >"$FOREMAN_HOME/agents/livewire.log"
    : >"$FOREMAN_HOME/agents/livewire.sh"

    same "$harness reap leaves a record inside the retention window alone" \
      "" "$(run_adapter reap 999999)"

    # BOARD_DRY_RUN says what a real sweep would take and takes nothing, the
    # same promise every other deletion sweep.sh makes keeps.
    # `env`, not an assignment in front of `run_adapter`: bash leaves an
    # assignment that prefixes a SHELL FUNCTION in effect after the function
    # returns, and a leaked BOARD_DRY_RUN would make the real reap below a
    # second dry run that deleted nothing while every claim still passed.
    same "$harness reap under BOARD_DRY_RUN names the agent it would take" \
      "$reapable" "$(env BOARD_DRY_RUN=1 "$adapter" reap 0)"
    if [[ -f "$FOREMAN_HOME/agents/$reapable.json" ]]; then
      ok "$harness reap under BOARD_DRY_RUN deletes nothing"
    else
      bad "$harness reap under BOARD_DRY_RUN deleted $reapable.json"
    fi

    same "$harness reap prints one line per agent it took" \
      "$reapable" "$(run_adapter reap 0)"
    left=""
    for suffix in json log sh; do
      [[ -e "$FOREMAN_HOME/agents/$reapable.$suffix" ]] && left="$left .$suffix"
    done
    if [[ -z "$left" ]]; then
      ok "$harness reap deletes a finished agent's record, log and wrapper"
    else
      bad "$harness reap left$left behind for $reapable"
    fi

    kept=""
    for suffix in json log sh; do
      [[ -e "$FOREMAN_HOME/agents/livewire.$suffix" ]] || kept="$kept .$suffix"
    done
    if [[ -z "$kept" ]]; then
      ok "$harness reap never takes a working agent"
    else
      bad "$harness reap deleted$kept from an agent that is still working"
    fi
  fi

  export HOME="$ORIGINAL_HOME"
  export PATH="$ORIGINAL_PATH"
  unset FOREMAN_HOME
  unset INSTALLATION
done

exit "$fail"
