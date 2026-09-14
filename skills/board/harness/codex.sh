#!/usr/bin/env bash
# The Codex harness, behind foreman's adapter verbs.
#
# usage:
#   codex.sh spawn --name N --cwd D --model M --prompt-file F
#                  --skip-permissions
#                  [--add-dir D]... [--mcp-config F]... [--loop-minutes K]
#                                             prints the session id
#   codex.sh resume --name N --cwd D --prompt-file F --skip-permissions
#                                             prints the session id
#   codex.sh list                             every agent, as a JSON list
#   codex.sh stop <id>                        stop one agent
#   codex.sh reap <older-than-seconds>        delete what finished agents left
#   codex.sh transcript <cwd> <session-id>    prints the transcript path
#   codex.sh check                            exit 0 if the binary runs
#   codex.sh skills-dir                       where this harness resolves skills
#   codex.sh skill-prompt <name> [--loop-minutes K]
#                                             the text that invokes a skill
#
# Codex has no `--bg` and no agent registry, so `spawn` and `resume` run the
# CLI through detached.sh: it supplies the detached process, the pid record,
# `list`, `stop`, the loop, the flag parsing and the verb table, and this file
# supplies only the command line, the MCP translation and the session-id
# parsing detached.sh's own header says an adapter owns.
#
# THIS FILE SOURCES detached.sh, AND NOTHING ELSE. `config.sh` picks the
# adapter from the installation's `harness` and exports it as `HARNESS_SH`, so
# sourcing `config.sh` back here would be a cycle.
#
# ## Flags, verified on this machine 2026-09-14 against `codex --version` ->
# ## codex-cli 0.133.0, by running `codex exec --help`,
# ## `codex exec resume --help`, `codex mcp add --help` and the config.toml
# ## `codex mcp add` itself writes -- the design fixes the five verbs, not these
# ## spellings.
#
#   -C, --cd <DIR>            codex exec's working directory. NOT accepted by
#                              `codex exec resume`: detached.sh's wrapper
#                              already `cd`s into the agent's cwd before running
#                              this command, which is also how `--all disables
#                              cwd filtering` (resume's own help text) implies
#                              resume finds the right session in the first
#                              place -- from the directory it runs in, not a
#                              flag.
#   -m, --model <MODEL>
#   --dangerously-bypass-approvals-and-sandbox
#   --profile-v2 <NAME>       "Layer $CODEX_HOME/<name>.config.toml on top of
#                              the base user config", quoting `codex exec
#                              --help`. CONFIRMED to load the file and to load
#                              its `[mcp_servers.*]` tables: with an empty base
#                              config.toml and one stdio server in the profile,
#                              `codex exec --profile-v2 <name>` tried to launch
#                              that server and logged the rmcp transport error;
#                              the same command without the flag logged nothing.
#                              A profile file that does not exist is silently
#                              ignored -- which is why the stub in
#                              tests/lib/harness-stub.sh refuses one, and why
#                              spawn below never passes the flag without having
#                              written the file.
#   --json                    one JSON object per event line on stdout. Running
#                              `codex exec --json 'say hi'` while logged in on
#                              this machine printed a `thread.started` event
#                              FIRST, carrying `{"thread_id": "<uuid>"}` --
#                              CONFIRMED, not assumed; the turn itself then
#                              failed on an unrelated model-catalogue error, but
#                              thread.started had already printed. No other
#                              event in the stream carries a session id.
#   codex exec resume <SESSION_ID> [PROMPT]
#
# The MCP table names come from codex itself: `codex mcp add localy --env
# FOO=bar -- /bin/echo hi` and `codex mcp add remotey --url https://...` were
# run against a throwaway CODEX_HOME and the config.toml they wrote is exactly
# the shape _codex_write_profile generates -- `command`, `args` and an
# `[mcp_servers.<name>.env]` sub-table for a local server, a bare `url` for a
# remote one. `bearer_token_env_var` is the only other remote key codex knows;
# it has no way to carry arbitrary HTTP headers, so a remote server whose
# mcp.json entry has `headers` is REFUSED rather than started without them.
#
# ## Why a profile file, and never `-c mcp_servers.<name>.env.KEY=...`
#
# The shared mcp.json carries the Linear credential in a server's `env`. This
# adapter used to interpolate those values into `-c` overrides, which put the
# secret in the codex argv -- readable by every process on the machine through
# /proc/<pid>/cmdline and `ps` -- and, because detached.sh writes the command
# into a generated wrapper, verbatim into `agents/<id>.sh` at mode 0644,
# forever. A secret must never be an argv element and must never land in a
# world-readable file. It goes in a file this adapter creates at 0600 before
# any content is written to it.
#
# That file is `$CODEX_HOME/foreman-<installation>.config.toml`. Writing under
# the operator's CODEX_HOME is acceptable here where rewriting their
# `config.toml` was not: the profile is additive (codex reads it only when
# `--profile-v2` names it, so the operator's own sessions never see it),
# foreman-owned (the `foreman-` prefix and the installation name make it ours
# and no one else's), and deterministic (one file per installation, overwritten
# by each spawn, so nothing accumulates). `config.toml`, by contrast, is read
# by every Codex session on the machine and is the operator's to edit.
set -euo pipefail

