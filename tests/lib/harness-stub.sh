#!/usr/bin/env bash
# Stub `claude`, `codex` and `opencode` on PATH, so the three harness adapters
# can be driven for real without a subscription, a network or a model.
#
# It stubs at the external boundary and nothing inside it. The adapters, and
# detached.sh underneath two of them, run exactly as they do in production:
# the argv, the record files, the process group, the loop and the session-id
# parsing are all the real code. Only the three binaries are fake.
#
# SOURCE IT, DO NOT RUN IT. It defines one function.
#
#   harness_stub_install <bin_dir> <state_dir>
#       Writes claude, codex and opencode into <bin_dir>, keeping their state
#       under <state_dir>, and sets:
#         HARNESS_STUB_MARKER   create this file to end every agent's work
#         HARNESS_STUB_RUNS     one line per harness invocation
#         HARNESS_STUB_ARGV     one line per invocation, holding its whole argv
#         HARNESS_STUB_BEARER   per codex invocation, one `<VARIABLE> <cksum>`
#                               line per FOREMAN_MCP_*_BEARER in its environment
#         HARNESS_STUB_PROFILES per codex invocation that layered a profile
#                               file, one `layered <path>` line
#       and reads HARNESS_STUB_CODEX_VERSION (0.133.0 or 0.154.0, default
#       0.133.0) at run time to choose which codex it acts as.
#
# ## The marker is the whole clock
#
# A stub agent works until <marker> exists and then finishes. One file drives
# every adapter's `working` -> `done` transition, so the test never sleeps for
# a fixed number of seconds hoping a state has changed. It also makes the loop
# measurable: with the marker already there each pass ends at once, so what a
# `--loop-minutes` spawn produces is one line in <runs> per pass.
#
# ## What each line of a stub stands for
#
# Every stub reproduces the ONE property of the real program that an adapter
# reads, and nothing else. Where that is not obvious the stub says so in a
# comment beside it, because a stub that is smaller than the behaviour under
# test passes the test by construction.
#
# ## bash 3.2
#
# The generated stubs use `[ ]`, one `shift` per loop pass and no arrays: they
# run under whatever bash the adapter's `nohup` wrapper woke up in, which on
# macOS is 3.2.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'foreman: %s is a library; source it from a test\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

# How often a working stub emits an event, in seconds. The adapters' liveness
# checks read the transcript's mtime, so an agent that is working has to keep
# moving it; a stub that wrote once and then slept would make a healthy agent
# read as wedged.
_HARNESS_STUB_EVENT_SECONDS=0.2

# The paths every stub is born knowing, written into it rather than read from
# the environment. detached.sh hands its generated wrapper to `nohup python3`,
# and a stub that looked its state up in $HARNESS_STUB_STATE would answer from
# whatever environment that wrapper happened to inherit.
_harness_stub_prelude() { # <state_dir>
  printf '%s\n' 'set -u'
  printf 'STUB_STATE=%q\n' "$1"
  printf 'STUB_MARKER=%q\n' "$1/marker"
  printf 'STUB_RUNS=%q\n' "$1/runs"
  # The whole argv of every invocation, which is what a test reads to claim
  # that a secret never became a command-line argument. Separate from
  # STUB_RUNS, which counts passes and must stay one line per run.
  printf 'STUB_ARGV=%q\n' "$1/argv"
  printf 'STUB_BEARER=%q\n' "$1/bearer"
  printf 'STUB_PROFILES=%q\n' "$1/profiles"
  printf 'STUB_EVENT_SECONDS=%q\n' "$_HARNESS_STUB_EVENT_SECONDS"
}

