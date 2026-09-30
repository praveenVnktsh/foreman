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
# NOT registering is no longer the same as registering. Measured 2026-09-16 on
# Claude Code 2.1.273: a plain `claude --bg` tick did NOT appear in the desktop
# app at all. Running `/remote-control` inside it did, and so did spawning it
# with `claude --bg --remote-control <name>`. So the tick has to ask for Remote
# Control by name at the spawn; leaving the kill switch off is not enough, and a
# tick that merely "keeps" it is invisible. The name is passed explicitly
# because the flag's value is optional: a bare `--remote-control` would take
# whatever argument came next as the session's name.
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

# asks_for_rc <argv file> -- "asks:<name>" when the spawn passes
# `--remote-control` followed by the session's own `--name`, "silent" when it
# passes no `--remote-control` at all, and what went wrong otherwise. The value
# must be the session's name and nothing else: the flag's value is optional, so
# anything else sitting in that slot is an argument it swallowed.
asks_for_rc() {
  python3 - "$1" <<'PY'
import sys
argv = open(sys.argv[1]).read().split("\n")[:-1]
name = next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "--name"), None)
hits = [i for i, a in enumerate(argv) if a == "--remote-control"]
if not hits:
    print("silent"); sys.exit(0)
if len(hits) > 1:
    print("repeated"); sys.exit(0)
i = hits[0]
value = argv[i + 1] if i + 1 < len(argv) - 1 else None  # never the prompt
print("asks:" + value if value is not None and value == name else "swallowed:" + repr(value))
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
  got="$(asks_for_rc "$DISPATCH_ARGV_LOG")"
  [[ "$got" == silent ]] \
    && ok "$desc, and does not ask for Remote Control" \
    || bad "$desc, but it asks for Remote Control: $got"
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
# A fresh monitor.stamp. dispatch.sh (Task 4) refuses to dispatch while any
# board's Monitor stamp is stale or missing, and this file is testing Remote
# Control registration, not that gate.
fixture_arm_monitor "$home/.foreman" demo
tick_argv="$work/tick-argv"; registry="$work/registry.json"
printf '[]\n' >"$registry"
mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then cat "$registry"; exit 0; fi
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$@" >"$tick_argv"
  # The adapter reads the session id back by name after it spawns, so the row
  # carries the name it was given and a session id.
  name=""; prev=""
  for a in "\$@"; do [[ "\$prev" == "--name" ]] && name="\$a"; prev="\$a"; done
  printf '[{"id":"tick-1","name":"%s","state":"working","pid":4242,"startedAt":%s,"cwd":"","sessionId":"tick-sid"}]\n' "\$name" "\$(date +%s)000" >"$registry"
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
  got="$(asks_for_rc "$tick_argv")"
  [[ "$got" == asks:* && "$got" != "asks:" ]] \
    && ok "the tick asks for Remote Control under its own name, so every restart is visible" \
    || bad "tick does not ask for Remote Control under its own name: $got"
else
  bad "supervise.sh never reached claude --bg: $(cat "$work/supervise.log")"
fi

exit "$fail"
