#!/usr/bin/env bash
# The Claude Code harness, behind foreman's adapter verbs.
#
# usage:
#   claude.sh spawn --name N --cwd D --model M --prompt-file F
#                   [--add-dir D]... [--mcp-config F]... [--skip-permissions]
#                   [--max-budget-usd N] [--settings JSON] [--loop-minutes K]
#                   [--remote-control]
#                                             prints the session id
#   claude.sh resume --name N --cwd D --prompt-file F [--skip-permissions]
#                   [--mcp-config F]... [--max-budget-usd N] [--settings JSON]
#                                             prints the session id
#   claude.sh list                            every agent, as a JSON list
#   claude.sh stop <id>                       stop one agent
#   claude.sh reap <older-than-seconds>       delete finished foreman records,
#                                             printing the ids it took
#   claude.sh transcript <cwd> <session-id>   prints the transcript path
#   claude.sh check                           exit 0 if the binary runs
#   claude.sh skills-dir                      where this harness resolves skills
#   claude.sh skill-prompt <name> [--loop-minutes K]
#                                             the text that invokes a skill
#
# Every script that ran `claude` directly runs this instead, so one file knows
# how the CLI spells its flags. `config.sh` picks the adapter from the
# installation's `harness` and exports it as `HARNESS_SH`.
#
# THIS FILE SOURCES NOTHING. `config.sh` selects it, so sourcing `config.sh`
# back would be a cycle; and `config.sh` needs `FOREMAN_INSTANCE`, which a
# `check` run before any board exists cannot supply.
set -euo pipefail

die() { printf 'harness/claude: %s\n' "$*" >&2; exit 1; }