harness_stub_install() { # <bin_dir> <state_dir>
  if [[ $# -ne 2 ]]; then
    printf 'foreman: harness_stub_install needs <bin_dir> <state_dir>\n' >&2
    return 1
  fi
  local bin="$1" state="$2"
  mkdir -p "$bin" "$state" || return 1
  # Absolute, resolved once. A stub started by detached.sh's wrapper wakes up
  # in the agent's cwd, and a relative state directory would leave it writing
  # its rows somewhere no later read looks.
  bin="$(cd "$bin" && pwd)" || return 1
  state="$(cd "$state" && pwd)" || return 1

  HARNESS_STUB_MARKER="$state/marker"
  HARNESS_STUB_RUNS="$state/runs"
  HARNESS_STUB_ARGV="$state/argv"
  HARNESS_STUB_BEARER="$state/bearer"
  HARNESS_STUB_PROFILES="$state/profiles"
  : >"$HARNESS_STUB_RUNS" || return 1
  : >"$HARNESS_STUB_ARGV" || return 1
  : >"$HARNESS_STUB_BEARER" || return 1
  : >"$HARNESS_STUB_PROFILES" || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Stub `claude`, for the four things claude.sh runs: --bg, agents, stop'
    printf '%s\n' '# and --version.'
    _harness_stub_prelude "$state"
    cat <<'CLAUDE_STUB'

STUB_ROWS="$STUB_STATE/rows"
STUB_STOPPED="$STUB_STATE/stopped"

printf '%s\n' "$*" >>"$STUB_ARGV"

# Claude persists a session at ~/.claude/projects/<slug>/<id>.jsonl, the slug
# being the cwd with every '/' and '.' turned into '-'. claude.sh's
# `transcript` verb composes exactly this path, so the stub has to write the
# file that path names -- not one of its own choosing.
transcript_path() { # <cwd> <session>
  printf '%s/.claude/projects/%s/%s.jsonl' \
    "$HOME" "$(printf '%s' "$1" | tr './' '--')" "$2"
}

# The real agent appends to its session file for as long as it is working.
# That is what the mtime the adapters read is evidence of, so the stub appends
# too, in the background, until the marker says the work is over.
start_transcript() { # <cwd> <session>
  local path
  path="$(transcript_path "$1" "$2")"
  mkdir -p "$(dirname "$path")"
  : >"$path"
  ( while [ ! -f "$STUB_MARKER" ]; do
      printf '{"type":"assistant"}\n' >>"$path"
      sleep "$STUB_EVENT_SECONDS"
    done ) >/dev/null 2>&1 &
}

# Row numbers double as ids, session ids and startedAt, so no two spawns ever
# share one. A stub that reused a session id would make "resume continued the
# same session" true whatever the adapter did.
next_index() {
  local n=0
  if [ -f "$STUB_ROWS" ]; then n="$(wc -l <"$STUB_ROWS" | tr -d ' ')"; fi
  printf '%s\n' "$(( n + 1 ))"
}

field_by_session() { # <session> <column>
  awk -F'\t' -v want="$1" -v col="$2" '$2 == want { print $col }' "$STUB_ROWS" | tail -1
}

background() {
  local name="" resume_from="" index session
  while [ $# -gt 0 ]; do
    # One shift per pass, reading $2 without consuming it: a `--name` with no
    # value then reads as empty rather than tripping `set -u`.
    case "$1" in
      --name) name="${2:-}" ;;
      --resume) resume_from="${2:-}" ;;
    esac
    shift
  done

  # `--bg --resume` FORKS: a new session id inheriting the old session's name.
  # Reproduced because claude.sh's resume prints the id it resumed FROM, and a
  # stub that kept one id per name could not tell that apart from a resume
  # that printed the fork's id by mistake.
  if [ -n "$resume_from" ]; then name="$(field_by_session "$resume_from" 3)"; fi

  index="$(next_index)"
  session="session-$index"
  # startedAt is epoch MILLIseconds in the real registry, and every consumer
  # sorts by it, so it only has to rise with each spawn.
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "agent-$index" "$session" "$name" "$PWD" "$(( 1700000000000 + index ))" >>"$STUB_ROWS"
  start_transcript "$PWD" "$session"
  printf 'stub agent %s started\n' "$session"
}

agents() {
  python3 -c '
import json, os, sys

rows_path, stopped_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]
stopped = set()
if os.path.exists(stopped_path):
    with open(stopped_path) as handle:
        stopped = {line.strip() for line in handle if line.strip()}
finished = os.path.exists(marker)

agents = []
if os.path.exists(rows_path):
    with open(rows_path) as handle:
        for line in handle:
            if not line.strip():
                continue
            agent_id, session, name, cwd, started = line.rstrip("\n").split("\t")
            if agent_id in stopped:
                state = "stopped"
            else:
                state = "done" if finished else "working"
            agents.append({
                "name": name,
                "id": agent_id,
                "sessionId": session,
                "pid": int(started) % 100000,
                "state": state,
                "startedAt": int(started),
                "cwd": cwd,
                "status": "running",
            })
print(json.dumps(agents))
' "$STUB_ROWS" "$STUB_STOPPED" "$STUB_MARKER"
}

case "${1:-}" in
  --bg)
    printf 'claude\n' >>"$STUB_RUNS"
    background "$@"
    ;;
  agents) agents ;;
  # The registry keys a stop by the AGENT id, not the session id. Recorded so
  # the next `agents` answers stopped for that row and no other.
  stop) printf '%s\n' "${2:-}" >>"$STUB_STOPPED" ;;
  --version) printf 'claude-stub 0.0.0\n' ;;
  *) exit 0 ;;
