#!/usr/bin/env bash
# The Claude Code harness, behind foreman's adapter verbs.
#
# usage:
#   claude.sh spawn --name N --cwd D --model M --prompt-file F
#                   [--add-dir D]... [--mcp-config F]... [--skip-permissions]
#                   [--max-budget-usd N] [--settings JSON] [--loop-minutes K]
#                                             prints the session id
#   claude.sh resume --name N --cwd D --prompt-file F [--skip-permissions]
#                   [--max-budget-usd N] [--settings JSON]
#                                             prints the session id
#   claude.sh list                            every agent, as a JSON list
#   claude.sh stop <id>                       stop one agent
#   claude.sh reap <older-than-seconds>       nothing here; see the verb below
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
  local add_dirs=() mcp_configs=() args=() dir
  while [[ $# -gt 0 ]]; do
    # Two passes over the same argument: the first says whether it is a flag
    # this verb knows and whether a value follows it. Without that, `set -u`
    # answers a value-less `--name` with "$2: unbound variable", which names
    # bash's problem rather than the one the caller has.
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
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
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-permissions) skip=1; shift; continue ;;
      --name|--cwd|--prompt-file|--max-budget-usd|--settings)
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
  # Nothing to reap. This adapter keeps no records of its own: `claude agents`
  # IS the registry, and Claude Code ages it out itself. codex.sh and
  # opencode.sh answer this verb by deleting the record, log and wrapper that
  # detached.sh wrote for each of their spawns, because nothing else ever would.
  #
  # It still takes the window and still exits 0, so sweep.sh calls the same
  # verb on every installation instead of branching on the harness -- the
  # branching this adapter exists to remove.
  reap)
    [[ $# -eq 1 ]] || usage
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
