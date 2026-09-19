#!/usr/bin/env bash
# The OpenCode harness, behind foreman's adapter verbs.
#
# usage:
#   opencode.sh spawn  --name N --cwd D --model M --prompt-file F
#                      --skip-permissions
#                      [--add-dir D]... [--mcp-config F]... [--loop-minutes K]
#                      [--remote-control]   accepted; nothing to register
#                                             prints the session id
#   opencode.sh resume --name N --cwd D --prompt-file F --skip-permissions
#                      [--mcp-config F]...    prints the session id
#   opencode.sh list                          every agent, as a JSON list
#   opencode.sh stop <id>                     stop one agent
#   opencode.sh reap <older-than-seconds>     delete what finished agents left
#   opencode.sh transcript <cwd> <session-id> prints the transcript path
#   opencode.sh check                         exit 0 if the binary runs
#   opencode.sh skills-dir                    where this harness resolves skills
#   opencode.sh skill-prompt <name> [--loop-minutes K]
#                                             the text that invokes a skill
#
# `config.sh` picks this file when an installation's `harness = "opencode"`,
# and exports it as `HARNESS_SH`. Every script that used to run `claude`
# directly runs "$HARNESS_SH" instead.
#
# THIS FILE SOURCES detached.sh (node h2) for everything `opencode run` cannot
# give foreman on its own: a process that outlives the caller, an agent
# registry, `list`, `stop`, the tick's loop, the flag parsing and the verb
# table. What stays here is only opencode's own command line, its MCP
# translation and its own session-id parsing — see detached.sh's header for the
# split.
#
# ## The CLI, as measured on this machine, 2026-09-14
#
#   $ opencode --version
#   1.18.30
#
#   $ opencode run --help
#   opencode run [message..]
#     -m, --model     model to use, provider/model
#     -s, --session   session id to continue
#         --format    default | json
#         --dir       directory to run in
#         --title     title for the session (truncated prompt if omitted)
#         --auto      auto-approve permissions that are not explicitly denied
#
# No `--cwd`: the flag is spelled `--dir`. No `--yes` or `--dangerously-*`:
# auto-approval is `--auto`. There is no flag for MCP config; that is an
# environment variable, below.
#
# ## The session id, parsed from `--format json`
#
# Ran `opencode run --format json 'say hi'` against an authenticated CLI on
# this machine. Every line of the event stream is one JSON object, and EVERY
# event — `step_start`, `text`, `step_finish`, and everything else the run
# prints — carries a top-level `"sessionID"` key, not only the first line or
# one event type. So the parser below reads line by line and takes the first
# `sessionID` it finds; it does not assume which event carries it. That is what
# "parse defensively" means here: a future opencode that adds an event type
# before the ones seen still has a sessionID on it, because every type this run
# produced did.
#
# `--title N` was confirmed against `opencode session list`: the session it
# started carried the exact title, not a truncated prompt. `spawn` below
# passes it the agent name so `opencode session list` reads the same name
# every other foreman listing does.
#
# `-s/--session <id>` resume was confirmed the same way: a second `opencode
# run --session <id>` against a fresh session continued it — the reply
# referenced the first turn — and `opencode session list` still showed one
# row. `resume` below relies on that: it never re-passes `--title`, `--model`
# or MCP config, matching the five-verb contract, which gives `resume` none of
# those to pass.
#
# ## MCP config: OPENCODE_CONFIG, not ~/.config/opencode/opencode.json
#
# `opencode run` has no `--mcp-config` flag. `strings` on the compiled binary
# turned up its own help text for the mechanism:
#
#   OPENCODE_CONFIG=/path/to/file.json: load an additional explicit config.
#
# and the config schema at https://opencode.ai/config.json confirms the shape
# an MCP entry takes there: `{"mcp": {"<name>": {"type": "local", "command":
# [...], "environment": {...}}}}` for a command server, or `{"type": "remote",
# "url": ..., "headers": {...}}` for one reached over HTTP.
#
# We do not write ~/.config/opencode/opencode.json. That file is the
# operator's — shared by the opencode TUI, every other project they open, and
# any plugin they installed by hand — and a foreman agent that edited it would
# hand its Linear MCP server to whatever else opencode is doing that day, or
# lose the operator's own config on the first crash mid-write. `OPENCODE_CONFIG`
# points at a file of foreman's own instead, read fresh for exactly this run.
#
# ## Where that file goes: $FOREMAN_HOME/mcp/opencode.json, at 0600
#
# It used to be `$FOREMAN_HOME/agents/mcp-<name>-<pid>-<ms>.json`, world
# readable at 0644, with the Linear credential inside and nothing to delete it.
# Two failures, both measured 2026-09-14:
#
#   - detached.sh's `list` globs `agents/*.json`, so every one of those files
#     came back as an agent row: `{"name": "", "id": "mcp-...", "state":
#     "stopped"}`. One phantom agent per spawn, forever, in the listing
#     reconcile.py and sweep.sh read.
#   - The credential sat at 0644 in a directory that never gets swept.
#
# So: outside agents/, in a directory of its own at 0700, one deterministic
# name that each spawn overwrites, and the file itself at 0600.
#
# ## bash 3.2
#
# No `mapfile`, no `declare -A`, and under `set -u` an empty array expands as
# ${arr[@]+"${arr[@]}"}. python3 does the JSON, matching detached.sh.
set -euo pipefail