_CODEX_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./detached.sh
source "$_CODEX_SH_DIR/detached.sh"
detached_adapter codex "${BASH_SOURCE[0]}"

# The profile file is named for the installation, so two installations on one
# machine cannot overwrite each other's MCP config mid-spawn.
#
# `$INSTALLATION` is what config.sh exports; it is NOT re-derived from a path
# here. installation.py owns that derivation, and a second copy of it agrees
# only until one of them is edited. An unset value is refused rather than
# guessed: the guess would write one installation's credential into another's
# profile.
_codex_profile_name() {
  [[ -n "${INSTALLATION:-}" ]] \
    || die "INSTALLATION is unset; config.sh exports it, and this adapter will not guess which installation's MCP config to write"
  # The same rule installation.py enforces on a name, enforced again because
  # here the name becomes a FILENAME under the operator's CODEX_HOME. A name
  # holding `/` or `..` would write outside it.
  [[ "$INSTALLATION" =~ ^[A-Za-z0-9_]+$ ]] \
    || die "INSTALLATION '$INSTALLATION' is not a name: letters, digits and underscore only"
  printf 'foreman-%s' "$INSTALLATION"
}

_codex_home_dir() {
  printf '%s' "${CODEX_HOME:-$HOME/.codex}"
}

# Translate the Claude-format mcp.json ({"mcpServers": {name: {command, args,
# env}}} or {name: {type, url}}) into one codex profile file.
#
# Reads several sources so a caller passing more than one --mcp-config still
# gets one file; today's callers pass exactly one, `$FOREMAN_HOME/mcp.json`.
_codex_write_profile() { # <dest> <mcp.json>...
  python3 -c '
import json, os, re, sys

dest = sys.argv[1]
sources = sys.argv[2:]

# A bare TOML key is letters, digits, underscore and dash. It governs the
# server NAME and every env KEY alike: a key holding a dot would open a nested
# table nobody asked for, and one holding `=` or a quote makes codex refuse the
# whole file. The name rule alone used to be checked, and env keys went through
# unvalidated.
KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def toml_string(value):
    out = [chr(34)]
    for char in value:
        point = ord(char)
        if char == chr(34):
            out.append("\\" + chr(34))
        elif char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif point < 0x20 or point == 0x7F:
            out.append("\\u%04X" % point)
        else:
            out.append(char)
    out.append(chr(34))
    return "".join(out)


servers = {}
for path in sources:
    with open(path) as handle:
        try:
            doc = json.load(handle)
        except ValueError as exc:
            sys.exit("foreman: %s is not readable JSON (%s)" % (path, exc))
    if not isinstance(doc, dict):
        sys.exit("foreman: %s holds a %s, expected a JSON object" % (path, type(doc).__name__))
    entries = doc.get("mcpServers")
    if not isinstance(entries, dict):
        sys.exit("foreman: %s.mcpServers is missing or not a JSON object" % path)

    for name, entry in entries.items():
        if not KEY.match(name):
            sys.exit("foreman: %s.mcpServers has a server named %r; only letters, digits, underscore and dash are allowed" % (path, name))
        if name in servers:
            sys.exit("foreman: mcp server %r is defined in more than one --mcp-config file" % name)
        if not isinstance(entry, dict):
            sys.exit("foreman: %s.mcpServers.%s holds a %s, expected a JSON object" % (path, name, type(entry).__name__))

        lines = ["[mcp_servers.%s]" % name]
        env = {}
        if "command" in entry:
            command = entry.get("command")
            if not isinstance(command, str) or not command:
                sys.exit("foreman: %s.mcpServers.%s.command is missing or not a non-empty string" % (path, name))
            args = entry.get("args", [])
            if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
                sys.exit("foreman: %s.mcpServers.%s.args must be a list of strings" % (path, name))
            env = entry.get("env", {})
            if not isinstance(env, dict) or not all(isinstance(v, str) for v in env.values()):
                sys.exit("foreman: %s.mcpServers.%s.env must be an object of strings" % (path, name))
            lines.append("command = %s" % toml_string(command))
            if args:
                lines.append("args = [%s]" % ", ".join(toml_string(a) for a in args))
        elif "url" in entry:
            # A remote server, e.g. {"type": "http", "url": "https://..."}. The
            # old `-c` translation refused this shape outright, so one remote
            # Linear MCP killed every codex spawn on the installation while
            # opencode.sh translated the same entry without complaint.
            url = entry.get("url")
            if not isinstance(url, str) or not url:
                sys.exit("foreman: %s.mcpServers.%s.url is missing or not a non-empty string" % (path, name))
            if entry.get("headers"):
                sys.exit("foreman: %s.mcpServers.%s has headers; codex 0.133.0 carries only url and bearer_token_env_var, and starting this server without its headers would hand the model an unauthenticated connection" % (path, name))
            lines.append("url = %s" % toml_string(url))
        else:
            sys.exit("foreman: %s.mcpServers.%s has neither command nor url; cannot translate it" % (path, name))

        # AFTER every scalar key of this server: a sub-table header ends the
        # table above it, so an `args = [...]` written below this point would
        # be read as an environment variable called args.
        if env:
            lines.append("")
            lines.append("[mcp_servers.%s.env]" % name)
            for key, value in env.items():
                if not KEY.match(key):
                    sys.exit("foreman: %s.mcpServers.%s.env has a key named %r; only letters, digits, underscore and dash are allowed" % (path, name, key))
                lines.append("%s = %s" % (key, toml_string(value)))
        servers[name] = lines

body = ["# Generated by foreman for this installation. Overwritten on every",
        "# spawn; edit mcp.json, not this file.", ""]
for name in servers:
    body.extend(servers[name])
    body.append("")

# 0600 BEFORE any content lands, which is why this is os.open with an explicit
# mode and not open(): the file holds the Linear credential, and a file that is
# world-readable for the microsecond between creation and chmod is a file that
# was world-readable. A leftover temp file is removed first, because O_TRUNC on
# an existing file keeps the mode that file already had.
os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
tmp = "%s.tmp.%d" % (dest, os.getpid())
if os.path.exists(tmp):
    os.unlink(tmp)
handle = os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w")
with handle:
    handle.write("\n".join(body))
os.replace(tmp, dest)
' "$@"
}