# The usage block in this file's own header is the only copy. A second one in a
# here-doc drifts the day a verb is added, and the caller who just mistyped one
# is then shown the older of the two.
usage() {
  sed -n '/^# usage:$/,/^#$/{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# The registry as a JSON list, carrying only the fields foreman reads.
#
# "I could not tell" must never look like "no agents are running". A caller that
# folds a failed `claude agents` into an empty list answers it by starting a
# second tick beside a healthy one, or by re-dispatching on top of a live build.
# So this refuses instead, and prints nothing when it refuses.
list_agents() {
  local raw
  raw="$(claude agents --json --all 2>/dev/null)" \
    || die "claude agents exited non-zero; refusing to answer as if nothing were running"
  printf '%s' "$raw" | python3 -c '
import json, sys

FIELDS = ("name", "id", "sessionId", "pid", "state", "startedAt", "cwd", "status")
try:
    agents = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
# A registry that is not a LIST is not an empty one. Iterating a future
# {"agents": [...]} wrapper walks its KEYS, matches nothing, and prints an empty
# list with exit 0 -- the one answer that lets a second tick start.
if not isinstance(agents, list):
    sys.exit(3)
print(json.dumps([{k: a.get(k) for k in FIELDS} for a in agents if isinstance(a, dict)]))
' || die "claude agents did not print a JSON list"
}

# The session id of the newest agent called <name>, or nothing.
#
# `--bg --resume` FORKS: it starts a new session id and inherits the name, so
# several agents legitimately share one. The newest `startedAt` is the live one.
# Taking the first match resumes a dead session and silently loses every turn
# since.
lookup_session() { # <name>
  # Read the registry into a variable rather than piping it, so a refusal from
  # `list_agents` ends this function. Piped, the filter below still runs, on an
  # empty stdin, and prints a JSON traceback UNDER the one line that says what
  # actually went wrong -- sending the reader after Python's internals.
  #
  # `|| exit 1` rather than trusting `set -e`. Bash 3.2 does NOT apply `set -e`
  # to an assignment made inside a command substitution that is itself being
  # substituted, which is exactly the shape here: spawn's `session="$(...)"`
  # around this function's `agents="$(...)"`. Measured 2026-09-14 -- the refusal
  # printed, this function carried on and returned an empty string, and spawn
  # reported "it never registered". That is the one confusion this whole path
  # exists to prevent: "I could not tell" wearing "nothing is running"'s clothes.
  local agents
  agents="$(list_agents)" || exit 1
  printf '%s' "$agents" | python3 -c '
import json, sys

want = sys.argv[1]
matches = [a for a in json.load(sys.stdin) if a.get("name") == want]
if matches:
    print(max(matches, key=lambda a: a.get("startedAt") or 0).get("sessionId") or "")
' "$1"
}

# `--dangerously-skip-permissions` IS `--permission-mode bypassPermissions`;
# passing both conflicts, so it is one or the other. Whichever is chosen is
# NON-VARIADIC, which is what keeps the prompt from being swallowed -- see the
# order rule in spawn(). This holds on the resume path too: a resumed agent with
# no permission flag blocks on its first Bash call exactly like a fresh one.
PERMISSION_ARGS=()
set_permission_args() { # <non-empty to skip permissions>
  if [[ -n "$1" ]]; then
    PERMISSION_ARGS=(--dangerously-skip-permissions)
  else
    PERMISSION_ARGS=(--permission-mode acceptEdits)
  fi
}

spawn() {
  local name="" cwd="" model="" model_given="" prompt_file="" skip="" budget="" settings="" prompt session
  local remote_control=""
  local add_dirs=() mcp_configs=() args=() dir
  while [[ $# -gt 0 ]]; do
    # Two passes over the same argument: the first says whether it is a flag
    # this verb knows and whether a value follows it. Without that, `set -u`
    # answers a value-less `--name` with "$2: unbound variable", which names
    # bash's problem rather than the one the caller has.
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
      # Registers the session with the operator's claude.ai account, so it can
      # be opened from the desktop or mobile app. supervise.sh asks for it on
      # the tick and nothing else does. On 2.1.273 a `--bg` session that does
      # not ask is not listed there at all, so staying out of the way of Remote
      # Control is not the same as having it.
      --remote-control) remote_control=1; shift; continue ;;
      --name|--cwd|--model|--prompt-file|--add-dir|--mcp-config|--loop-minutes|--max-budget-usd|--settings)
        [[ $# -ge 2 ]] || die "spawn: $1 needs a value" ;;
      *) die "spawn: unknown argument: $1" ;;
    esac
    case "$1" in
      --name) name="$2" ;;
      --cwd) cwd="$2" ;;
      # A per-agent spend ceiling. Claude Code is the one harness with such a
      # flag, so this is the one adapter that takes it; codex.sh and
      # opencode.sh refuse it by name rather than dropping a cap the operator
      # set. dispatch.sh passes it whenever MAX_BUDGET_USD is non-empty.
      --max-budget-usd) budget="$2" ;;
      # Claude Code settings JSON for this one agent. dispatch.sh passes
      # config.sh's CARD_AGENT_SETTINGS, which turns off the Remote Control
      # registration a card agent would otherwise leave behind forever.
      --settings) settings="$2" ;;
      # An empty model is a VALUE, not an omission: `--model ""` reaches the CLI
      # as an empty `--model`, which Claude Code reads as "inherit this session's
      # model". config.sh's `PLAN_MODEL=` convention depends on it surviving the
      # trip, so emptiness cannot be the test for "was it given".
      --model) model="$2"; model_given=1 ;;
      --prompt-file) prompt_file="$2" ;;
      --add-dir) add_dirs+=("$2") ;;
      --mcp-config) mcp_configs+=("$2") ;;
      # Accepted and ignored. `/loop` already loops inside one session, so the
      # cadence belongs to the agent and not to a wrapper. The other adapters
      # need K because their harness returns when the turn ends. Refusing it
      # here would make every caller branch per harness, which is the branching
      # this adapter exists to remove.
      --loop-minutes) : ;;
    esac
    shift 2
  done

  [[ -n "$name" ]] || die "spawn: --name is required"
  [[ -n "$cwd" && -d "$cwd" ]] || die "spawn: --cwd must name a directory, got '$cwd'"
  [[ -n "$model_given" ]] || die "spawn: --model is required (an empty value is allowed)"
  [[ -n "$prompt_file" && -r "$prompt_file" ]] \
    || die "spawn: --prompt-file must name a readable file, got '$prompt_file'"
  prompt="$(cat "$prompt_file")"
  # An empty prompt spawns an agent that authenticates and then waits at an
  # empty prompt box forever, which is indistinguishable from the swallowed
  # prompt below and just as invisible.
  [[ -n "${prompt//[[:space:]]/}" ]] || die "spawn: prompt file $prompt_file is empty"

  # ORDER IS LOAD-BEARING. `--add-dir <directories...>`, `--tools <tools...>` and
  # `--mcp-config <files...>` are VARIADIC: whatever follows one is eaten as
  # another value. A prompt placed after one produces an agent that starts,
  # authenticates, and then sits at an empty prompt box forever -- `state:
  # blocked`, no transcript, no error. A non-variadic flag must therefore sit
  # immediately before the prompt, and the permission flag is the one that does.
  # Any flag added here goes BEFORE set_permission_args, never after.
  args=(--bg --name "$name" --model "$model")
  for dir in ${add_dirs[@]+"${add_dirs[@]}"}; do args+=(--add-dir "$dir"); done
  for dir in ${mcp_configs[@]+"${mcp_configs[@]}"}; do args+=(--mcp-config "$dir"); done
  [[ -z "$budget" ]] || args+=(--max-budget-usd "$budget")
  # One value, never variadic, so it may sit anywhere before the permission flag.
  [[ -z "$settings" ]] || args+=(--settings "$settings")
  # The CLI's `--remote-control [name]` takes an OPTIONAL value, so a bare flag
  # would take whatever followed it as the session's name -- the permission
  # flag here, or the prompt if anyone ever reordered this. Passing the name
  # makes the value explicit, and it is the name the app then shows.
  [[ -z "$remote_control" ]] || args+=(--remote-control "$name")
  set_permission_args "$skip"
  args+=("${PERMISSION_ARGS[@]}")

  # The CLI's own chatter would land on stdout beside the session id this verb
  # promises, and every caller reads that id with a command substitution.
  cd "$cwd"
  claude "${args[@]}" "$prompt" >/dev/null

  # `|| exit 1` for the reason lookup_session records: an unreadable registry
  # must not arrive here as an empty string and be reported as "never registered".
  session="$(lookup_session "$name")" || exit 1
  [[ -n "$session" ]] || die "spawned $name but it never registered with claude agents"
  printf '%s\n' "$session"
}