_OPENCODE_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./detached.sh
source "$_OPENCODE_SH_DIR/detached.sh"
detached_adapter opencode "${BASH_SOURCE[0]}"

# Translate a Claude-format mcp.json (`{"mcpServers": {...}}`) into the
# OpenCode config shape and write it to <dest>. Reads one or more source
# files so a future caller that passes several --mcp-config flags, the way
# claude.sh's spawn does, still gets one merged file; today's callers pass
# exactly one, `$FOREMAN_HOME/mcp.json`.
#
# Refuses rather than guesses: a server entry with neither `command` nor
# `url` has no known translation, and passing it through as `{}` would start
# opencode with a silently broken MCP server foreman then reports as "the
# board went quiet" instead of "this config is bad".
_opencode_write_mcp_config() { # <dest> <source-mcp-json>...
  python3 -c '
import json, os, sys

dest = sys.argv[1]
sources = sys.argv[2:]
servers = {}

for path in sources:
    with open(path) as handle:
        try:
            doc = json.load(handle)
        except ValueError as exc:
            sys.exit("foreman: %s is not readable JSON (%s)" % (path, exc))
    claude_servers = doc.get("mcpServers") if isinstance(doc, dict) else None
    if not isinstance(claude_servers, dict):
        sys.exit("foreman: %s has no mcpServers object; expected Claude mcp.json shape" % path)

    for name, entry in claude_servers.items():
        if name in servers:
            sys.exit("foreman: mcp server %r is defined in more than one --mcp-config file" % name)
        if not isinstance(entry, dict):
            sys.exit("foreman: mcp server %r in %s is a %s, expected an object" % (name, path, type(entry).__name__))

        if "command" in entry:
            command = entry.get("command")
            if not isinstance(command, str) or not command:
                sys.exit("foreman: mcp server %r in %s has no command string" % (name, path))
            args = entry.get("args", [])
            if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
                sys.exit("foreman: mcp server %r in %s has an args field that is not a list of strings" % (name, path))
            env = entry.get("env", {})
            if not isinstance(env, dict) or not all(isinstance(v, str) for v in env.values()):
                sys.exit("foreman: mcp server %r in %s has an env field that is not a string-valued object" % (name, path))
            translated = {"type": "local", "command": [command] + args}
            if env:
                translated["environment"] = env
        elif "url" in entry:
            url = entry.get("url")
            if not isinstance(url, str) or not url:
                sys.exit("foreman: mcp server %r in %s has no url string" % (name, path))
            headers = entry.get("headers", {})
            if not isinstance(headers, dict) or not all(isinstance(v, str) for v in headers.values()):
                sys.exit("foreman: mcp server %r in %s has a headers field that is not a string-valued object" % (name, path))
            translated = {"type": "remote", "url": url}
            if headers:
                translated["headers"] = headers
        else:
            sys.exit("foreman: mcp server %r in %s has neither command nor url; cannot translate it" % (name, path))

        servers[name] = translated

config = {"$schema": "https://opencode.ai/config.json", "mcp": servers}

# 0600 BEFORE any content lands, which is why this is os.open with an explicit
# mode and not open(): a server env here holds the Linear credential, and a
# file that is world-readable for the microsecond between creation and a chmod
# is a file that was world-readable. A leftover temp file is removed first,
# because O_TRUNC on an existing file keeps the mode that file already had.
os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
tmp = "%s.tmp.%d" % (dest, os.getpid())
if os.path.exists(tmp):
    os.unlink(tmp)
handle = os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w")
with handle:
    json.dump(config, handle)
    handle.write("\n")
os.replace(tmp, dest)
' "$@"
}

