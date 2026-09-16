#!/usr/bin/env bash
# The detached half of the Codex and OpenCode harness adapters.
#
# Neither CLI has a background mode or an agent registry: `codex exec` and
# `opencode run` run in the foreground and return when the turn ends. This file
# supplies what Claude's `--bg` gives foreman for free — a process that outlives
# the caller, a record of it, a listing, a stop, and the tick's loop — so that
# codex.sh and opencode.sh carry only their own command line and their own
# session-id parsing.
#
# SOURCE IT, DO NOT RUN IT. It defines functions and nothing else.
#
# ## The process interface an adapter uses
#
#   detached_spawn <name> <cwd> <home> <loop-minutes|""> -- <command...>
#       Starts <command...> detached, records it, prints foreman's id for it.
#       A non-empty loop-minutes makes the detached process a loop: run the
#       command, wait that many minutes, run it again, until it is stopped.
#       Fractional minutes are allowed, which is what lets a test loop in
#       seconds.
#   detached_note_session <home> <id> <sessionId>
#       Fills in the harness's own session id, once the adapter has parsed it.
#   detached_list <home>          the spec's JSON list, one row per record
#   detached_reap <home> <older-than-seconds>
#       Deletes the record, the log and the wrapper of every agent that is
#       finished and older than the window, and prints one line per id. Nothing
#       else reaps them: every spawn leaves three files under <home>/agents
#       forever, and detached_list globs and parses all of them on every
#       dispatch gate, every sweep, every watch-agents poll and every supervise
#       fire, so the cost of a liveness check rose with the installation's
#       lifetime. sweep.sh calls it through the adapter's `reap` verb.
#   detached_stop <home> <id>     TERM then KILL, to the whole process group
#   detached_transcript <home> <id>   prints the log path
#   detached_newest <home> <match-field> <match-value> <out-field>
#       One field of the newest row whose <match-field> equals <match-value>.
#
# Every function names what failed on stderr and returns 1. The adapters run
# under `set -e`, so that is their exit 1.
#
# ## The command-line interface an adapter uses
#
#   detached_adapter <short-name> <adapter-file>   register, before anything else
#   detached_main <verb> [args...]                 the whole verb table
#   detached_parse_spawn  <args...>    fills DETACHED_NAME, DETACHED_CWD,
#   detached_parse_resume <args...>    DETACHED_MODEL, DETACHED_PROMPT_FILE,
#                                      DETACHED_PROMPT, DETACHED_LOOP_MINUTES
#                                      and DETACHED_MCP_CONFIGS
#   detached_home                      $FOREMAN_HOME, or a refusal
#   die <message>                      prefixed with the adapter's name, exit 1
#   usage                              the adapter's own header, exit 2
#
# These moved here from codex.sh and opencode.sh, which carried ~93 byte
# identical lines between them: both flag loops, both validation blocks, the
# `--max-budget-usd` refusal four times over, `usage`, the verb `case`, and the
# "newest startedAt wins" filter five times across three files. Two copies of a
# rule do not drift on the day they are written, and that delay is what makes
# the drift expensive: the adapter nobody watches is the one that keeps the old
# rule.
#
# ## What the adapter still owns
#
# Building <command...>, parsing the harness's own session id out of its JSON
# event stream, translating the shared mcp.json into that harness's own format,
# and its own strings. `spawn` here prints FOREMAN's id; the adapter's `spawn`
# verb must print the SESSION id, so an adapter tails the log until the harness
# names its session, calls detached_note_session, and prints that.
#
# detached_main calls five functions the adapter must define: `spawn`,
# `resume`, `check`, `skills_dir` and `skill_prompt_text <name>`.
#
# ## The record
#
# One JSON document per agent at <home>/agents/<id>.json, rewritten whole:
#
#   name        the agent name the caller asked for, e.g. foreman/<...>/build-1
#   cwd         where the command runs
#   pid         the detached process, which is also its process group id
#   startedBy   what `ps -o lstart= -p <pid>` printed for that pid at spawn
#   sessionId   the harness's own id; "" until detached_note_session fills it
#   startedAt   epoch MILLIseconds, the unit every consumer already sorts by
#   log         <home>/agents/<id>.log, both streams of the command
#   exit        absent until the command ends, then its exit code
#
# `startedBy` is what makes `pid` mean anything. A pid alone is a recycled
# number: after a reboot, an OOM kill or a pid wraparound, a record left at
# `working` aliases whatever process now holds it. Measured 2026-09-14 by
# hand-writing a record with `pid: 1` — `list` reported it `working`, which
# means the card is never re-dispatched, `sweep.sh` protects its worktree
# forever, the host ceiling keeps counting it, and `detached_stop` then sends
# TERM and KILL to an unrelated process group. A pid plus the start time the
# kernel gave THAT process identifies one process and no other.
#
# Beside it live <id>.log and <id>.sh, the generated wrapper. The id is the
# filename, so nothing stores it twice.
#
# ## bash 3.2
#
# macOS ships it: no `mapfile`, no `declare -A`, and under `set -u` an empty
# array expands as ${arr[@]+"${arr[@]}"}. python3 does the JSON, the epoch
# milliseconds and the process-group detach, because it is already a hard
# dependency of this repository and `setsid(1)` is not on macOS at all.

# Where this file lives, so the generated wrapper can source it back. Resolved
# at source time: the wrapper runs long after the caller has moved on, and a
# relative path would resolve against whatever cwd it woke up in.
_DETACHED_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Running this file does nothing and exits 0, which reads exactly like a verb
# that succeeded. Refuse instead: an adapter that ran it rather than sourcing it
# would report a spawn that never happened.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'foreman: %s is a library; source it from a harness adapter\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