esac
CLAUDE_STUB
  } >"$bin/claude" || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Stub `codex`, for `codex exec`, `codex exec resume` and --version.'
    _harness_stub_prelude "$state"
    cat <<'CODEX_STUB'

# `codex exec --json` prints one JSON object per line and returns when the turn
# ends; there is no background mode and no registry. detached.sh supplies both,
# so what this stub owes the adapter is the event stream and an exit.
#
# It acts as one of two measured versions, chosen by HARNESS_STUB_CODEX_VERSION
# (default 0.133.0). Read from the environment on purpose, unlike the paths
# above: the adapter reads `codex exec --help` in its own process and runs
# `codex exec` from detached.sh's wrapper, which inherits the adapter's
# environment, so both invocations see the same version.
STUB_VERSION="${HARNESS_STUB_CODEX_VERSION:-0.133.0}"
case "$STUB_VERSION" in
  # 0.133.0: `--profile-v2` layers the profile file; `--profile` is the old
  # [profiles.<name>] table in config.toml.
  0.133.0) LAYER_FLAG=--profile-v2 ;;
  # 0.154.0: `--profile-v2` is gone; `-p/--profile` layers the profile file.
  0.154.0) LAYER_FLAG=--profile ;;
  *) printf 'codex-stub: no such stub version %s\n' "$STUB_VERSION" >&2; exit 2 ;;
esac

printf '%s\n' "$*" >>"$STUB_ARGV"
case "${1:-}" in
  --version) printf 'codex-cli %s\n' "$STUB_VERSION"; exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac

# The two help entries the adapter reads to pick its flag, worded as each
# version words them.
if [ "${2:-}" = --help ]; then
  if [ "$STUB_VERSION" = 0.133.0 ]; then
    printf '%s\n' \
      '  -p, --profile <CONFIG_PROFILE>' \
      '          Configuration profile from config.toml to specify default options' \
      '' \
      '      --profile-v2 <CONFIG_PROFILE_V2>' \
      '          Layer $CODEX_HOME/<name>.config.toml on top of the base user config'
  else
    printf '%s\n' \
      '  -p, --profile <CONFIG_PROFILE_V2>' \
      '          Layer $CODEX_HOME/<name>.config.toml on top of the base user config'
  fi
  exit 0
fi

printf 'codex\n' >>"$STUB_RUNS"

# `thread.started` is the only event carrying a session id, and codex.sh polls
# the log for exactly it. `codex exec resume <id>` continues that thread, so it
# names the id it was handed rather than minting another.
THREAD="thread-$$"