resume() {
  local name="" cwd="" prompt_file="" skip="" budget="" settings="" prompt session
  local args=() mcp_configs=() config
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
      --name|--cwd|--prompt-file|--max-budget-usd|--settings|--mcp-config)
        [[ $# -ge 2 ]] || die "resume: $1 needs a value" ;;
      *) die "resume: unknown argument: $1" ;;
    esac
    case "$1" in
      --name) name="$2" ;;
      --cwd) cwd="$2" ;;
      --prompt-file) prompt_file="$2" ;;
      # The same ceiling spawn takes. A resumed agent runs the same tests and
      # spends the same way, so the cap holds on this path too.
      --max-budget-usd) budget="$2" ;;
      # Claude Code settings JSON for this one agent. dispatch.sh passes
      # config.sh's CARD_AGENT_SETTINGS, which turns off the Remote Control
      # registration a card agent would otherwise leave behind forever.
      --settings) settings="$2" ;;
      # The same MCP servers spawn takes. The codex adapter needs them on
      # resume because codex keeps no MCP config across one; accepting the flag
      # here keeps one contract across adapters.
      --mcp-config) mcp_configs+=("$2") ;;
    esac
    shift 2
  done

  [[ -n "$name" ]] || die "resume: --name is required"
  [[ -n "$cwd" && -d "$cwd" ]] || die "resume: --cwd must name a directory, got '$cwd'"
  [[ -n "$prompt_file" && -r "$prompt_file" ]] \
    || die "resume: --prompt-file must name a readable file, got '$prompt_file'"
  prompt="$(cat "$prompt_file")"
  [[ -n "${prompt//[[:space:]]/}" ]] || die "resume: prompt file $prompt_file is empty"

  session="$(lookup_session "$name")" || exit 1
  [[ -n "$session" ]] || die "no agent named $name to resume"

  cd "$cwd"
  args=(--bg --resume "$session")
  # VARIADIC, so before the permission flag, by spawn's order rule.
  for config in ${mcp_configs[@]+"${mcp_configs[@]}"}; do args+=(--mcp-config "$config"); done
  [[ -z "$budget" ]] || args+=(--max-budget-usd "$budget")
  # One value, never variadic, so it may sit anywhere before the permission flag.
  [[ -z "$settings" ]] || args+=(--settings "$settings")
  set_permission_args "$skip"
  args+=("${PERMISSION_ARGS[@]}")
  claude "${args[@]}" "$prompt" >/dev/null
  # The id RESUMED FROM, which is what the caller records against the card. The
  # fork this resume just started carries the same name, so the next lookup by
  # name finds it without anyone having to remember either id.
  printf '%s\n' "$session"
}