# Which adapter sourced this file, and where that file lives. `die` prefixes
# its message with the name, and `usage` reads the usage block out of the file,
# so both stay the adapter's own voice while the code is shared.
_DETACHED_ADAPTER=""
_DETACHED_ADAPTER_FILE=""

detached_adapter() { # <short-name> <adapter-file>
  if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
    printf 'foreman: detached_adapter needs <short-name> <adapter-file>\n' >&2
    return 1
  fi
  _DETACHED_ADAPTER="$1"
  _DETACHED_ADAPTER_FILE="$2"
}

die() { printf 'harness/%s: %s\n' "${_DETACHED_ADAPTER:-?}" "$*" >&2; exit 1; }

# The usage block in the adapter's own header is the only copy. A second one in
# a here-doc drifts the day a verb is added, and the caller who just mistyped
# one is then shown the older of the two.
usage() {
  sed -n '/^# usage:$/,/^#$/{s/^# \{0,1\}//;p;}' "$_DETACHED_ADAPTER_FILE" >&2
  exit 2
}

# Every verb but check/skills-dir/skill-prompt needs $FOREMAN_HOME: it is where
# this file keeps agents/, and config.sh already exports it for every caller
# that sources it.
#
# REFUSES rather than defaulting to $HOME/.foreman. opencode.sh used to guess
# that default, and the guess turned `list` into `[]` with exit 0 on a home
# that was never set — "I could not tell" wearing "nothing is running"'s
# clothes, which is the answer that lets a second tick start beside a healthy
# one and lets a dispatch land on top of a live build.
detached_home() {
  [[ -n "${FOREMAN_HOME:-}" ]] \
    || die "FOREMAN_HOME is unset; this adapter keeps its agent records under \$FOREMAN_HOME/agents"
  printf '%s' "$FOREMAN_HOME"
}

# How long detached_stop waits for a TERM to be honoured before it sends KILL,
# and how often it looks. Five seconds is the harness's own shutdown budget:
# both CLIs flush their event stream on TERM, and killing during that flush
# loses the last lines of the log an operator reads to find out why.
_DETACHED_STOP_GRACE_POLLS=20
_DETACHED_STOP_POLL_SECONDS=0.25

# The shell's convention for "killed by signal N" is 128+N. Recording the same
# number the wrapper would have recorded, had it lived long enough to see its
# child die, keeps one meaning for `exit` whoever wrote it.
_DETACHED_EXIT_TERM=143
_DETACHED_EXIT_KILL=137

# Merge keys into a record, rewriting the whole document.
#
# `set` overwrites; `default` leaves a key that is already there alone. That
# distinction is what lets detached_stop claim an exit code without erasing the
# real one a wrapper wrote a microsecond earlier.
_detached_record_write() { # <file> set|default <key> <value>...
  python3 -c '
import json, os, sys

# The three fields foreman compares as numbers. Everything else is a string,
# and a string "0" exit code would make `state` read done as stopped.
NUMERIC = ("pid", "startedAt", "exit", "stoppedAt")

path, op = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
if len(pairs) % 2:
    sys.exit("foreman: %s: record update needs key/value pairs, got %d arguments" % (path, len(pairs)))

record = {}
if os.path.exists(path):
    with open(path) as handle:
        try:
            record = json.load(handle)
        except ValueError as exc:
            sys.exit("foreman: %s is not readable JSON (%s); refusing to overwrite it" % (path, exc))
    if not isinstance(record, dict):
        sys.exit("foreman: %s holds a %s, expected a JSON object" % (path, type(record).__name__))

for key, value in zip(pairs[::2], pairs[1::2]):
    if op == "default" and key in record:
        continue
    if key not in NUMERIC:
        record[key] = value
        continue
    try:
        record[key] = int(value)
    except ValueError:
        sys.exit("foreman: %s: %s=%r is not an integer" % (path, key, value))

# Written to one side and renamed, because the wrapper and a concurrent
# detached_stop both write this file. A half-written document makes
# detached_list refuse, and a listing that refuses is how a second tick gets
# started beside a healthy one.
tmp = "%s.tmp.%d" % (path, os.getpid())
with open(tmp, "w") as handle:
    json.dump(record, handle)
    handle.write("\n")
os.replace(tmp, path)
' "$@"
}

_detached_record_set() { # <file> <key> <value>...
  local file="$1"
  shift
  _detached_record_write "$file" set "$@"
}

_detached_record_default() { # <file> <key> <value>...
  local file="$1"
  shift
  _detached_record_write "$file" default "$@"
}

# What the kernel says about when THIS pid started. Prints nothing when the pid
# is gone or out of range, which both readers treat as "not the process we
# recorded".
#
# `ps -o lstart= -p <pid>` is the portable spelling: BSD ps on macOS and procps
# on Linux both print the ctime form, `Mon Sep 14 09:09:04 2026`, verified on
# this machine 2026-09-14 (macOS pads it with trailing spaces). The comparison
# is byte-for-byte against what this printed at spawn, so both readers strip
# the trailing NEWLINE and nothing else — the pad is then present in both
# strings or in neither. detached_list's python does the same, in the same
# words, because the comparison is worthless if the two normalisations differ.
_detached_start_time() { # <pid>
  ps -o lstart= -p "$1" 2>/dev/null || true
}

_detached_record_path() { # <home> <id>
  printf '%s/agents/%s.json' "$1" "$2"
}

