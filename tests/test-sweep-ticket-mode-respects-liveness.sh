#!/usr/bin/env bash
# Ticket-mode sweep (`sweep.sh <TICKET...>`) used to delete worktrees with no
# liveness check at all -- unlike `--orphans`, which reads `claude agents` and
# refuses to touch any tree that is a non-"stopped" agent's cwd, because
# deleting a live agent's working directory "destroys unpushed work and kills
# it with no diagnosable error" while leaving a dead one costs only disk.
# SKILL.md only ever calls ticket-mode sweep on tickets it just judged
# terminal, so this is defense-in-depth for when that judgment was stale,
# raced, or wrong -- exactly the same judgment `--orphans` already defends
# against, applied to the same class of call.
#
# Measured 2026-09-23 on Claude Code 2.1.280: a finished agent EXITS, so a
# "stopped" row is already exited (pid null, state not "working"). Ticket
# mode now forgets it through the adapter -- `claude rm` for this harness --
# rather than waiting for a `stopped` it will never see arrive a second time.
# The stub below answers `rm` for real, by dropping the row from a state
# file, so a forget that did not actually happen cannot pass this test.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"
sweep="$board_dir/sweep.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

fixture="$work_dir/target"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
fixture_board_toml "$fixture"

home="$work_dir/home"
fixture_add_instance "$home" alpha "$fixture"

# The fixture home declares no installation.toml, so bin/installation.py reads
# it as the lone Claude installation with legacy names: no installation
# segment in any worktree or agent name.
live_wt="$fixture/.claude/worktrees/foreman-alpha-PRA-1"
dead_wt="$fixture/.claude/worktrees/foreman-alpha-PRA-2"
mkdir -p "$live_wt" "$dead_wt"

# PRA-1's build agent is still "working" (a pid, no session id needed for
# that classification); PRA-2's is "stopped" -- pid null, which on 2.1.280 is
# already exited, not merely idle.
stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
state_file="$stub_dir/agents.json"

write_state() { # <json>
  printf '%s' "$1" >"$state_file"
}

write_state '[
  {"id": "sess-PRA-1", "name": "foreman/alpha/PRA-1/build-1", "sessionId": "sess-PRA-1", "state": "working", "pid": 111, "cwd": "'"$live_wt"'"},
  {"id": "sess-PRA-2", "name": "foreman/alpha/PRA-2/build-1", "sessionId": "sess-PRA-2", "state": "stopped", "pid": null, "cwd": "'"$dead_wt"'"}
]'

# One stub, driven by a state file on disk rather than a second fixed
# heredoc: `rm <id>` actually removes that row, so a sweep that only THINKS
# it forgot a session (but never called the adapter's `rm`) fails here
# instead of coincidentally passing because the next heredoc was already
# empty. Every other argv -- `agents --json --all`, in particular -- prints
# whatever is currently in the file.
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
state="$(dirname "$0")/agents.json"
case "$1" in
  rm)
    python3 - "$2" "$state" <<'PY'
import json, sys
target, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    rows = json.load(f)
rows = [r for r in rows if r.get("id") != target]
with open(path, "w") as f:
    json.dump(rows, f)
PY
    printf 'removed %s\n' "$2"
    ;;
  stop)
    # Matches the measurement: a stop changes nothing in the registry,
    # whether the row has a pid or not.
    printf 'stopped %s\n' "$2"
    ;;
  *)
    cat "$state"
    ;;
esac
STUB
chmod +x "$stub_dir/claude"

# FOREMAN_HOME is named explicitly. config.sh no longer derives it from $HOME:
# it asks bin/installation.py, which reads the home as the parent of this
# clone. An explicit home is what that derivation yields to, and it is how this
# file stays pointed at its temporary directory.
out="$(HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha \
  PATH="$stub_dir:$PATH" "$sweep" PRA-1 PRA-2 2>&1)" \
  || { bad "sweep.sh PRA-1 PRA-2 exited non-zero: $out"; exit "$fail"; }

if [[ -d "$live_wt" ]]; then
  ok "ticket-mode sweep leaves a worktree alone while its agent is not stopped"
else
  bad "ticket-mode sweep removed PRA-1's worktree while its build agent was still \"working\""
fi

if [[ ! -d "$dead_wt" ]]; then
  ok "ticket-mode sweep still reaps a ticket whose agent has actually stopped, in the same invocation"
else
  bad "ticket-mode sweep left PRA-2's worktree behind even though its agent was stopped: $out"
fi

grep -qi "PRA-1" <<<"$out" || bad "sweep.sh said nothing about skipping the live PRA-1 worktree: $out"

# A second sweep, once the agent has actually stopped (pid gone, so it is now
# exited too), must forget it through the same `rm` verb and reap it. The
# stub script is unchanged -- only the state file moves, the same way the
# real registry would report the same row differently a tick later.
write_state '[
  {"id": "sess-PRA-1", "name": "foreman/alpha/PRA-1/build-1", "sessionId": "sess-PRA-1", "state": "stopped", "pid": null, "cwd": "'"$live_wt"'"}
]'
out2="$(HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha \
  PATH="$stub_dir:$PATH" "$sweep" PRA-1 2>&1)" \
  || { bad "second sweep of PRA-1 exited non-zero: $out2"; exit "$fail"; }
if [[ ! -d "$live_wt" ]]; then
  ok "a later sweep reaps the worktree once its agent has actually stopped"
else
  bad "PRA-1's worktree still was not reaped once its agent was reported stopped: $out2"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: ticket-mode sweep respects agent liveness the same way --orphans does\n'
exit "$fail"