# The namespace every name foreman gives an agent starts with. `config.sh`
# spells it literally twice -- `TICK_AGENT_NAME="foreman/tick"` and
# `BOARD_NAME_PREFIX="foreman/$INSTANCE"` -- and THIS FILE SOURCES NOTHING, so
# it carries its own copy. Changing the namespace means changing both places.
FOREMAN_NAME_ROOT="foreman/"

# Delete the record of every finished foreman agent older than the window, and
# print one id per line.
#
# `~/.claude/jobs/<short-id>/` is Claude Code's record of a `--bg` session, and
# it is what `claude agents --json --all` lists an agent from. Removing the
# directory is the only thing that clears the listing; no `claude` subcommand
# does. Until 2026-09-22 this verb was a no-op, commented "Claude Code ages it
# out itself". It does not: records days old were still listed, still `done`,
# and sweep.sh reads every listed agent as a live one -- so no Claude-harness
# worktree could ever be reaped. One machine reached 72 worktrees and 261G,
# which failed preflight's free-disk gate and stopped every board dispatching.
reap() { # <older-than-seconds>
  python3 - "$HOME/.claude/jobs" "$1" "$FOREMAN_NAME_ROOT" <<'PY'
import json, os, shutil, sys, time

jobs, raw_window, name_root = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    window = float(raw_window)
except ValueError:
    sys.exit("foreman: reap: older-than-seconds %r is not a number" % raw_window)
if window < 0:
    sys.exit("foreman: reap: older-than-seconds %r cannot be negative" % raw_window)

# The same switch sweep.sh reads before every other deletion it makes. The ids
# still print, so a dry run says exactly which records a real one would take;
# only the removal is skipped. Read from the environment because the adapter is
# a separate process from the sweep that sets it.
dry_run = bool(os.environ.get("BOARD_DRY_RUN"))

if not os.path.isdir(jobs):
    sys.exit(0)

cutoff = time.time() - window

for short in sorted(os.listdir(jobs)):
    directory = os.path.join(jobs, short)
    # `pins.json` is a FILE in this directory. Only a directory is a record.
    if not os.path.isdir(directory):
        continue
    path = os.path.join(directory, "state.json")
    try:
        # The age comes from the mtime of state.json, never from a field inside
        # it. The schema is Claude Code's, not foreman's, and it changed under
        # us once already: on 2.1.228 (2026-09-13) `claude stop` wrote `state:
        # stopped` into the record, and by 2026-09-22 it printed "stopped <id>",
        # exited 0 and left the record saying `done`. The mtime is the
        # filesystem's own answer to "nothing has touched this in thirty days",
        # and the daemon writes the record as the agent runs.
        mtime = os.path.getmtime(path)
        with open(path) as handle:
            record = json.load(handle)
    except (OSError, ValueError) as exc:
        # reap DELETES files, so an unreadable record goes the safe way: name it
        # and leave it. Saying so is not a failure of the reap, so the exit code
        # stays 0 -- detached.sh's `complain(..., strict=False)` rule.
        print("foreman: could not read %s (%s); leaving that record" % (path, exc), file=sys.stderr)
        continue
    if not isinstance(record, dict):
        print("foreman: %s is not a JSON object; leaving that record" % path, file=sys.stderr)
        continue
    # ~/.claude/jobs is the OPERATOR'S directory, shared with their own
    # `claude --bg` sessions. Those are not foreman's to delete, so a record is
    # taken only when its name sits under foreman's own namespace root.
    if not (record.get("name") or "").startswith(name_root):
        continue
    # FINISHED is: the turn is over AND the process is gone. `working` is never
    # taken, even if it somehow lost its pid -- the same tie-goes-to-leaving-it
    # rule detached.sh's reap applies. A record that still holds a pid is a
    # process that is still up whatever its state says: its log is open, and
    # sweep.sh's worktree protection reads it.
    if record.get("state") == "working":
        continue
    if record.get("pid"):
        continue
    if mtime > cutoff:
        continue
    if not dry_run:
        try:
            shutil.rmtree(directory)
        except OSError as exc:
            sys.exit("foreman: cannot remove %s (%s)" % (directory, exc))
    print(short)
PY
}