# One field out of a record. Refuses a record that is missing or unreadable
# rather than printing nothing: an empty pid would make detached_stop signal
# the caller's own process group.
_detached_record_field() { # <home> <id> <key>
  local file
  file="$(_detached_record_path "$1" "$2")"
  python3 -c '
import json, sys

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        record = json.load(handle)
except FileNotFoundError:
    sys.exit("foreman: no agent record at %s" % path)
except ValueError as exc:
    sys.exit("foreman: %s is not readable JSON (%s)" % (path, exc))
if not isinstance(record, dict):
    sys.exit("foreman: %s holds a %s, expected a JSON object" % (path, type(record).__name__))
value = record.get(key)
print("" if value is None else value)
' "$file" "$3"
}

# Start <command...> detached and record it. Prints the id.
detached_spawn() { # <name> <cwd> <home> <loop-minutes|""> -- <command...>
  local name="${1:-}" cwd="${2:-}" home="${3:-}" loop_minutes="${4:-}"
  if [[ $# -lt 5 ]]; then
    printf 'foreman: detached_spawn needs <name> <cwd> <home> <loop-minutes> -- <command...>\n' >&2
    return 1
  fi
  shift 4
  if [[ "$1" != "--" ]]; then
    printf 'foreman: detached_spawn expected -- before the command, got %s\n' "$1" >&2
    return 1
  fi
  shift
  if [[ $# -eq 0 ]]; then
    printf 'foreman: detached_spawn was given no command to run\n' >&2
    return 1
  fi
  if [[ -z "$name" ]]; then
    printf 'foreman: detached_spawn needs an agent name; the name is how every caller finds the agent again\n' >&2
    return 1
  fi
  if [[ ! -d "$cwd" ]]; then
    printf 'foreman: detached_spawn cwd %s is not a directory\n' "$cwd" >&2
    return 1
  fi
  if [[ -z "$home" ]]; then
    printf 'foreman: detached_spawn needs the installation home that holds agents/\n' >&2
    return 1
  fi

  local loop_seconds=""
  if [[ -n "$loop_minutes" ]]; then
    loop_seconds="$(python3 -c '
import sys

raw = sys.argv[1]
try:
    minutes = float(raw)
except ValueError:
    sys.exit("foreman: loop-minutes %r is not a number" % raw)
if minutes <= 0:
    sys.exit("foreman: loop-minutes %r must be positive; a zero wait is a hot loop" % raw)
print("%.3f" % (minutes * 60))
' "$loop_minutes")" || return 1
  fi

  local agents_dir
  mkdir -p "$home/agents" || return 1
  # Resolved to an absolute path here, once. The detached process is handed
  # these paths and wakes up wherever it likes; a relative home would leave it
  # writing its record somewhere no later `detached_list <home>` looks.
  agents_dir="$(cd "$home/agents" && pwd)" || return 1

  local started
  started="$(python3 -c 'import time; print(int(time.time() * 1000))')" || return 1

  # The id has to be unique per spawn and safe as a filename, and it is the
  # only thing an operator sees in a listing, so it stays readable.
  #
  # Four parts, each earning its place: the agent name's last segment says
  # which card and attempt this is; the start in milliseconds separates two
  # spawns of the same name; the caller's pid separates two shells that spawn
  # within one millisecond; and the counter separates two spawns by one shell
  # inside one millisecond, which no amount of "that cannot happen" makes
  # impossible. A collision would have one agent overwrite another's record.
  local safe id record log wrapper
  safe="$(basename "$name")"
  safe="${safe//[!A-Za-z0-9._-]/_}"
  if [[ -z "$safe" ]]; then
    printf 'foreman: agent name %s has no characters that can be used in a filename\n' "$name" >&2
    return 1
  fi
  _DETACHED_SPAWN_COUNT=$(( ${_DETACHED_SPAWN_COUNT:-0} + 1 ))
  id="$safe-$started-$$-$_DETACHED_SPAWN_COUNT"
  record="$agents_dir/$id.json"
  log="$agents_dir/$id.log"
  wrapper="$agents_dir/$id.sh"

  # A generated script rather than an inline `bash -c`: the loop, the record
  # write and the wait below are twenty lines of shell, and embedding them in a
  # string literal beside a caller-supplied command line is the quoting hazard
  # sweep.sh already documents for its own re-exec.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '# Generated by detached_spawn for %s. Deleting it does not stop the\n' "$id"
    printf '# agent: bash has already read it.\n'
    printf '%s\n' 'set -u'
    printf 'source %q\n' "$_DETACHED_SH"
    printf 'RECORD=%q\n' "$record"
    printf 'AGENT_CWD=%q\n' "$cwd"
    printf 'LOOP_SECONDS=%q\n' "$loop_seconds"
    printf 'set --'
    local arg
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    cat <<'WRAPPER_BODY'

# detached_spawn cannot write the record until the kernel has told it this
# process's pid, so the record may not be there yet. Wait for it. A command
# that finished first would have its exit code overwritten by that write, and
# the row would sit at `working` behind a dead pid until something noticed.
WAITED=0
while [ ! -f "$RECORD" ] && [ "$WAITED" -lt 100 ]; do
  sleep 0.1
  WAITED=$(( WAITED + 1 ))
done
if [ ! -f "$RECORD" ]; then
  printf 'foreman: %s never appeared; refusing to run unrecorded\n' "$RECORD" >&2
  exit 1
fi

if ! cd "$AGENT_CWD"; then
  printf 'foreman: cannot enter %s; the agent was spawned for a directory that is gone\n' "$AGENT_CWD" >&2
  _detached_record_set "$RECORD" exit 1
  exit 1
fi

# stdin from /dev/null on every run of the harness, spawn and resume, codex and
# opencode alike. `codex exec ... --json PROMPT` with stdin left open prints
# "Reading additional input from stdin..." and waits for an EOF that never
# comes: on codex-cli 0.154.0 over ssh it sat 180 seconds with no event, and
# `list` would call it `working` the whole time. Today this wrapper already
# gets /dev/null twice over: detached_spawn redirects it, and a non-interactive
# shell gives any `... &` stdin from /dev/null anyway. Both live in another
# function, and a harness that hangs here hangs with no error to find, so the
# rule is stated where the harness runs.
if [ -z "$LOOP_SECONDS" ]; then
  "$@" </dev/null
  _detached_record_set "$RECORD" exit "$?"
  exit 0
fi

# The tick's shape. A pass that fails does NOT end the loop: the tick is
# expected to fail passes — an unreachable Linear, a repository mid-rebase —
# and a board that stops walking after one bad pass stops dispatching
# altogether. Only a signal ends this, which is why no exit code is written
# here: detached_stop records one, and a death with none recorded already reads
# as stopped.
while :; do
  "$@" </dev/null || true
  sleep "$LOOP_SECONDS"
done
WRAPPER_BODY
  } >"$wrapper" || return 1
  chmod +x "$wrapper" || return 1

  # `setsid()` before the exec is what makes stop work: it puts the wrapper in
  # a brand new session, so its pid is also its process group id and one
  # `kill -TERM -<pid>` reaches the loop, the harness call inside it, and
  # anything the harness spawned. macOS ships no `setsid(1)`, and bash cannot
  # do it, so python3 does — the same python3 this file already needs for JSON.
  #
  # `nohup` on top of that ignores SIGHUP, which survives the exec, so an agent
  # started from a terminal outlives the terminal.
  nohup python3 -c 'import os, sys
os.setsid()
os.execv(sys.argv[1], sys.argv[1:])' "$wrapper" >>"$log" 2>&1 </dev/null &
  local pid=$!

  # Read BEFORE the record is written, because the wrapper cannot run until the
  # record exists, so the process is still sitting in its wait loop here and
  # `ps` is certain to see it.
  #
  # An empty answer for a pid that `kill -0` still finds means `ps` itself is
  # unusable, which is an environment failure and not this agent's. Refusing
  # here leaves the wrapper waiting for a record that never arrives; it gives
  # up after ten seconds without ever running the harness, so nothing is
  # orphaned in the worktree.
  local start_time
  start_time="$(_detached_start_time "$pid")"
  if [[ -z "$start_time" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    printf 'foreman: ps -o lstart= -p %s printed nothing for a process that is running; cannot tell this agent apart from a later pid reuse\n' "$pid" >&2
    return 1
  fi

  # One write, holding every field, AFTER the pid is known — the wrapper is
  # blocked waiting for exactly this file, so nothing can race it.
  _detached_record_set "$record" \
    name "$name" \
    cwd "$cwd" \
    pid "$pid" \
    startedBy "$start_time" \
    sessionId "" \
    startedAt "$started" \
    log "$log" || return 1

  printf '%s\n' "$id"
}

# Record the harness's own session id, once the adapter has parsed it out of
# the event stream. Until this runs the row lists an empty sessionId, which is
# how a caller tells "not named yet" from "named".
detached_note_session() { # <home> <id> <sessionId>
  if [[ $# -ne 3 ]]; then
    printf 'foreman: detached_note_session needs <home> <id> <sessionId>\n' >&2
    return 1
  fi
  local record
  record="$(_detached_record_path "$1" "$2")"
  if [[ ! -f "$record" ]]; then
    printf 'foreman: no agent record at %s\n' "$record" >&2
    return 1
  fi
  _detached_record_set "$record" sessionId "$3"
}

# The one reader of <home>/agents, as a single program with two operations.
#
#   list <home>                     the JSON rows
#   reap <home> <older-than-seconds>  the ids it deleted
#
# Both ask the same question first — is this agent finished? — so `is_alive`
# and `state_of` are written once. A second copy of that rule would drift, and
# a reap that decided `working` differently from `list` would delete the record
# and the log of an agent that is still writing to them.
#
# Printed by a function and passed with `python3 -c`, the same way every other
# python in this file is invoked. A function rather than a variable holding
# `$(cat <<'X' ... X)`: bash 3.2 does not keep the here-document quoted inside a
# command substitution, and the first apostrophe in a comment below then ends a
# string the parser thinks it is in. Measured 2026-09-14 — `bash -n` reported
# "unexpected EOF while looking for matching `''" two hundred lines further
# down, naming a function that was fine.
_detached_records_py() {
  cat <<'RECORDS_PY'
import glob, json, os, subprocess, sys, time

# What one spawn leaves under <home>/agents, all three named by the id: the
# record, the log and the generated wrapper.
SUFFIXES = (".json", ".log", ".sh")

op, home = sys.argv[1], sys.argv[2]


def start_time(pid):
    # The same reading detached_spawn took, normalised the same way: strip the
    # trailing newline and nothing else. See _detached_start_time.
    try:
        result = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        sys.exit("foreman: cannot run ps to check pid %s (%s)" % (pid, exc))
    return result.stdout.decode("utf-8", "replace").rstrip("\n")


def is_alive(record, path):
    pid = record.get("pid")
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Someone else owns it. That is still a process that exists, and
        # reporting it dead would let a second agent start beside it.
        pass
    # The pid exists. Whether it is OUR pid is a second question: the number is
    # recycled, so a record left at `working` across a reboot would otherwise
    # adopt whatever now holds it. A start time that does not match is a death.
    recorded = record.get("startedBy")
    if not recorded:
        sys.exit(
            "foreman: %s records a live pid with no startedBy; refusing to say whether it is this agent or a later process reusing the number"
            % path
        )
    return start_time(pid) == recorded


def state_of(record, alive):
    # `blocked` never appears here. codex.sh and opencode.sh REFUSE to spawn or
    # resume without --skip-permissions, so every agent this file records runs
    # with its harness bypass flag and never waits on a prompt nobody will
    # answer. That refusal is what this row depends on: an `opencode run`
    # without --auto and with no TTY sits on an approval request forever, and
    # this table would call it `working` for the twelve hours until a human
    # looked.
    # Asked to stop is stopped, whatever the process did before the ask. A
    # finished agent carries exit 0 and would otherwise read `done` forever:
    # the stop found no process and changed nothing, so sweep.sh re-issued it
    # until AGENT_STOP_TIMEOUT_SECONDS, failed every terminal card, and its
    # liveness guard kept the card's worktree as a live agent's. `claude stop`
    # moves a `done` Claude agent to `stopped`, and this keeps that promise.
    if record.get("stoppedAt") is not None:
        return "stopped"
    code = record.get("exit")
    if code is not None:
        return "done" if code == 0 else "stopped"
    # A pid that is gone with no exit code recorded is a DEATH: an OOM, a
    # SIGKILL, a reboot. It reads as stopped because we minted this pid
    # ourselves at spawn and wrote it down, so its absence is evidence about
    # this agent. claude.sh must not reason this way: there the registry owns
    # the pid, a missing one only means the registry did not report one, and
    # `state` is the answer to read instead.
    return "working" if alive else "stopped"


def agent_id(path):
    # The filename IS the id. Storing it in the document too would give it two
    # places to disagree with itself after a copy or a rename.
    return os.path.basename(path)[: -len(".json")]


def records(strict):
    # Every record under <home>/agents, as (path, record, state, alive).
    #
    # `strict` is the one thing the two operations disagree about, and it is
    # the unreadable record. `list` REFUSES the whole listing, because a
    # listing that skipped a row would report that agent as absent, and absent
    # is the answer that lets a second tick start beside a healthy one. `reap`
    # DELETES files, so the safe direction is the opposite one: it says what it
    # could not read on stderr and leaves that agent's three files alone.
    for path in sorted(glob.glob(os.path.join(home, "agents", "*.json"))):
        try:
            with open(path) as handle:
                record = json.load(handle)
        except (OSError, ValueError) as exc:
            complain("foreman: %s is not readable JSON (%s)" % (path, exc), strict)
            continue
        if not isinstance(record, dict):
            complain(
                "foreman: %s holds a %s, expected a JSON object" % (path, type(record).__name__),
                strict,
            )
            continue
        # Liveness is asked only when nothing else answers. A record that
        # already carries an exit code is finished whatever holds its pid now,
        # and asking would refuse a perfectly good finished record for a
        # missing startedBy.
        alive = record.get("exit") is None and is_alive(record, path)
        yield path, record, state_of(record, alive), alive


def complain(message, strict):
    if strict:
        sys.exit(message)
    print("%s; leaving its files alone" % message, file=sys.stderr)


def listing():
    rows = []
    for path, record, state, alive in records(strict=True):
        rows.append({
            "name": record.get("name") or "",
            "id": agent_id(path),
            "sessionId": record.get("sessionId") or "",
            # Reported only while the process is up. Consumers read this field
            # as a liveness proxy, and the record keeps the real pid for
            # detached_stop either way.
            "pid": record.get("pid") if alive else None,
            "state": state,
            "startedAt": record.get("startedAt") or 0,
            "cwd": record.get("cwd") or "",
            # Neither harness publishes a status line. null says there is none;
            # "" would claim there is one and that it is blank.
            "status": None,
        })
    # Several rows may share a name, and every consumer takes the newest.
    rows.sort(key=lambda row: row["startedAt"])
    print(json.dumps(rows))


def reap(raw_window):
    try:
        window = float(raw_window)
    except ValueError:
        sys.exit("foreman: reap: older-than-seconds %r is not a number" % raw_window)
    if window < 0:
        sys.exit("foreman: reap: older-than-seconds %r cannot be negative" % raw_window)
    # startedAt is epoch MILLIseconds, the unit every record carries.
    cutoff = int(time.time() * 1000) - int(window * 1000)
    # The same switch sweep.sh reads before every other deletion it makes. The
    # ids still print, so a dry run says exactly which agents a real one would
    # take; only the removal is skipped.
    dry_run = bool(os.environ.get("BOARD_DRY_RUN"))
    for path, record, state, _alive in records(strict=False):
        # `working` is the whole guard. A live agent's log is open and being
        # appended to, and its record is what `stop`, the host ceiling and
        # sweep.sh's worktree protection all read.
        if state == "working":
            continue
        if (record.get("startedAt") or 0) > cutoff:
            continue
        name = agent_id(path)
        if not dry_run:
            for suffix in SUFFIXES:
                target = os.path.join(home, "agents", name + suffix)
                try:
                    os.remove(target)
                except FileNotFoundError:
                    # A log a spawn never got as far as writing, or another
                    # sweep that reached this record first. The file is gone,
                    # which is all this asked for.
                    pass
                except OSError as exc:
                    sys.exit("foreman: cannot remove %s (%s)" % (target, exc))
        print(name)


if op == "list":
    if len(sys.argv) != 3:
        sys.exit("foreman: list takes <home> and nothing else")
    listing()
elif op == "reap":
    if len(sys.argv) != 4:
        sys.exit("foreman: reap takes <home> <older-than-seconds>")
    reap(sys.argv[3])
else:
    sys.exit("foreman: %r is not an operation on agent records" % op)
RECORDS_PY
}

# The spec's JSON list: name, id, sessionId, pid, state, startedAt, cwd, status.
detached_list() { # <home>
  if [[ $# -ne 1 ]]; then
    printf 'foreman: detached_list needs <home>\n' >&2
    return 1
  fi
  python3 -c "$(_detached_records_py)" list "$1"
}

# Delete what every finished agent older than the window left behind, and print
# one line per id.
#
# It computes nothing else: no worktree, no slot, no card. sweep.sh already owns
# every other lifecycle decision on this installation and calls this with the
# retention it applies to the rest of a finished agent's leavings.
#
# BOARD_DRY_RUN is honoured inside, beside the removal it suppresses, and is
# read from the environment because the adapter is a separate process from the
# sweep that sets it.
detached_reap() { # <home> <older-than-seconds>
  if [[ $# -ne 2 ]]; then
    printf 'foreman: detached_reap needs <home> <older-than-seconds>\n' >&2
    return 1
  fi
  python3 -c "$(_detached_records_py)" reap "$1" "$2"
}

# TERM the process group, then KILL what survives, and record the stop.
detached_stop() { # <home> <id>
  if [[ $# -ne 2 ]]; then
    printf 'foreman: detached_stop needs <home> <id>\n' >&2
    return 1
  fi
  local home="$1" id="$2" record pid started_by
  record="$(_detached_record_path "$home" "$id")"
  pid="$(_detached_record_field "$home" "$id" pid)" || return 1
  if [[ -z "$pid" ]]; then
    printf 'foreman: %s records no pid; refusing to signal\n' "$record" >&2
    return 1
  fi

  # Already gone. No exit code goes into the record: the process died on its
  # own and we do not know what it exited with, so writing one would be a
  # guess. The ask is recorded instead, so a finished agent reads stopped after
  # it; state_of says why that matters.
  if ! kill -0 "$pid" 2>/dev/null; then
    _detached_mark_stopped "$record"
    return 0
  fi

  # The pid is held by SOMETHING. The start time says whether it is still ours.
  # Without this check a stale record — one left at `working` across a reboot
  # or a wraparound — makes this function TERM and then KILL a whole process
  # group that belongs to someone else on the machine. A mismatch means our
  # process is gone, which is the case above.
  started_by="$(_detached_record_field "$home" "$id" startedBy)" || return 1
  if [[ -z "$started_by" ]]; then
    printf 'foreman: %s records no startedBy; refusing to signal pid %s, which may belong to another process by now\n' "$record" "$pid" >&2
    return 1
  fi
  if [[ "$(_detached_start_time "$pid")" != "$started_by" ]]; then
    _detached_mark_stopped "$record"
    return 0
  fi

  # The NEGATIVE pid is the point: spawn made this pid a session leader, so it
  # is also the process group id, and the group holds the loop, the harness
  # call inside it and the harness's own children. Signalling the bare pid
  # kills the loop and leaves a `codex exec` running against the worktree the
  # sweep is about to delete. The bare pid is only the fallback, for a spawn
  # whose setsid did not take.
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  local waited=0 signal="$_DETACHED_EXIT_TERM"
  while [[ "$waited" -lt "$_DETACHED_STOP_GRACE_POLLS" ]] && kill -0 "$pid" 2>/dev/null; do
    sleep "$_DETACHED_STOP_POLL_SECONDS"
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    signal="$_DETACHED_EXIT_KILL"
  fi

  # `default`, not `set`: a wrapper that got its own TERM in time wrote the
  # command's real exit code, and that is the better answer. Both are non-zero,
  # so the row reads stopped whichever landed first.
  _detached_record_default "$record" exit "$signal"
  _detached_mark_stopped "$record"
}

# Exit 0 while the recorded process is still THIS agent's, 1 once it is gone,
# and 2 with a message when the record cannot say. Same test as detached_stop
# and the records python: pid plus the start time recorded at spawn. A bare
# `kill -0` would call a recycled pid alive, and a caller waiting on that
# answer would wait out its whole timeout on a stranger's process.
detached_is_running() { # <home> <id>
  if [[ $# -ne 2 ]]; then
    printf 'foreman: detached_is_running needs <home> <id>\n' >&2
    return 2
  fi
  local home="$1" id="$2" pid started_by
  pid="$(_detached_record_field "$home" "$id" pid)" || return 2
  if [[ -z "$pid" ]]; then
    printf 'foreman: %s records no pid; cannot say whether the agent is running\n' \
      "$(_detached_record_path "$home" "$id")" >&2
    return 2
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  started_by="$(_detached_record_field "$home" "$id" startedBy)" || return 2
  if [[ -z "$started_by" ]]; then
    printf 'foreman: %s records no startedBy; cannot tell pid %s apart from a later process reusing it\n' \
      "$(_detached_record_path "$home" "$id")" "$pid" >&2
    return 2
  fi
  [[ "$(_detached_start_time "$pid")" == "$started_by" ]]
}

# Record that this agent was asked to stop. `default`, so a second stop keeps
# the first time. state_of reads the field as stopped, and says why.
_detached_mark_stopped() { # <record file>
  _detached_record_default "$1" stoppedAt "$(date +%s)000"
}

# The log is the transcript: both harnesses stream their turn to stdout, and
# that is the file whose mtime is the agent's last activity.
detached_transcript() { # <home> <id>
  if [[ $# -ne 2 ]]; then
    printf 'foreman: detached_transcript needs <home> <id>\n' >&2
    return 1
  fi
  # Read from the record rather than recomposing <home>/agents/<id>.log, so the
  # path is decided once, in detached_spawn.
  _detached_record_field "$1" "$2" log
}

# One field of the NEWEST row whose <match-field> equals <match-value>, or
# nothing when no row matches.
#
# Several records legitimately share a name — a spawn, then a later resume —
# and every consumer in the board takes the largest startedAt. That rule was
# written out five times across the three adapters; it is written here once.
detached_newest() { # <home> <match-field> <match-value> <out-field>
  if [[ $# -ne 4 ]]; then
    printf 'foreman: detached_newest needs <home> <match-field> <match-value> <out-field>\n' >&2
    return 1
  fi
  # Read into a variable rather than piping detached_list into python: piped, a
  # refusal from detached_list still leaves the filter running on empty stdin,
  # and its traceback buries the one line that said what actually went wrong.
  local agents
  agents="$(detached_list "$1")" || return 1
  printf '%s' "$agents" | python3 -c '
import json, sys

field, want, out = sys.argv[1], sys.argv[2], sys.argv[3]
matches = [row for row in json.load(sys.stdin) if row.get(field) == want]
if matches:
    value = max(matches, key=lambda row: row.get("startedAt") or 0).get(out)
    print("" if value is None else value)
' "$2" "$3" "$4"
}

# The `transcript <cwd> <session-id>` verb, for both adapters.
#
# The cwd the spec puts in that signature is not read. A session id is minted
# by the harness for one session, and a session runs in one directory, so the
# pair and the id alone select the same record; matching on the id alone is the
# rule codex.sh already used.
detached_transcript_for_session() { # <home> <session-id>
  local id
  id="$(detached_newest "$1" sessionId "$2" id)" || return 1
  [[ -n "$id" ]] || die "no agent record for session $2"
  detached_transcript "$1" "$id"
}

# The flags `spawn` and `resume` share, parsed once.
#
# Filled by detached_parse_spawn and detached_parse_resume, read by the
# adapter's argv builder. Globals rather than a return value because bash 3.2
# has no way to return an array and the mcp-config list is one.
DETACHED_NAME=""
DETACHED_CWD=""
DETACHED_MODEL=""
DETACHED_PROMPT_FILE=""
DETACHED_PROMPT=""
DETACHED_LOOP_MINUTES=""
DETACHED_MCP_CONFIGS=()

# A spend ceiling only Claude Code can hold. Refused BY NAME rather than as an
# unknown argument: the operator set MAX_BUDGET_USD expecting a cap, and an
# adapter that silently dropped it would run uncapped. The fix is on their side
# — unset it for this installation.
_detached_refuse_budget() { # <verb>
  die "$1: --max-budget-usd is a Claude Code cap; $_DETACHED_ADAPTER has no per-run spend ceiling. Unset MAX_BUDGET_USD for this installation."
}

# Both harnesses are run with no TTY, from a wrapper nobody is watching.
#
# Without its bypass flag an agent asks for approval and waits for an answer
# that is never typed. `list` calls that `working`, so the card sits at the
# same state until a human looks, which on a board that ticks every twelve
# minutes means twelve hours. There is no degraded mode worth offering: refuse
# the spawn instead, and name the switch the operator has to change.
_detached_require_bypass() { # <verb> <skip-permissions given>
  [[ -n "$2" ]] || die "$1: $_DETACHED_ADAPTER cannot run unattended without its bypass flag; AGENT_SKIP_PERMISSIONS=0 is a Claude-only debugging switch"
}

# The checks both verbs make on a name, a directory and a prompt file. The
# prompt lands in DETACHED_PROMPT.
_detached_parse_common() { # <verb>
  [[ -n "$DETACHED_NAME" ]] || die "$1: --name is required"
  [[ -n "$DETACHED_CWD" && -d "$DETACHED_CWD" ]] \
    || die "$1: --cwd must name a directory, got '$DETACHED_CWD'"
  [[ -n "$DETACHED_PROMPT_FILE" && -r "$DETACHED_PROMPT_FILE" ]] \
    || die "$1: --prompt-file must name a readable file, got '$DETACHED_PROMPT_FILE'"
  DETACHED_PROMPT="$(cat "$DETACHED_PROMPT_FILE")"
  # An empty prompt starts a harness that reads nothing and sits idle, which
  # reads as `working` in `list` forever — the same swallowed-prompt failure
  # claude.sh's spawn refuses.
  [[ -n "${DETACHED_PROMPT//[[:space:]]/}" ]] \
    || die "$1: prompt file $DETACHED_PROMPT_FILE is empty"
}

detached_parse_spawn() {
  DETACHED_NAME=""; DETACHED_CWD=""; DETACHED_MODEL=""; DETACHED_PROMPT_FILE=""
  DETACHED_PROMPT=""; DETACHED_LOOP_MINUTES=""; DETACHED_MCP_CONFIGS=()
  local skip=""
  while [[ $# -gt 0 ]]; do
    # Two passes over the same argument, the same shape claude.sh uses: the
    # first says whether it is a flag this verb knows and whether a value
    # follows it, so a value-less `--name` names the caller's mistake instead
    # of bash's "unbound variable" under `set -u`.
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
      # Accepted and ignored. supervise.sh asks for Remote Control on every tick
      # it starts, whatever the harness; neither harness here has a claude.ai
      # account to register with. Refusing it would leave this installation
      # with no tick at all, which is a far worse answer than no app listing.
      --remote-control) shift; continue ;;
      --name|--cwd|--model|--prompt-file|--add-dir|--mcp-config|--loop-minutes|--settings)
        [[ $# -ge 2 ]] || die "spawn: $1 needs a value" ;;
      --max-budget-usd) _detached_refuse_budget spawn ;;
      *) die "spawn: unknown argument: $1" ;;
    esac
    case "$1" in
      --name) DETACHED_NAME="$2" ;;
      --cwd) DETACHED_CWD="$2" ;;
      --model) DETACHED_MODEL="$2" ;;
      --prompt-file) DETACHED_PROMPT_FILE="$2" ;;
      # Accepted and ignored. Neither harness has a second directory to widen a
      # sandbox to: both run here with their bypass flag, which turns the
      # sandbox off entirely. Claude's adapter needs the flag because ITS
      # permission model stays on and is directory-scoped. Refusing it instead
      # would make every caller branch per harness, which is the branching the
      # adapter exists to remove.
      --add-dir) : ;;
      # Claude Code settings JSON, which dispatch.sh passes for every card agent
      # to turn off Remote Control registration. Neither harness here registers
      # anything with a claude.ai account, so there is nothing for it to turn
      # off. Accepted rather than refused for the same reason as --add-dir.
      --settings) : ;;
      --mcp-config) DETACHED_MCP_CONFIGS+=("$2") ;;
      --loop-minutes) DETACHED_LOOP_MINUTES="$2" ;;
    esac
    shift 2
  done

  _detached_require_bypass spawn "$skip"
  _detached_parse_common spawn
  # Unlike Claude, neither harness here reads an empty --model as "inherit the
  # caller's model". installation.toml refuses to leave a Codex or OpenCode
  # installation's models unset, so an empty value is always a caller bug.
  [[ -n "$DETACHED_MODEL" ]] || die "spawn: --model is required"
}

detached_parse_resume() {
  DETACHED_NAME=""; DETACHED_CWD=""; DETACHED_MODEL=""; DETACHED_PROMPT_FILE=""
  DETACHED_PROMPT=""; DETACHED_LOOP_MINUTES=""; DETACHED_MCP_CONFIGS=()
  local skip=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
      --name|--cwd|--prompt-file|--settings|--mcp-config)
        [[ $# -ge 2 ]] || die "resume: $1 needs a value" ;;
      --max-budget-usd) _detached_refuse_budget resume ;;
      *) die "resume: unknown argument: $1" ;;
    esac
    case "$1" in
      --name) DETACHED_NAME="$2" ;;
      --cwd) DETACHED_CWD="$2" ;;
      --prompt-file) DETACHED_PROMPT_FILE="$2" ;;
      # A resumed agent reconnects to the same MCP servers a fresh one starts,
      # and neither harness keeps a session's MCP config across a resume: codex
      # reads its servers from the profile each run names.
      --mcp-config) DETACHED_MCP_CONFIGS+=("$2") ;;
      # Dropped, as on spawn.
      --settings) : ;;
    esac
    shift 2
  done

  # A resumed agent runs the same tools as a fresh one and blocks on the first
  # of them exactly the same way, so the bypass flag is required on this path
  # too.
  _detached_require_bypass resume "$skip"
  _detached_parse_common resume
}

# `skill-prompt <name> [--loop-minutes K]`, whose K both adapters accept and
# ignore: the loop lives in this file's generated wrapper, around the whole
# harness call, so every pass is a single-pass invocation either way.
_detached_skill_prompt() { # <name> [--loop-minutes K]
  local name="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --loop-minutes)
        [[ $# -ge 2 ]] || die "skill-prompt: --loop-minutes needs a value"
        shift 2 ;;
      *) die "skill-prompt: unknown argument: $1" ;;
    esac
  done
  skill_prompt_text "$name"
}

# The verb table, identical on both adapters. The five functions it calls —
# spawn, resume, check, skills_dir and skill_prompt_text — are what an adapter
# defines.
detached_main() { # <verb> [args...]
  if [[ -z "$_DETACHED_ADAPTER_FILE" ]]; then
    printf 'foreman: no adapter registered; call detached_adapter <name> <file> after sourcing detached.sh\n' >&2
    exit 1
  fi
  [[ $# -ge 1 ]] || usage
  local verb="$1" home
  shift
  case "$verb" in
    spawn) spawn "$@" ;;
    resume) resume "$@" ;;
    list)
      [[ $# -eq 0 ]] || usage
      # `$(detached_home)` cannot sit inline as an argument here: `set -e` reads
      # the exit status of `detached_list`, never the substitution nested inside
      # its argument list, so an unset $FOREMAN_HOME would print `[]` — a
      # confident, wrong "nothing is running" — instead of refusing.
      home="$(detached_home)" || exit 1
      detached_list "$home"
      ;;
    stop)
      [[ $# -eq 1 ]] || usage
      home="$(detached_home)" || exit 1
      detached_stop "$home" "$1"
      ;;
    # One verb for both adapters, here rather than in each of their own `case`:
    # neither file has a verb table any more, and a reap that existed on codex
    # and not on opencode would leave one harness's agents/ growing forever
    # while the sweep reported success.
    reap)
      [[ $# -eq 1 ]] || usage
      home="$(detached_home)" || exit 1
      detached_reap "$home" "$1"
      ;;
    transcript)
      [[ $# -eq 2 ]] || usage
      home="$(detached_home)" || exit 1
      detached_transcript_for_session "$home" "$2"
      ;;
    check)
      [[ $# -eq 0 ]] || usage
      check
      ;;
    skills-dir)
      [[ $# -eq 0 ]] || usage
      skills_dir
      ;;
    skill-prompt)
      [[ $# -ge 1 ]] || usage
      _detached_skill_prompt "$@"
      ;;
    *) usage ;;
  esac
}
