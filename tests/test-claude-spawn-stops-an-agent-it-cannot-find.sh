#!/bin/bash
# Claim: claude.sh spawn stops the agent `claude --bg` started when it cannot
# find that agent in the registry, and waits out a registry that lags.
#
# The failure it prevents: spawn ran `claude --bg`, then read `claude agents`
# once. A failed read or a row not listed yet killed the spawn with the agent
# already running in the worktree. dispatch.sh then moved on to the next
# candidate or attempt and removed that worktree from under a live agent.
# codex.sh and opencode.sh already stopped theirs before dying.
#
# `claude` is the one thing stubbed: a script that prints the id `--bg` prints,
# answers `agents` as the case needs, and records every `stop`.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
adapter="$root/skills/board/harness/claude.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

mkdir -p "$work/bin" "$work/cwd"
calls="$work/calls"
# How `agents` answers: fail (exit 1), empty ([]), or lag (fails twice, then
# lists the agent).
mode="$work/mode"
cat >"$work/bin/claude" <<STUB
#!/bin/bash
case "\$1" in
  --bg) printf 'agent-77\n' ;;
  agents)
    reads="\$(cat "$work/reads" 2>/dev/null || echo 0)"
    echo \$(( reads + 1 )) >"$work/reads"
    case "\$(cat "$mode")" in
      fail) exit 1 ;;
      empty) echo '[]' ;;
      lag)
        [ "\$reads" -ge 2 ] || exit 1
        echo '[{"name":"probe","id":"agent-77","sessionId":"session-77","pid":42,"state":"working","startedAt":1,"cwd":"/","status":null}]' ;;
    esac ;;
  stop) printf 'stop %s\n' "\$2" >>"$calls" ;;
esac
STUB
chmod +x "$work/bin/claude"
export PATH="$work/bin:$PATH"
prompt="$work/prompt.md"
echo "do the thing" >"$prompt"

spawn() {
  : >"$calls"
  rm -f "$work/reads"
  "$adapter" spawn --name probe --cwd "$work/cwd" --model m --prompt-file "$prompt" --skip-permissions 2>/dev/null
}

for case_mode in fail empty; do
  echo "$case_mode" >"$mode"
  if spawn >/dev/null; then
    bad "spawn with a registry that answers '$case_mode' exited 0"
  elif grep -qx 'stop agent-77' "$calls"; then
    ok "spawn that cannot find its agent ($case_mode registry) stops it before dying"
  else
    bad "spawn with a '$case_mode' registry died without stopping agent-77"
  fi
done

echo lag >"$mode"
session="$(spawn)"
if [[ "$session" == session-77 && ! -s "$calls" ]]; then
  ok "spawn waits out a registry that lags and stops nothing"
else
  bad "spawn with a lagging registry printed '$session' and called: $(cat "$calls")"
fi

exit "$fail"
