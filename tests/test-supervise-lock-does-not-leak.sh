#!/usr/bin/env bash
# supervise.sh's own concurrency lock (fd 9 on $SUPERVISE_LOCK, which defaults to
# $FOREMAN_HOME/supervise.lock -- machine-level, because one tick serves every
# board) must
# not leak into the agent it spawns.
#
# `exec 9>"$SUPERVISE_LOCK"` opens fd 9 in supervise.sh's own
# process; bash does not mark it close-on-exec. `start_agent()` then runs
# `claude --bg ...` -- which returns as soon as the agent is SPAWNED, not when
# it finishes, per this script's own header comment -- so the fd (and the
# flock riding on it) is inherited not just by that immediate `claude`
# process but by the DETACHED agent it spawns, which keeps running for hours
# after supervise.sh has exited. Left open, every supervise.sh fire after the
# first sees `flock -n 9` fail against a lock nothing but a stale, unrelated
# background process is holding, logs "another supervisor holds the lock" and
# stands down forever -- a watchdog that silently stops working after its own
# first successful start.
#
# Proved by making the stub `claude --bg` fork a background process that
# outlives it (standing in for the detached agent) and checking, once
# supervise.sh's own process has exited, whether that background process is
# STILL holding the flock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"
withlock="$repo_root/skills/board/withlock.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
git -C "$fixture_repo" init -q -b main
fixture_board_toml "$fixture_repo"

home="$work_dir/home"
fixture_add_instance "$home" demo "$fixture_repo"
board_home="$work_dir/board-home"

marker="$work_dir/bg-agent-started"
holder_log="$work_dir/bg-agent.log"
name_log="$work_dir/agent-name.log"
: >"$name_log"

# `agents` ANSWERS FOR THE NAME IT WAS JUST GIVEN. The harness adapter spawns
# with `--bg` and then asks the registry for that name's session id, so a stub
# that always printed `[]` made the spawn die at "it never registered" -- and
# supervise.sh takes that as its own failure, before this file has measured
# anything about fd 9.
mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then
  if [[ -s "$name_log" ]]; then
    printf '[{"name":"%s","id":"stub-tick","sessionId":"stub-session","pid":1,"state":"idle","startedAt":1,"cwd":"","status":"running"}]\n' \\
      "\$(cat "$name_log")"
  else
    echo '[]'
  fi
  exit 0
fi
if [[ "\$1" == "--bg" ]]; then
  prev=""
  for arg in "\$@"; do
    if [[ "\$prev" == "--name" ]]; then printf '%s\n' "\$arg" >"$name_log"; fi
    prev="\$arg"
  done
  # Simulate the detached agent claude --bg spawns: a background process that
  # outlives this stub's own return, inheriting whatever fds this process has
  # open. It holds fd 9 open (a bare no-op write) for as long as it can, so a
  # fresh attempt to flock the SAME lockfile can observe whether it is busy.
  #
  # Its own stdout/stderr are redirected to /dev/null, deliberately: left
  # inherited, they would still point at the pipe behind the test's own
  # \$(supervise.sh 2>&1) capture, and a background job holding THAT pipe
  # open blocks the capture until the job exits -- a real and separate leak,
  # but not the one this file is about, and it would swallow the timing this
  # test depends on.
  ( : >"$marker"
    { : >&9; } 2>/dev/null && echo "fd9-open" >>"$holder_log" || echo "fd9-closed" >>"$holder_log"
    sleep 6 ) </dev/null >/dev/null 2>&1 &
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

# FOREMAN_HOME is named explicitly. config.sh no longer derives it from $HOME:
# it asks bin/installation.py, which reads the home as the parent of this
# clone. An explicit home is what that derivation yields to, and it is how this
# file stays pointed at its temporary directory.
run_out="$(HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
  SUPERVISE_LOCK="$board_home/supervise.lock" "$supervise" 2>&1)" \
  || { bad "supervise.sh exited non-zero: $run_out"; exit "$fail"; }
grep -q "started foreman/claude/tick" <<<"$run_out" \
  || bad "supervise.sh did not report starting the tick agent: $run_out"

# The real-world symptom, checked FIRST and time-critical: the stub's
# background process (standing in for the detached agent) holds fd 9 for up
# to 6 seconds if it inherited it. A fresh flock attempt with a timeout well
# under that must fail while it is still leaked, and succeed immediately once
# the fix closes the fd before `claude` is even exec'd.
lockfile="$board_home/supervise.lock"
if "$withlock" "$lockfile" 3 -- true; then
  ok "the supervise.lock lockfile is free once supervise.sh's own process has exited"
else
  bad "the supervise.lock lockfile is still held after supervise.sh exited -- a stale background process is holding it"
fi

# Wait for the stub's background process to have actually run its fd-9 probe,
# for the second, more direct assertion below.
for _ in $(seq 1 50); do
  [[ -s "$holder_log" ]] && break
  sleep 0.05
done
[[ -s "$holder_log" ]] || bad "the stubbed detached agent never ran its fd-9 probe"

if grep -q "fd9-open" "$holder_log"; then
  bad "the detached agent inherited fd 9 -- it can still hold supervise.sh's own lock: $(cat "$holder_log")"
else
  ok "the detached agent does not inherit fd 9"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: supervise.sh does not leak its lock fd into the agent it spawns\n'
exit "$fail"