transcript() { # <cwd> <session-id>
  # Claude persists a session at ~/.claude/projects/<slug>/<id>.jsonl, where the
  # slug is the cwd with every '/' and '.' replaced by '-'. The file's mtime is
  # the agent's last activity, which is how liveness here tells "waiting for the
  # next tick" apart from "wedged mid-turn"; `state` alone cannot.
  local slug
  slug="$(printf '%s' "$1" | tr './' '--')"
  printf '%s/.claude/projects/%s/%s.jsonl\n' "$HOME" "$slug" "$2"
}

skill_prompt() { # <name> [--loop-minutes K]
  local name="$1" loop=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --loop-minutes)
        [[ $# -ge 2 ]] || die "skill-prompt: --loop-minutes needs a value"
        loop=1; shift 2 ;;
      *) die "skill-prompt: unknown argument: $1" ;;
    esac
  done
  # `/loop /<name>` carries NO interval. `/loop 20m /<name>` is fixed-interval
  # cron mode, which polls and never arms the agent Monitor -- the polling design
  # the event-driven board replaced. So K is read only as "this prompt loops",
  # and the number never reaches the prompt text.
  if [[ -n "$loop" ]]; then
    printf '/loop /%s\n' "$name"
  else
    printf '/%s\n' "$name"
  fi
}

[[ $# -ge 1 ]] || usage
VERB="$1"
shift
case "$VERB" in
  spawn) spawn "$@" ;;
  resume) resume "$@" ;;
  list)
    [[ $# -eq 0 ]] || usage
    list_agents
    ;;
  stop)
    [[ $# -eq 1 ]] || usage
    claude stop "$1"
    ;;
  # Claude Code keeps the registry, but it never ages it out: a record under
  # `~/.claude/jobs/<short-id>/` outlives the process by days, and every listed
  # agent protects its worktree from the sweep. So this verb deletes what
  # codex.sh and opencode.sh delete through detached.sh -- the record of a
  # finished agent -- and for the same reason: nothing else ever would.
  #
  # It takes the same window and prints the same one-id-per-line answer on every
  # harness, so sweep.sh calls one verb instead of branching on the harness --
  # the branching this adapter exists to remove.
  reap)
    [[ $# -eq 1 ]] || usage
    reap "$1"
    ;;
  transcript)
    [[ $# -eq 2 ]] || usage
    transcript "$1" "$2"
    ;;
  check)
    [[ $# -eq 0 ]] || usage
    claude --version
    ;;
  skills-dir)
    [[ $# -eq 0 ]] || usage
    # The override is what lets a test point an install at a temporary directory
    # instead of the operator's real one; `install-skills.sh` reads it through
    # this verb rather than composing the path a second time.
    printf '%s\n' "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
    ;;
  skill-prompt)
    [[ $# -ge 1 ]] || usage
    skill_prompt "$@"
    ;;
  *) usage ;;
esac
