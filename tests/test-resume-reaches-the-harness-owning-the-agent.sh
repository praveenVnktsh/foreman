#!/bin/bash
# Claim: registry.sh sends `resume` and `transcript` to the harness that owns
# the agent, on an installation that spawns on more than one harness.
#
# The failure it prevents: a stage that falls back from Claude to Codex leaves
# its build in Codex's registry. registry.sh sent every resume to the default
# harness, so resuming that build asked Claude for an agent it never had. And
# claude.sh's transcript composed a path for any session id at all and exited
# 0, so as the first harness asked it answered for the Codex agent too, with a
# file that never existed: no idle time for the build, and a sweep pointed at
# the wrong directory. Codex and OpenCode share one registry directory, so a
# resume by name there has to go by the harness the record names.
#
# Drives the real registry.sh and the real adapters, with only the three CLIs
# stubbed (tests/lib/harness-stub.sh).
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
# shellcheck source=lib/harness-stub.sh
source "$here/lib/harness-stub.sh"

work="$(mktemp -d)"
trap ': >"$HARNESS_STUB_MARKER" 2>/dev/null; sleep 0.5; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
same() {
  if [[ "$2" == "$3" ]]; then ok "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3" >&2; fail=1; fi
}

harness_dir="$root/skills/board/harness"
registry="$harness_dir/registry.sh"
harness_stub_install "$work/bin" "$work/state"
export HOME="$work/home"
export FOREMAN_HOME="$work/foreman"
export PATH="$work/bin:$PATH"
mkdir -p "$HOME" "$FOREMAN_HOME/agents"
cwd="$work/worktree"
mkdir -p "$cwd"
prompt="$work/prompt.md"
echo "do the thing" >"$prompt"

spawn_on() { # <harness> <name>
  "$harness_dir/$1.sh" spawn --name "$2" --cwd "$cwd" --model stub-model \
    --prompt-file "$prompt" --skip-permissions
}
resume_through_registry() { # [--harness H] <name>
  local forced=()
  if [[ "$1" == "--harness" ]]; then forced=(--harness "$2"); shift 2; fi
  "$registry" resume ${forced[@]+"${forced[@]}"} --name "$1" --cwd "$cwd" \
    --prompt-file "$prompt" --skip-permissions
}
# The harness of the newest detached record named <name>.
newest_harness() { # <name>
  FOREMAN_HARNESSES=codex FOREMAN_DEFAULT_HARNESS=codex "$registry" list | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if r.get("name") == sys.argv[1]]
print(max(rows, key=lambda r: r["startedAt"]).get("harness") if rows else "")
' "$1"
}

# Claude is the default; the build fell back to Codex.
export FOREMAN_DEFAULT_HARNESS=claude FOREMAN_HARNESSES="claude codex"
native="$(spawn_on claude native)" || bad "claude spawn failed"
fallback="$(spawn_on codex fallback)" || bad "codex spawn failed"

same "resume of an agent on a fallback harness reaches that harness" \
  "$fallback" "$(resume_through_registry fallback 2>&1)"
same "resume of an agent on the default harness still reaches it" \
  "$native" "$(resume_through_registry native 2>&1)"
same "resume --harness sends the resume to the harness named" \
  "$fallback" "$(resume_through_registry --harness codex fallback 2>&1)"

path="$("$registry" transcript "$cwd" "$fallback")"
if [[ "$path" == "$FOREMAN_HOME"/agents/*.log && -e "$path" ]]; then
  ok "transcript of a fallback agent is its own log, not a Claude path"
else
  bad "transcript of a fallback agent answered '$path'"
fi
path="$("$registry" transcript "$cwd" "$native")"
if [[ "$path" == "$HOME"/.claude/projects/* && -e "$path" ]]; then
  ok "transcript of a Claude agent is its session file"
else
  bad "transcript of a Claude agent answered '$path'"
fi
if "$harness_dir/claude.sh" transcript "$cwd" "$fallback" >/dev/null 2>&1; then
  bad "claude.sh transcript exited 0 for a session it has no file for"
else
  ok "claude.sh transcript exits non-zero for a session it has no file for"
fi
if "$registry" transcript "$cwd" no-such-session >/dev/null 2>&1; then
  bad "registry transcript exited 0 for a session no harness has"
else
  ok "registry transcript exits non-zero for a session no harness has"
fi

# Codex and OpenCode list the same records; the record says whose it is.
export FOREMAN_DEFAULT_HARNESS=codex FOREMAN_HARNESSES="codex opencode"
shared="$(spawn_on opencode shared)" || bad "opencode spawn failed"
same "resume of an OpenCode agent in the registry Codex shares reaches OpenCode" \
  "$shared" "$(resume_through_registry shared 2>&1)"
same "the resumed agent's record names opencode" "opencode" "$(newest_harness shared)"
if "$harness_dir/codex.sh" resume --name shared --cwd "$cwd" --prompt-file "$prompt" \
    --skip-permissions >/dev/null 2>&1; then
  bad "codex.sh resumed an agent OpenCode spawned"
else
  ok "codex.sh refuses to resume an agent OpenCode spawned"
fi

exit "$fail"