# How long spawn waits for opencode to name its session, in whole seconds.
#
# `opencode run --format json` prints NOTHING until the model's first step
# produces output, although the session exists within about two seconds
# (OpenCode's own log: `message=created id=ses_...`). Measured 2026-09-14 on
# opencode 1.18.30:
#
#   - The wait was 15 seconds. The first foreman/opencode/tick, whose prompt
#     loads the board skill and an MCP server before answering, was killed at
#     15 seconds with an empty log. With a one-word prompt and nothing to load,
#     the two working models took 6.4 and 7.0 seconds to their first event.
#   - opencode-go/deepseek-v4.1-flash never answered at all: no event and no
#     error for 120 seconds. A longer wait does not rescue that model, which
#     is why the timeout message names it and the command that checks it.
#
# FOREMAN_OPENCODE_SESSION_WAIT_SECONDS overrides it. It exists for the tests,
# which cannot sit out two minutes per claim, and for an operator on a model
# slower than this.
_OPENCODE_SESSION_WAIT_DEFAULT_SECONDS=120
_OPENCODE_SESSION_POLL_SECONDS=0.5

# What _opencode_wait_for_session returns besides 0, so spawn can tell a model
# that never answered from a process that is gone.
_OPENCODE_WAIT_TIMED_OUT=1
_OPENCODE_WAIT_EXITED=2
_OPENCODE_WAIT_UNKNOWABLE=3

# How many trailing log lines an error quotes.
_OPENCODE_LOG_TAIL_LINES=5

# The wait in whole seconds, refusing an override that is not one. A typo such
# as `2m` must not quietly become the default, or a wait of zero.
_opencode_session_wait_seconds() {
  local wait="${FOREMAN_OPENCODE_SESSION_WAIT_SECONDS:-$_OPENCODE_SESSION_WAIT_DEFAULT_SECONDS}"
  if [[ ! "$wait" =~ ^[1-9][0-9]*$ ]]; then
    printf 'foreman: FOREMAN_OPENCODE_SESSION_WAIT_SECONDS is %s; expected a positive whole number of seconds\n' "$wait" >&2
    return 1
  fi
  printf '%s\n' "$wait"
}

# Poll <log> until opencode names its session, the process dies, or <wait>
# seconds pass. Prints the session id on success; otherwise returns one of the
# _OPENCODE_WAIT_* codes above.
#
# Polls, because the log is being written by a process we just started:
# `detached_spawn` returns as soon as the wrapper is recorded, not once
# opencode has spoken.
#
# The deadline reads bash's SECONDS, not a count of polls: every poll also runs
# python, so a count of polls waits longer than the number it claims.
_opencode_wait_for_session() { # <home> <id> <log> <wait-seconds>
  local home="$1" id="$2" log="$3" wait="$4" session running
  local deadline=$(( SECONDS + wait ))
  while :; do
    session="$(_opencode_session_in_log "$log")"
    [[ -n "$session" ]] && { printf '%s\n' "$session"; return 0; }

    running=0
    detached_is_running "$home" "$id" || running=$?
    if [[ "$running" -eq 1 ]]; then
      # Read once more. The last event can land between the read above and the
      # exit: the stub, and a fast real run, print a session and finish at once.
      session="$(_opencode_session_in_log "$log")"
      [[ -n "$session" ]] && { printf '%s\n' "$session"; return 0; }
      return "$_OPENCODE_WAIT_EXITED"
    fi
    [[ "$running" -eq 0 ]] || return "$_OPENCODE_WAIT_UNKNOWABLE"

    [[ "$SECONDS" -lt "$deadline" ]] || return "$_OPENCODE_WAIT_TIMED_OUT"
    sleep "$_OPENCODE_SESSION_POLL_SECONDS"
  done
}

