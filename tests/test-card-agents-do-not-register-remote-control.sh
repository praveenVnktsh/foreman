#!/usr/bin/env bash
# Claim: a dispatched card agent does not register a Remote Control session,
# and the tick still does.
#
# A `claude --bg` session registers a Remote Control session with the
# operator's claude.ai account, and that registration outlives the process.
# Measured 2026-09-14 on Claude Code 2.1.270: every agent one board had ever
# spawned, 932 of them, was still listed in the desktop app as "Remote Control
# · offline" after its process, its `~/.claude/jobs` record and its transcript
# were all gone. No command, setting or API removes one, and sweep.sh cannot
# reach it, so the registration has to not happen -- at the spawn, through
# config.sh's CARD_AGENT_SETTINGS on each `claude --bg` line dispatch.sh has.
#
# The tick is the exception on purpose: it is the one session worth attaching
# to from a phone, and one row that restarts rarely. A card is three to six
# rows per build, and those are what filled the list.
#
# The prompt is checked too. Every spawn line documents that ORDER IS
# LOAD-BEARING: a variadic flag placed before the prompt eats it. `--settings`
# takes exactly one value, and this is what keeps that true the day someone
# reorders the flags.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# remote_control <argv file> -- one word: "disabled", "enabled" (no setting
# turns it off), or what went wrong; and a second word saying whether the last
# argument is still the prompt.
remote_control() {
  python3 - "$1" "$2" <<'PY'
import json, sys
argv = open(sys.argv[1]).read().split("\n")[:-1]
if not argv:
    print("never-spawned"); sys.exit(0)
verdict = "enabled"
for i, a in enumerate(argv[:-1]):
    if a != "--settings":
        continue
    try:
        settings = json.loads(argv[i + 1])
    except ValueError:
        verdict = "unparseable"; break
    if settings.get("disableRemoteControl") is True:
        verdict = "disabled"
print(verdict, "prompt-last" if argv[-1] == sys.argv[2] else "prompt-lost:" + repr(argv[-1]))
PY
}

# --- dispatched agents, through the real dispatch.sh -------------------------
dispatch_fixture_setup "$work" "$repo_root"
prompt="$(cat "$DISPATCH_PROMPT")"

check_dispatch() { # <description> <dispatch.sh args...>
  local desc="$1"; shift
  dispatch_fixture_run "$@"
  local got
  got="$(remote_control "$DISPATCH_ARGV_LOG" "$prompt")"
  if [[ "$got" == "disabled prompt-last" ]]; then
    ok "$desc"
  else
    bad "$desc: $got"
    [[ "$got" == never-spawned* ]] && dispatch_fixture_show_run_log
  fi
}
check_dispatch "a plan agent is spawned with Remote Control disabled" \
  --ticket PRA-1 --role plan --attempt 1
check_dispatch "a build agent is spawned with Remote Control disabled" \
  --ticket PRA-2 --role build --attempt 1
check_dispatch "a review agent is spawned with Remote Control disabled" \
  --ticket PRA-3 --role review --attempt 1 --slot a --ref "$DISPATCH_SEED_SHA"

# --- the tick, through the real supervise.sh -----------------------------------
#
# Its own fixture: supervise.sh reads the registry to decide whether to start
# a tick, and a stub that answers `[]` until a `--bg` has happened, then a live
# tick, is what lets run mode start exactly one and return.
home="$work/tick-home"; target="$work/tick-target"
mkdir -p "$target"
git -C "$target" init -q -b main
fixture_board_toml "$target"
fixture_add_board "$home" demo "$target"
tick_argv="$work/tick-argv"; registry="$work/registry.json"
printf '[]\n' >"$registry"
mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then cat "$registry"; exit 0; fi
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$@" >"$tick_argv"
  printf '[{"id":"tick-1","name":"foreman/tick","state":"working","startedAt":%s,"cwd":"","sessionId":""}]\n' "\$(date +%s)000" >"$registry"
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$home/.local/bin:$PATH" SUPERVISE_LOCK="$work/supervise.lock" \
    TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=1 \
    TICK_LOCK_WAIT_SECONDS=2 \
    "$repo_root/skills/board/supervise.sh" >"$work/supervise.log" 2>&1 || true

if [[ -s "$tick_argv" ]]; then
  got="$(remote_control "$tick_argv" "$(tail -n1 "$tick_argv")")"
  [[ "$got" == "enabled prompt-last" ]] \
    && ok "the tick keeps Remote Control, so the operator can still attach to the board" \
    || bad "tick: $got"
else
  bad "supervise.sh never reached claude --bg: $(cat "$work/supervise.log")"
fi

exit "$fail"
