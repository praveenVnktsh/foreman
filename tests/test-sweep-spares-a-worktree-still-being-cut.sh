#!/usr/bin/env bash
# Claim: `sweep.sh --orphans` leaves a worktree whose dispatch is still running,
# before its agent has registered, and reaps it once that dispatch is gone.
#
# A sweep keeps a worktree only while a registered agent uses it. dispatch.sh
# cuts the worktree, runs the target's bootstrap -- minutes, for a real
# dependency install -- and only then spawns the agent that registers. A sweep
# in that window read the tree as an orphan and deleted it under the dispatch.
# dispatch.sh now holds a marker naming the worktree and its own pid
# (config.sh's dispatch_marker_for), and the sweep keeps the tree while that pid
# lives.
#
# The sweep runs FROM the bootstrap, so it lands in exactly that window. The
# bootstrap then fails if its worktree is gone, which refuses the dispatch.
# `claude` is the only external boundary stubbed (tests/lib/dispatch-fixture.sh);
# its registry is empty until the spawn, as the real one is.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
holder=""
trap '[[ -z "$holder" ]] || kill "$holder" 2>/dev/null; rm -rf "$work_dir"' EXIT
dispatch_fixture_setup "$work_dir" "$repo_root"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$(git -C "$work_dir/target" rev-parse --show-toplevel)"
sweep_out="$work_dir/sweep.out"
cat >>"$target/board.toml" <<TOML
[bootstrap]
command = "bash '$repo_root/skills/board/sweep.sh' --orphans >'$sweep_out' 2>&1; echo sweep-exit=\$? >>'$sweep_out'; test -d \"\$PWD/.\""
TOML

dispatch_fixture_run --ticket MRK-1 --role build --attempt 1
grep -q 'sweep-exit=0' "$sweep_out" 2>/dev/null && ok "the sweep ran inside the bootstrap" \
  || { bad "the sweep inside the bootstrap did not run cleanly: $(cat "$sweep_out" 2>&1)"; dispatch_fixture_show_run_log; }
grep -q 'foreman-demo-MRK-1' "$sweep_out" 2>/dev/null \
  && bad "the sweep inside the bootstrap touched the worktree being cut: $(cat "$sweep_out")" \
  || ok "a sweep during the bootstrap leaves the worktree its dispatch is cutting"
[[ -s "$DISPATCH_ARGV_LOG" ]] && ok "and the dispatch goes on to spawn in it" \
  || { bad "the dispatch did not reach its spawn"; dispatch_fixture_show_run_log; }

markers="$DISPATCH_HOME/.foreman/instances/demo/dispatching"
[[ -z "$(ls -A "$markers" 2>/dev/null)" ]] && ok "the dispatch removes its marker when it ends" \
  || bad "the dispatch left a marker behind: $(ls -A "$markers")"

# A dispatch killed mid-bootstrap leaves its marker naming a dead pid. That
# protects nothing: the worktree is an orphan and goes, and so does the marker.
tree="$target/.claude/worktrees/foreman-demo-MRK-2"
mkdir -p "$tree" "$markers"
sleep 60 &
holder=$!
printf '%s\n' "$holder" >"$markers/foreman-demo-MRK-2"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
env HOME="$DISPATCH_HOME" FOREMAN_HOME="$DISPATCH_HOME/.foreman" FOREMAN_INSTANCE=demo \
  PATH="$_DISPATCH_STUB_BIN:$PATH" bash "$repo_root/skills/board/sweep.sh" --orphans >"$sweep_out" 2>&1 \
  || bad "the sweep exited non-zero: $(cat "$sweep_out")"
[[ ! -d "$tree" ]] && ok "a worktree whose dispatch died is reaped" \
  || bad "the worktree outlived its dead dispatch: $(cat "$sweep_out")"
[[ ! -e "$markers/foreman-demo-MRK-2" ]] && ok "and the dead dispatch's marker goes with it" \
  || bad "a marker naming a dead pid was left behind"

[[ "$fail" -eq 0 ]] && printf 'PASS: the sweep spares a worktree its dispatch is still cutting\n'
exit "$fail"
