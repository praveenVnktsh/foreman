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

# Polls for a path to be GONE, the mirror of wait_for_state: detached.sh's
# cleanup (trap on TERM, or the plain rm after a normal exit) runs in the
# wrapper process, not in this shell, so a bare `[[ ! -e ]]` right after a stop
# or a marker would race it.
wait_for_absence() { # <path>
  local tries=0
  while [[ "$tries" -lt "$POLL_TRIES" ]]; do
    [[ ! -e "$1" ]] && return 0
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
  # The MCP profile codex.sh writes. There is one foreman, so the name is the
  # constant codex.sh:_codex_profile_name prints -- not composed from anything
  # this fixture exports.
  CODEX_PROFILE=foreman
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

  # Claim: each run's TMPDIR is its own <id>.tmp under $FOREMAN_HOME/agents,
  # never this test's own TMPDIR. Before detached.sh set this per run, the
  # wrapper left TMPDIR as it found it, and opencode's leaked 5.4MB .so per
  # run piled 586 files / 3.1G into the shared /tmp between 2026-09-16 and
  # 2026-09-23, tripping preflight's min_free_tmp_mb and stopping dispatch.
  # Claude is exempt: claude.sh runs `claude --bg` directly, with no
  # detached.sh wrapper underneath it.
  probe_tmp=""
  if [[ "$harness" != claude ]]; then
    probe_id="$(agent_field probe id)"
    probe_tmp="$FOREMAN_HOME/agents/$probe_id.tmp"
    recorded_tmp=""
    tries=0
    while [[ "$tries" -lt "$POLL_TRIES" ]]; do
      recorded_tmp="$(tail -1 "$HARNESS_STUB_TMPDIRS" 2>/dev/null | awk '{print $1}')"
      [[ -n "$recorded_tmp" ]] && break
      sleep "$POLL_SECONDS"
      tries=$(( tries + 1 ))
    done
    same "$harness spawn gives the run its own TMPDIR under agents/<id>.tmp, not this test's" \
      "$probe_tmp" "$recorded_tmp"
  fi

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
  stopper_tmp=""
  [[ "$harness" != claude ]] && stopper_tmp="$FOREMAN_HOME/agents/$(agent_field stopper id).tmp"
  run_adapter stop "$(agent_field stopper id)"
  if wait_for_state stopper stopped; then ok "$harness stop moves that agent to stopped"
  else bad "$harness stop moves that agent to stopped"; fi

  # Claim: TERMing a run's process group also removes its run directory. The
  # wrapper's trap on TERM (detached.sh) is what makes a stopped agent leave
  # no .tmp/ behind for a KILL-only reap to have to clean up later.
  if [[ "$harness" != claude ]]; then
    if wait_for_absence "$stopper_tmp"; then
      ok "$harness stopping an agent with TERM removes its run directory"
    else
      bad "$harness run directory $stopper_tmp still exists after stop"
    fi
  fi

  : >"$HARNESS_STUB_MARKER"
  if wait_for_state probe done; then ok "$harness list shows the agent done once its work ends"
  else bad "$harness list shows the agent done once its work ends"; fi

  # Claim: a run directory is removed once its agent finishes normally, not
  # just when it is stopped. The wrapper's own `rm -rf "$RUN_TMP"` after the
  # harness call returns is what this pins; the trap above pins the signalled
  # path.
  if [[ "$harness" != claude ]]; then
    if wait_for_absence "$probe_tmp"; then
      ok "$harness run directory is removed once probe finishes on its own"
    else
      bad "$harness run directory $probe_tmp still exists once probe is done"
    fi
  fi

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

  # supervise.sh passes --remote-control on every tick it starts, whatever the
  # harness, so a spawn that refused it would leave that installation with no
  # tick at all. Only Claude Code has Remote Control; the other two accept the
  # flag and have nothing to register.
  rc_err="$work/$harness/rc.err"
  if run_adapter spawn --name watched --cwd "$agent_cwd" --model stub-model \
      --prompt-file "$prompt" --remote-control --skip-permissions >/dev/null 2>"$rc_err"; then
    ok "$harness spawn accepts --remote-control"
  else
    bad "$harness spawn --remote-control: $(cat "$rc_err")"
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

  # A remote server behind a bearer token, the shape the shared mcp.json takes
  # on the one live machine. codex.sh used to refuse every entry with
  # `headers`, so a codex tick could never start there. codex carries a bearer
  # token only through `bearer_token_env_var`, so the token must reach the
  # codex process as that variable and must be written down nowhere: not the
  # argv, not the profile, not agents/. Codex only, because the translation
  # into an environment variable is codex's alone.
  if [[ "$harness" == codex ]]; then
    bearer_canary=SECRET_BEARER_CANARY
    bearer_variable=FOREMAN_MCP_BOARD_REMOTE_BEARER
    # What the stub records for a variable holding the canary: a checksum,
    # never the value.
    bearer_seen="$bearer_variable $(printf '%s' "$bearer_canary" | cksum)"
    bearer_profile="${CODEX_HOME:-$HOME/.codex}/$CODEX_PROFILE.config.toml"
    bearer_json="$work/$harness/mcp-bearer.json"
    printf '{"mcpServers": {"board-remote": {"type": "http", "url": "https://example.invalid/mcp", "headers": {"Authorization": "Bearer %s"}}}}\n' \
      "$bearer_canary" >"$bearer_json"
    bearer_err="$work/$harness/bearer.err"

    : >"$HARNESS_STUB_ARGV"
    : >"$HARNESS_STUB_BEARER"
    if bearer_session="$(run_adapter spawn --name bearer --cwd "$agent_cwd" --model stub-model \
        --prompt-file "$prompt" --skip-permissions --mcp-config "$bearer_json" \
        2>"$bearer_err")"; then
      ok "$harness spawn accepts a remote mcp server with an Authorization: Bearer header"
    else
      bad "$harness spawn with an Authorization: Bearer header: $(cat "$bearer_err")"
    fi

    # codex hands its environment to every command the model runs, so the
    # token printed under `env` until the profile excluded it.
    if grep -qxF 'exclude = ["FOREMAN_MCP_*"]' "$bearer_profile" 2>/dev/null; then
      ok "$harness spawn writes the FOREMAN_MCP_* shell environment exclude into the profile"
    else
      bad "$harness spawn left exclude = [\"FOREMAN_MCP_*\"] out of $bearer_profile"
    fi

    # The stub prints an MCP error event naming the server url. Real codex
    # error output for a failing MCP server was NOT measured, so this proves
    # only that nothing between the harness and the log adds the token.
    bearer_log="$(run_adapter transcript "$agent_cwd" "${bearer_session:-none}" 2>/dev/null)"
    if [[ -n "$bearer_log" ]] && grep -qF "https://example.invalid/mcp" "$bearer_log" \
        && ! grep -q "$bearer_canary" "$bearer_log"; then
      ok "$harness log holds the MCP error event's url and not the bearer token"
    else
      bad "$harness log at '$bearer_log' lacks the MCP error url or holds the bearer token"
    fi

    if grep -qF "bearer_token_env_var = \"$bearer_variable\"" "$bearer_profile" 2>/dev/null; then
      ok "$harness spawn names the bearer token's environment variable in the profile"
    else
      bad "$harness spawn left bearer_token_env_var = \"$bearer_variable\" out of $bearer_profile"
    fi

    if grep -q "$bearer_canary" "$bearer_profile" 2>/dev/null; then
      bad "$harness spawn wrote a bearer token into the profile $bearer_profile"
    else
      ok "$harness spawn keeps a bearer token out of the profile"
    fi

    # What this proves is the ADAPTER: the stub never prints the token, so a
    # real codex writing it into its own --json log would not fail here.
    if grep -rq "$bearer_canary" "$FOREMAN_HOME/agents"; then
      bad "$harness adapter wrote the bearer token under $FOREMAN_HOME/agents"
    else
      ok "$harness adapter writes the bearer token into no file under agents/"
    fi

    if grep -q "$bearer_canary" "$HARNESS_STUB_ARGV"; then
      bad "$harness spawn put a bearer token in the harness argv"
    else
      ok "$harness spawn keeps a bearer token out of the harness argv"
    fi

    if grep -qxF "$bearer_seen" "$HARNESS_STUB_BEARER"; then
      ok "$harness spawn hands the bearer token to codex in $bearer_variable"
    else
      bad "$harness spawn did not hand codex $bearer_variable holding the token; the stub saw: $(cat "$HARNESS_STUB_BEARER")"
    fi

    # A resumed agent reconnects to the same server, so it needs the same
    # variable. Polled: resume returns before the detached stub has run.
    : >"$HARNESS_STUB_BEARER"
    run_adapter resume --name bearer --cwd "$agent_cwd" --prompt-file "$prompt" \
      --skip-permissions --mcp-config "$bearer_json" >/dev/null 2>"$bearer_err"
    tries=0
    while [[ "$tries" -lt "$POLL_TRIES" ]] && ! grep -qxF "$bearer_seen" "$HARNESS_STUB_BEARER"; do
      sleep "$POLL_SECONDS"
      tries=$(( tries + 1 ))
    done
    if grep -qxF "$bearer_seen" "$HARNESS_STUB_BEARER"; then
      ok "$harness resume hands the bearer token to codex in $bearer_variable"
    else
      bad "$harness resume did not hand codex $bearer_variable holding the token: $(cat "$bearer_err")"
    fi

    # Refusals name the header, because the header is what the operator edits.
    two_headers="$work/$harness/mcp-two-headers.json"
    printf '%s\n' '{"mcpServers": {"board-remote": {"type": "http", "url": "https://example.invalid/mcp", "headers": {"Authorization": "Bearer x", "X-Tenant": "acme"}}}}' >"$two_headers"
    if run_adapter spawn --name twoheaders --cwd "$agent_cwd" --model stub-model \
        --prompt-file "$prompt" --skip-permissions --mcp-config "$two_headers" \
        >/dev/null 2>"$bearer_err"; then
      bad "$harness spawn accepted a remote mcp server with a header codex cannot carry"
    elif grep -q "X-Tenant" "$bearer_err"; then
      ok "$harness spawn refuses a remote mcp server with a second header, naming it"
    else
      bad "$harness spawn refused a second header without naming it: $(cat "$bearer_err")"
    fi

    basic="$work/$harness/mcp-basic.json"
    printf '%s\n' '{"mcpServers": {"board-remote": {"type": "http", "url": "https://example.invalid/mcp", "headers": {"Authorization": "Basic x"}}}}' >"$basic"
    if run_adapter spawn --name basic --cwd "$agent_cwd" --model stub-model \
        --prompt-file "$prompt" --skip-permissions --mcp-config "$basic" \
        >/dev/null 2>"$bearer_err"; then
      bad "$harness spawn accepted an Authorization header that is not Bearer"
    elif grep -q "Authorization" "$bearer_err"; then
      ok "$harness spawn refuses an Authorization: Basic header, naming it"
    else
      bad "$harness spawn refused Authorization: Basic without naming it: $(cat "$bearer_err")"
    fi

    # codex renamed the flag that layers a profile file: `--profile-v2` on
    # 0.133.0, `--profile` on 0.154.0, where 0.133.0's `--profile` is another
    # mechanism. One fixed spelling loses every MCP server on one of the two.
    # `env`, not a prefix assignment, for the leak the reap claims record.
    for codex_version in 0.133.0 0.154.0; do
      case "$codex_version" in
        0.133.0) layer_flag=--profile-v2 ;;
        0.154.0) layer_flag=--profile ;;
      esac
      : >"$HARNESS_STUB_ARGV"
      : >"$HARNESS_STUB_PROFILES"
      : >"$HARNESS_STUB_BEARER"
      : >"$HARNESS_STUB_SHELL"
      if env HARNESS_STUB_CODEX_VERSION="$codex_version" "$adapter" spawn \
          --name "layer-$codex_version" --cwd "$agent_cwd" --model stub-model \
          --prompt-file "$prompt" --skip-permissions --mcp-config "$bearer_json" \
          >/dev/null 2>"$bearer_err" \
        && grep -qF -- " $layer_flag $CODEX_PROFILE " "$HARNESS_STUB_ARGV" \
        && grep -qxF "layered $bearer_profile" "$HARNESS_STUB_PROFILES"; then
        ok "$harness $codex_version spawn layers the MCP profile through $layer_flag"
      else
        bad "$harness $codex_version spawn did not layer the MCP profile through $layer_flag: $(cat "$bearer_err") argv: $(cat "$HARNESS_STUB_ARGV")"
      fi

      # codex holds the token; a command the model runs does not. The version
      # variable is the control that shows the shell view was recorded at all.
      if grep -qxF "$bearer_seen" "$HARNESS_STUB_BEARER" \
          && grep -q "^HARNESS_STUB_CODEX_VERSION " "$HARNESS_STUB_SHELL" \
          && ! grep -q "^$bearer_variable " "$HARNESS_STUB_SHELL"; then
        ok "$harness $codex_version hides $bearer_variable from commands the model runs while codex holds it"
      else
        bad "$harness $codex_version shell view: $(cat "$HARNESS_STUB_SHELL") codex view: $(cat "$HARNESS_STUB_BEARER")"
      fi

      # Resume on the same version: the flag goes BEFORE `resume`, which both
      # versions (and so the stub) require. Polled: resume returns before the
      # detached stub has run.
      : >"$HARNESS_STUB_ARGV"
      : >"$HARNESS_STUB_PROFILES"
      env HARNESS_STUB_CODEX_VERSION="$codex_version" "$adapter" resume \
        --name "layer-$codex_version" --cwd "$agent_cwd" --prompt-file "$prompt" \
        --skip-permissions --mcp-config "$bearer_json" >/dev/null 2>"$bearer_err"
      tries=0
      while [[ "$tries" -lt "$POLL_TRIES" ]] && ! grep -qxF "layered $bearer_profile" "$HARNESS_STUB_PROFILES"; do
        sleep "$POLL_SECONDS"
        tries=$(( tries + 1 ))
      done
      if grep -qF -- " $layer_flag $CODEX_PROFILE resume " "$HARNESS_STUB_ARGV" \
          && grep -qxF "layered $bearer_profile" "$HARNESS_STUB_PROFILES"; then
        ok "$harness $codex_version resume layers the MCP profile through $layer_flag before resume"
      else
        bad "$harness $codex_version resume did not layer the MCP profile through $layer_flag before resume: $(cat "$bearer_err") argv: $(cat "$HARNESS_STUB_ARGV")"
      fi
    done

    # A codex that waits on an open stdin. The adapter is handed a stdin that
    # stays open -- a fifo with a writer that never closes it -- and the agent
    # must still finish. Measured 2026-09-14: with all three `</dev/null` in
    # detached.sh removed this claim STILL passes, because a non-interactive
    # shell gives an asynchronous list (`nohup ... &`) stdin from /dev/null on
    # its own. So it does not pin the redirects; it catches a spawn that ever
    # hands the harness the caller's stdin explicitly, which is the hang codex
    # 0.154.0 showed over ssh.
    stdin_fifo="$work/$harness/stdin.fifo"
    mkfifo "$stdin_fifo"
    sleep 120 >"$stdin_fifo" &
    stdin_holder=$!
    if env HARNESS_STUB_CODEX_VERSION=0.154.0 "$adapter" spawn --name stdinreader \
        --cwd "$agent_cwd" --model stub-model --prompt-file "$prompt" \
        --skip-permissions <"$stdin_fifo" >/dev/null 2>"$bearer_err" \
      && wait_for_state stdinreader done; then
      ok "$harness spawn reaches done when codex reads stdin to EOF"
    else
      bad "$harness spawn with an open stdin never reached done: $(cat "$bearer_err")"
    fi
    # `wait` reaps it here, so bash prints no "Terminated" job notice later.
    { kill "$stdin_holder"; wait "$stdin_holder"; } 2>/dev/null || true
  fi

  # `opencode run --format json` prints nothing until the model's first step
  # has output. Measured 2026-09-14: spawn gave up after 15 seconds, which
  # killed the first real tick with an empty log, and its message named neither
  # the model nor the live process, so a model that never answers read as an
  # adapter bug. The wait is lowered to SESSION_WAIT seconds here so the suite
  # does not sit out the two-minute default per claim.
  if [[ "$harness" == opencode ]]; then
    SESSION_WAIT=6
    # How long stopping a hung stub may add after the wait, in seconds: a TERM
    # to its group ends it at once, and python polls add well under a second.
    STOP_SLACK=3
    wait_err="$work/$harness/session-wait.err"

    if env FOREMAN_OPENCODE_SESSION_WAIT_SECONDS="$SESSION_WAIT" \
        HARNESS_STUB_OPENCODE_FIRST_EVENT=after-3 \
        "$adapter" spawn --name slowmodel --cwd "$agent_cwd" --model stub-slow-model \
        --prompt-file "$prompt" --skip-permissions >/dev/null 2>"$wait_err"; then
      ok "$harness spawn waits for a model whose first event comes late, up to the session wait"
    else
      bad "$harness spawn gave up on a model that answered in 3s of a ${SESSION_WAIT}s wait: $(cat "$wait_err")"
    fi

    started=$SECONDS
    if env FOREMAN_OPENCODE_SESSION_WAIT_SECONDS="$SESSION_WAIT" \
        HARNESS_STUB_OPENCODE_FIRST_EVENT=never \
        "$adapter" spawn --name hungmodel --cwd "$agent_cwd" --model stub-hung-model \
        --prompt-file "$prompt" --skip-permissions >/dev/null 2>"$wait_err"; then
      bad "$harness spawn succeeded for a model that never prints"
    else
      elapsed=$(( SECONDS - started ))
      if [[ "$elapsed" -le $(( SESSION_WAIT + STOP_SLACK )) ]]; then
        ok "$harness spawn gives up on a model that never prints within the session wait"
      else
        bad "$harness spawn took ${elapsed}s to give up with a ${SESSION_WAIT}s session wait"
      fi
      if grep -qF "stub-hung-model" "$wait_err"; then
        ok "$harness spawn names the model that never printed"
      else
        bad "$harness spawn's timeout does not name the model: $(cat "$wait_err")"
      fi
      if wait_for_state hungmodel stopped; then
        ok "$harness spawn stops a model that never printed before giving up"
      else
        bad "$harness spawn left a model that never printed at $(agent_field hungmodel state)"
      fi
    fi
    # Leave nothing hung behind, whatever the claims above found.
    run_adapter stop "$(agent_field hungmodel id)" >/dev/null 2>&1 || true

    started=$SECONDS
    if env FOREMAN_OPENCODE_SESSION_WAIT_SECONDS="$SESSION_WAIT" \
        HARNESS_STUB_OPENCODE_FIRST_EVENT=exit \
        "$adapter" spawn --name deadmodel --cwd "$agent_cwd" --model stub-dead-model \
        --prompt-file "$prompt" --skip-permissions >/dev/null 2>"$wait_err"; then
      bad "$harness spawn succeeded for an opencode that exited without printing"
    else
      elapsed=$(( SECONDS - started ))
      if [[ "$elapsed" -lt $(( SESSION_WAIT / 2 )) ]]; then
        ok "$harness spawn stops waiting as soon as opencode exits"
      else
        bad "$harness spawn took ${elapsed}s of a ${SESSION_WAIT}s wait to notice opencode had exited"
      fi
      if grep -qF "OpenCode exited before naming a session" "$wait_err"; then
        ok "$harness spawn says opencode exited before naming a session"
      else
        bad "$harness spawn's error for an exited opencode: $(cat "$wait_err")"
      fi
    fi
  fi

  if [[ -n "$(run_adapter skills-dir)" ]]; then ok "$harness skills-dir prints a path"
  else bad "$harness skills-dir prints a path"; fi

  if [[ -n "$(run_adapter skill-prompt board)" ]]; then
    ok "$harness skill-prompt names the board skill in one non-empty line"
  else
    bad "$harness skill-prompt names the board skill in one non-empty line"
  fi

  # A skill-prompt that STOPS at the invocation runs no pass. Measured
  # 2026-09-19: opencode's skill tool returns the skill text and the run ends,
  # so a prompt reading only "use skill tool to load board" gave one tool call
  # per session and no board pass -- the board silently stopped moving. The
  # prompt must ask for the pass in the same breath as the load. Claude differs
  # (`/loop` loops inside one session), so this pins the two harnesses whose
  # wrapper re-invokes the CLI once per pass.
  if [[ "$harness" != "claude" ]]; then
    prompt_text="$(run_adapter skill-prompt board)"
    case "$prompt_text" in
      *pass*) ok "$harness skill-prompt asks for a pass, not only an invocation" ;;
      *) bad "$harness skill-prompt stops at the invocation and would run no pass: $prompt_text" ;;
    esac

    # AND IT MUST NOT CAP THE TICK AT ONE PASS. The clause above used to read
    # "carry out one full pass", which satisfies `*pass*` -- so this test
    # passed while the tick was stopping after a single pass. Measured
    # 2026-09-21: a session ended its own report with "this was exactly one
    # pass as you asked... the skill's loop would run a second pass... I
    # stopped here", on a board with twelve cards in Todo and seven of ten
    # host slots free.
    #
    # SKILL.md is the contract -- "a tick runs until it stops making progress,
    # not once" -- and TICK_BUDGET_MINUTES and TICK_MAX_PASSES bound that loop.
    # A prompt that asks for one pass reaches neither.
    case "$prompt_text" in
      *"one full pass"*|*"one pass"*|*"a single pass"*)
        bad "$harness skill-prompt caps the tick at one pass, which SKILL.md's loop and budget knobs then bound nothing of: $prompt_text" ;;
      *) ok "$harness skill-prompt does not cap the tick at a single pass" ;;
    esac

    # The stop conditions are the skill's, so the prompt has to name work that
    # REPEATS rather than work that happens once.
    case "$prompt_text" in
      *"pass after pass"*|*passes*|*loop*)
        ok "$harness skill-prompt asks for repeated passes" ;;
      *) bad "$harness skill-prompt names no repetition, so one pass is a fair reading: $prompt_text" ;;
    esac
  fi

  # The loop, counted from the marker side: every pass now ends at once, so
  # what lands in the runs file is one line per pass and nothing else. Reset
  # first, because every verb above has already run the binary.
  : >"$HARNESS_STUB_RUNS"
  : >"$HARNESS_STUB_TMPDIRS"
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

  # Claim: the loop wrapper's `rm -rf "$RUN_TMP"` before each pass's `mkdir`
  # (detached.sh) gives every pass a fresh, empty TMPDIR, even though the
  # stub itself drops a leaked .stub-00000000.so into it every single pass.
  # Without that rm-then-mkdir, pass two would inherit pass one's leak and
  # every later pass would read "dirty" -- the shape of the 586-file,
  # 3.1G production leak (2026-09-16 to 2026-09-23), reproduced one pass at
  # a time instead of one run at a time.
  if [[ "$harness" != claude ]]; then
    tmpdir_runs="$(wc -l <"$HARNESS_STUB_TMPDIRS" | tr -d ' ')"
    if [[ "$tmpdir_runs" -ge 2 ]] && ! grep -q ' dirty$' "$HARNESS_STUB_TMPDIRS"; then
      ok "$harness spawn --loop-minutes gives every pass its own empty run directory"
    else
      bad "$harness loop recorded $tmpdir_runs run(s); tmpdirs: $(cat "$HARNESS_STUB_TMPDIRS")"
    fi
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

    # A run KILLed before its own cleanup, or a process that just never got a
    # chance to run its trap, leaves <id>.tmp/ behind with the harness's
    # leaked file still in it. detached_reap's SUFFIXES list names .tmp
    # beside .json, .log and .sh for exactly this: nothing else reaps it.
    reapable_tmp="$FOREMAN_HOME/agents/$reapable.tmp"
    mkdir -p "$reapable_tmp"
    : >"$reapable_tmp/leaked.so"

    # An agent that is certainly working: this test's own shell, with the start
    # time the kernel gave it, which is what makes the pid mean this process and
    # not a later one reusing the number. startedAt 1 puts it far outside every
    # window below, so `working` is the only thing that can save it.
    printf '{"name":"livewire","cwd":"%s","pid":%s,"startedBy":"%s","sessionId":"","startedAt":1,"log":"%s"}\n' \
      "$agent_cwd" "$$" "$(ps -o lstart= -p $$)" "$FOREMAN_HOME/agents/livewire.log" \
      >"$FOREMAN_HOME/agents/livewire.json"
    : >"$FOREMAN_HOME/agents/livewire.log"
    : >"$FOREMAN_HOME/agents/livewire.sh"
    livewire_tmp="$FOREMAN_HOME/agents/livewire.tmp"
    mkdir -p "$livewire_tmp"
    : >"$livewire_tmp/leaked.so"

    same "$harness reap leaves a record inside the retention window alone" \
      "" "$(run_adapter reap 999999)"
    if [[ -d "$reapable_tmp" ]]; then
      ok "$harness reap 999999 leaves a finished agent's leftover run directory alone"
    else
      bad "$harness reap 999999 removed $reapable_tmp, which is inside the retention window"
    fi

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
    if [[ -d "$reapable_tmp" ]]; then
      ok "$harness reap under BOARD_DRY_RUN leaves a finished agent's leftover run directory alone"
    else
      bad "$harness reap under BOARD_DRY_RUN removed $reapable_tmp"
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
    if [[ ! -e "$reapable_tmp" ]]; then
      ok "$harness reap removes a finished agent's leftover run directory"
    else
      bad "$harness reap left $reapable_tmp behind"
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
    if [[ -d "$livewire_tmp" ]]; then
      ok "$harness reap never takes a working agent's run directory"
    else
      bad "$harness reap deleted $livewire_tmp from an agent that is still working"
    fi
  fi

  export HOME="$ORIGINAL_HOME"
  export PATH="$ORIGINAL_PATH"
  unset FOREMAN_HOME
  unset CODEX_PROFILE
done

exit "$fail"