# Poll the agent's log for the `thread.started` event and pull `thread_id` out
# of it. Prints nothing (not an error) while the event has not appeared yet --
# detached.sh's wrapper waits on the record before it even runs `codex`, so the
# log can still be empty right after detached_spawn returns.
_codex_thread_id_from_log() { # <log>
  local log="$1"
  [[ -r "$log" ]] || return 0
  python3 -c '
import json, sys

path = sys.argv[1]
try:
    handle = open(path)
except FileNotFoundError:
    sys.exit(0)
with handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("type") == "thread.started":
            thread_id = event.get("thread_id")
            if isinstance(thread_id, str) and thread_id:
                print(thread_id)
            break
' "$log"
}

# How long spawn waits for `thread.started` before refusing. 60 polls of 0.5s:
# generous next to the model-catalogue round trip codex makes before its first
# event, short next to a build's own budget.
_CODEX_SESSION_POLL_SECONDS=0.5
_CODEX_SESSION_TIMEOUT_POLLS=60

_codex_await_session() { # <home> <id>
  local home="$1" id="$2" log elapsed=0 session
  log="$(detached_transcript "$home" "$id")" || return 1
  while [[ "$elapsed" -lt "$_CODEX_SESSION_TIMEOUT_POLLS" ]]; do
    session="$(_codex_thread_id_from_log "$log")" || return 1
    if [[ -n "$session" ]]; then
      detached_note_session "$home" "$id" "$session" || return 1
      printf '%s\n' "$session"
      return 0
    fi
    sleep "$_CODEX_SESSION_POLL_SECONDS"
    elapsed=$(( elapsed + 1 ))
  done
  # STOP IT BEFORE DYING. The process is running codex in the worktree right
  # now; giving up without stopping it leaves a live harness there while
  # dispatch.sh moves on to attempt 2 and `git worktree remove -f -f`s the same
  # directory out from under it.
  detached_stop "$home" "$id" || true
  die "codex never printed a thread.started event for $id; see $log"
}