# `--profile-v2 <name>` layers $CODEX_HOME/<name>.config.toml, which is where
# codex.sh puts the MCP servers so that no credential ever becomes an argv
# element. Real codex IGNORES a profile file that is not there -- silently, no
# warning, every MCP server simply absent -- so an adapter that passed the flag
# without writing the file would look healthy and reach Linear never. This stub
# is deliberately STRICTER than the real binary on exactly that point.
#
# `codex exec resume` REFUSES `--profile-v2` after the word `resume` ("error:
# unexpected argument '--profile-v2' found", codex-cli 0.133.0, 2026-09-14),
# and accepts it before. The stub refuses the same way, so an adapter that put
# the flag in the wrong place fails here instead of on the operator's machine.
#
# A flag this version does not layer a profile with is refused too: 0.154.0
# has no `--profile-v2`, and 0.133.0's `--profile` reads a config.toml table
# that holds no MCP servers. Either would leave every MCP server absent.
PROFILE=""
RESUMING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile-v2|--profile|-p)
      FLAG="$1"
      [ "$FLAG" = -p ] && FLAG=--profile
      if [ "$FLAG" != "$LAYER_FLAG" ]; then
        printf 'codex-stub %s: %s does not layer $CODEX_HOME/<name>.config.toml on this version\n' \
          "$STUB_VERSION" "$1" >&2
        exit 2
      fi
      if [ -n "$RESUMING" ]; then
        printf "codex-stub: error: unexpected argument '%s' found\n" "$1" >&2
        exit 2
      fi
      PROFILE="${2:-}" ;;
    resume) RESUMING=1; THREAD="${2:-$THREAD}" ;;
    # The prompt follows `--`, and a prompt holding the word resume is not the
    # subcommand.
    --) break ;;
  esac
  shift
done
if [ -n "$PROFILE" ]; then
  PROFILE_FILE="${CODEX_HOME:-$HOME/.codex}/$PROFILE.config.toml"
  if [ ! -r "$PROFILE_FILE" ]; then
    printf 'codex-stub: %s %s names %s, which is not there\n' \
      "$LAYER_FLAG" "$PROFILE" "$PROFILE_FILE" >&2
    exit 1
  fi
  # What the test reads to claim the MCP profile reached codex.
  printf 'layered %s\n' "$PROFILE_FILE" >>"$STUB_PROFILES"
fi

# Real codex reads stdin to EOF before its first event when stdin is open
# ("Reading additional input from stdin..."), and on 0.154.0 waited 180
# seconds with no event. The stub blocks the same way, so a harness command
# run with an open stdin never reaches thread.started here either.
printf 'Reading additional input from stdin...\n' >&2
cat >/dev/null

# A remote server's bearer token reaches codex as the environment variable its
# profile names in `bearer_token_env_var`, and in no other way. Recorded as
# `<VARIABLE> <cksum of the value>`, never the value: this state directory is
# what the test greps to prove the token is written down nowhere. Recorded
# before thread.started, so a spawn that has returned has already recorded it.
for variable in $(compgen -e); do
  case "$variable" in
    FOREMAN_MCP_*_BEARER)
      eval "value=\${$variable}"
      printf '%s %s\n' "$variable" "$(printf '%s' "$value" | cksum)" >>"$STUB_BEARER"
      ;;
  esac
done

printf '{"type":"thread.started","thread_id":"%s"}\n' "$THREAD"

# The turn keeps streaming until the work is over. stdout is the log, and the
# log is what `transcript` names, so this is the mtime an adapter's caller
# reads as "still alive".
while [ ! -f "$STUB_MARKER" ]; do
  printf '{"type":"item.completed"}\n'
  sleep "$STUB_EVENT_SECONDS"
done
exit 0
CODEX_STUB
  } >"$bin/codex" || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Stub `opencode`, for `opencode run` and --version.'
    _harness_stub_prelude "$state"
    cat <<'OPENCODE_STUB'

printf '%s\n' "$*" >>"$STUB_ARGV"
case "${1:-}" in
  --version) printf '0.0.0-stub\n'; exit 0 ;;
  run) ;;
  *) exit 0 ;;
esac

printf 'opencode\n' >>"$STUB_RUNS"

# Every event `opencode run --format json` prints carries a top-level
# sessionID, and `-s/--session <id>` continues an existing one. opencode.sh
# takes the first sessionID it sees, so the stub names the resumed session on
# its first line too.
SESSION="session-$$"
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--session) SESSION="${2:-$SESSION}" ;;
  esac
  shift
done
printf '{"type":"step_start","sessionID":"%s"}\n' "$SESSION"

while [ ! -f "$STUB_MARKER" ]; do
  printf '{"type":"text","sessionID":"%s"}\n' "$SESSION"
  sleep "$STUB_EVENT_SECONDS"
done
printf '{"type":"step_finish","sessionID":"%s"}\n' "$SESSION"
exit 0
OPENCODE_STUB
  } >"$bin/opencode" || return 1

  chmod +x "$bin/claude" "$bin/codex" "$bin/opencode" || return 1
}