# The last lines of <log> for an error message, with secrets masked, or a
# sentence saying the log is empty. The log holds whatever opencode printed on
# both streams, and a provider error can echo the key it was handed; this
# message goes to dispatch.sh's output and from there into card comments.
_opencode_log_tail() { # <log>
  python3 -c '
import re, sys

path, count = sys.argv[1], int(sys.argv[2])
try:
    with open(path, errors="replace") as handle:
        lines = [line.rstrip("\n") for line in handle if line.strip()]
except FileNotFoundError:
    lines = []
if not lines:
    print("the log %s is empty" % path)
    sys.exit(0)

QUOTE = "[\"\x27]?"
MASKS = (
    (re.compile(r"sk-[A-Za-z0-9_-]+"), "sk-***"),
    (re.compile(r"Bearer\s+\S+", re.IGNORECASE), "Bearer ***"),
    (re.compile(r"((?:api[_-]?key|token|secret|password)" + QUOTE + r"\s*[:=]\s*" + QUOTE + r")[^\s\"\x27,}]+", re.IGNORECASE), r"\1***"),
    # A long unbroken run of key characters is what a token looks like.
    (re.compile(r"[A-Za-z0-9_-]{32,}"), "***"),
)
print("last lines of %s:" % path)
for line in lines[-count:]:
    for pattern, replacement in MASKS:
        line = pattern.sub(replacement, line)
    print("  " + line)
' "$1" "$_OPENCODE_LOG_TAIL_LINES"
}

# The first `sessionID` any event in <log> carries, or nothing. See this file's
# header for why "first field on the first line" is not assumed — every event
# type this CLI printed during testing carried it, so this reads every line.
_opencode_session_in_log() { # <log>
  [[ -s "$1" ]] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get("sessionID"):
                print(event["sessionID"])
                break
except FileNotFoundError:
    pass
' "$1"
}