spawn() {
  detached_parse_spawn "$@"

  # `|| exit 1`, not trust in `set -e`: a command substitution's failure is
  # invisible to `set -e` the moment it sits inside anything but a bare
  # assignment (an argument list, a second substitution around it), and
  # claude.sh's lookup_session already documents catching this the hard way.
  # Every such call in this file keeps this guard for that reason, even the
  # ones that look safe today.
  local home id session
  home="$(detached_home)" || exit 1

  local args=(exec -C "$DETACHED_CWD" -m "$DETACHED_MODEL")
  # Always bypassed: detached_parse_spawn refuses a spawn without
  # --skip-permissions, so there is no second sandbox mode to branch on.
  args+=(--dangerously-bypass-approvals-and-sandbox)

  if [[ ${#DETACHED_MCP_CONFIGS[@]} -gt 0 ]]; then
    local profile profile_file
    profile="$(_codex_profile_name)" || exit 1
    profile_file="$(_codex_home_dir)/$profile.config.toml"
    _codex_write_profile "$profile_file" "${DETACHED_MCP_CONFIGS[@]}"
    args+=(--profile-v2 "$profile")
  fi

  # `--json` and the prompt come last: `--profile-v2`, unlike claude's
  # `--add-dir`, is not variadic, so there is no ordering hazard here, but the
  # prompt still goes after every flag and behind `--` so a prompt beginning
  # with `-` cannot be read as one.
  args+=(--json -- "$DETACHED_PROMPT")

  id="$(detached_spawn "$DETACHED_NAME" "$DETACHED_CWD" "$home" "$DETACHED_LOOP_MINUTES" -- codex "${args[@]}")" || exit 1
  session="$(_codex_await_session "$home" "$id")" || exit 1
  printf '%s\n' "$session"
}

resume() {
  detached_parse_resume "$@"

  local home session id
  home="$(detached_home)" || exit 1
  session="$(detached_newest "$home" name "$DETACHED_NAME" sessionId)" || exit 1
  [[ -n "$session" ]] || die "no agent named $DETACHED_NAME to resume"

  local args=(exec resume "$session" --dangerously-bypass-approvals-and-sandbox)
  args+=(--json -- "$DETACHED_PROMPT")

  # No --loop-minutes here, same as claude.sh's resume: the spec's own verb
  # table gives resume no such flag, on any adapter.
  id="$(detached_spawn "$DETACHED_NAME" "$DETACHED_CWD" "$home" "" -- codex "${args[@]}")" || exit 1
  # The id RESUMED FROM, not a freshly-awaited one: `codex exec resume`
  # continues that session, so it is what the caller already has on the card,
  # the same convention claude.sh's resume documents for its own fork.
  detached_note_session "$home" "$id" "$session" || exit 1
  printf '%s\n' "$session"
}

check() { codex --version; }

skills_dir() {
  # The override is what lets a test point an install at a temporary
  # directory instead of the operator's real one, the same as claude.sh's
  # CLAUDE_SKILLS_DIR; install-skills.sh reads it through this verb rather
  # than composing the path a second time.
  printf '%s\n' "${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
}

skill_prompt_text() { # <name>
  # ASSUMPTION -- could not verify against the CLI. codex-cli 0.133.0's own
  # --help exposes no `skill` subcommand and no flag naming one on this
  # machine, so this follows this node's brief rather than an observed flag:
  # an installed skill is referenced in the prompt as `$<name>`. If that
  # spelling is wrong, every prompt this adapter builds still reaches codex --
  # it just fails to invoke the skill, the same failure a typo'd `/board` would
  # be for claude.sh.
  printf '$%s\n' "$1"
}

detached_main "$@"