spawn() {
  detached_parse_spawn "$@"

  local home id log session wait waited=0
  home="$(detached_home)" || exit 1
  # Read before anything starts, so a bad override refuses with nothing to stop.
  wait="$(_opencode_session_wait_seconds)" || exit 1

  local args=(opencode run --dir "$DETACHED_CWD" -m "$DETACHED_MODEL" --format json --title "$DETACHED_NAME")
  # Always auto-approved: detached_parse_spawn refuses a spawn without
  # --skip-permissions, because an `opencode run` with no TTY and no --auto
  # waits on an approval nobody will type.
  args+=(--auto)

  # Wired up before detached_spawn starts the process: OPENCODE_CONFIG has to
  # be set in the wrapper's own environment, and `env -- "$@"` is the one way
  # to hand detached_spawn's generated wrapper an environment variable
  # alongside its command, since the wrapper execs "$@" literally.
  #
  # The PATH to the config is an argv element; the credential inside it is not.
  if [[ ${#DETACHED_MCP_CONFIGS[@]} -gt 0 ]]; then
    local mcp_dest="$home/mcp/opencode.json"
    _opencode_write_mcp_config "$mcp_dest" "${DETACHED_MCP_CONFIGS[@]}"
    args=(env "OPENCODE_CONFIG=$mcp_dest" "${args[@]}")
  fi

  args+=("$DETACHED_PROMPT")

  id="$(detached_spawn "$DETACHED_NAME" "$DETACHED_CWD" "$home" "$DETACHED_LOOP_MINUTES" -- "${args[@]}")" || exit 1
  log="$(detached_transcript "$home" "$id")" || exit 1

  session="$(_opencode_wait_for_session "$home" "$id" "$log" "$wait")" || waited=$?

  if [[ "$waited" -eq "$_OPENCODE_WAIT_EXITED" ]]; then
    # Nothing to stop: the process is gone, and its record keeps the exit code.
    die "spawned $DETACHED_NAME (foreman id $id) but OpenCode exited before naming a session; $(_opencode_log_tail "$log")"
  fi
  if [[ "$waited" -ne 0 ]]; then
    # STOP IT BEFORE DYING. The process is running opencode in the worktree
    # right now; giving up without stopping it leaves a live harness there
    # while dispatch.sh moves on to attempt 2 and `git worktree remove -f -f`s
    # the same directory out from under it.
    detached_stop "$home" "$id" || true
  fi
  if [[ "$waited" -eq "$_OPENCODE_WAIT_UNKNOWABLE" ]]; then
    die "spawned $DETACHED_NAME (foreman id $id) but could not tell whether it was still running, so stopped it"
  fi
  if [[ "$waited" -ne 0 ]]; then
    # Worded for the operator. Measured 2026-09-14: the old message named
    # neither the model nor the live process, so a model that never answers
    # read as a broken adapter. The command it names settles which one it is.
    die "spawned $DETACHED_NAME (foreman id $id): no output from opencode model $DETACHED_MODEL within ${wait}s (the process was alive and waiting); check the model with: opencode run -m $DETACHED_MODEL --format json \"Reply with ok\""
  fi
  detached_note_session "$home" "$id" "$session" || exit 1
  printf '%s\n' "$session"
}

resume() {
  detached_parse_resume "$@"

  local home session id
  home="$(detached_home)" || exit 1
  session="$(detached_newest "$home" name "$DETACHED_NAME" sessionId)" || exit 1
  [[ -n "$session" ]] || die "no agent named $DETACHED_NAME to resume"

  local args=(opencode run --dir "$DETACHED_CWD" --session "$session" --format json --auto)
  # The same config spawn writes, for the same reason: a resumed agent talks to
  # the same MCP servers. Accepted and dropped would be a resume that silently
  # loses every tool it had.
  if [[ ${#DETACHED_MCP_CONFIGS[@]} -gt 0 ]]; then
    local mcp_dest="$home/mcp/opencode.json"
    _opencode_write_mcp_config "$mcp_dest" "${DETACHED_MCP_CONFIGS[@]}"
    args=(env "OPENCODE_CONFIG=$mcp_dest" "${args[@]}")
  fi
  args+=("$DETACHED_PROMPT")

  id="$(detached_spawn "$DETACHED_NAME" "$DETACHED_CWD" "$home" "" -- "${args[@]}")" || exit 1
  detached_note_session "$home" "$id" "$session" || exit 1
  printf '%s\n' "$session"
}

check() { opencode --version; }

skills_dir() {
  # The override is what lets a test point an install at a temporary
  # directory instead of the operator's real one, the way claude.sh's
  # CLAUDE_SKILLS_DIR does.
  printf '%s\n' "${OPENCODE_SKILLS_DIR:-$HOME/.config/opencode/skill}"
}

skill_prompt_text() { # <name>
  # OpenCode's native `skill` tool, confirmed against its own docs (INSTALL.md
  # for the superpowers plugin, which targets this same tool): "use skill tool
  # to load <name>" is the prescribed phrasing, and skills-dir above is where
  # it looks.
  #
  # THE SECOND CLAUSE IS LOAD-BEARING. On 2026-09-19 every tick session, on
  # several models, loaded the skill and then stopped with "Loaded the `board`
  # skill." -- the skill tool RETURNS the skill's text and the run ends there,
  # so a prompt that asks only to load produces no board pass at all and the
  # board silently stops moving. Measured on the same host and model: the
  # minimal prompt gave 1 tool call per session, this one gave 26. Ask for the
  # pass in the same breath as the load.
  printf 'use skill tool to load %s, then carry out one full pass exactly as the skill instructs\n' "$1"
}

detached_main "$@"
