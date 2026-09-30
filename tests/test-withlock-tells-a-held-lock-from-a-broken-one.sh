#!/usr/bin/env bash
# Claim: withlock.py exits 75 only when another holder has the lock, exits 71
# when the lock cannot be taken at all, and keeps the lock until the command it
# guards has exited, even when it is sent SIGTERM.
#
# Every OSError from flock used to read as "busy". A lock that could never work
# -- a bad fd, a filesystem without flock -- then looked like a contended one,
# and supervise.sh's run mode answers "busy" by standing down: a watchdog that
# never runs again and always sounds fine. And a SIGTERM killed the wrapper at
# once, so the kernel released the lock while its command was still running,
# and the next caller took it beside that command.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
withlock="$root/skills/board/withlock.py"
work="$(mktemp -d)"
pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
lock="$work/the.lock"

# Wait up to ~5s for <file> to exist.
await() { local i; for i in $(seq 1 50); do [[ -e "$1" ]] && return 0; sleep 0.1; done; return 1; }

# --- a held lock is busy: 75 --------------------------------------------------
"$withlock" "$lock" 30 -- bash -c ": >'$work/held'; sleep 30" &
pids="$pids $!"
await "$work/held" || bad "the first holder never took the lock"
"$withlock" "$lock" 0.5 -- true 2>/dev/null
rc=$?
[[ "$rc" -eq 75 ]] && ok "a lock another process holds exits 75" || bad "a held lock exited $rc, not 75"
"$withlock" --fd 9 "$lock" 0.5 9>>"$lock" 2>/dev/null
rc=$?
[[ "$rc" -eq 75 ]] && ok "--fd on a held lock exits 75" || bad "--fd on a held lock exited $rc, not 75"
for p in $pids; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; pids=""

# --- a lock that cannot work is not busy: 71 ----------------------------------
# fd 9 is not open in the child, so flock fails with EBADF.
exec 9>&-
err="$("$withlock" --fd 9 "$lock" 0.5 2>&1)"
rc=$?
[[ "$rc" -eq 71 ]] && ok "a lock that cannot be taken at all exits 71" \
  || bad "a broken lock exited $rc, not 71: $err"
grep -q 'cannot lock' <<<"$err" && ok "and says so" || bad "the broken lock said: $err"

# --- --fd leaves the lock held by the caller's fd -----------------------------
(
  exec 9>>"$lock"
  "$withlock" --fd 9 "$lock" 5 || exit 1
  : >"$work/fd-held"
  sleep 3
) &
pids="$pids $!"
await "$work/fd-held" || bad "the --fd holder never took the lock"
"$withlock" "$lock" 0.5 -- true 2>/dev/null
rc=$?
[[ "$rc" -eq 75 ]] && ok "--fd keeps the lock after withlock.py itself exits" \
  || bad "the lock was free while the --fd caller still held its fd (exit $rc)"
for p in $pids; do wait "$p" 2>/dev/null; done; pids=""

# --- SIGTERM reaches the command, and the lock outlives it until it exits ----
cat >"$work/slow-to-stop.sh" <<SH
#!/usr/bin/env bash
trap 'echo term >"$work/child-got-term"; sleep 2; echo done >"$work/child-done"; exit 0' TERM
: >"$work/child-started"
# Bounded, so a wrapper that drops the signal fails this test instead of
# leaving the command running and the test hanging on it.
for _ in \$(seq 1 100); do sleep 0.1; done
SH
chmod +x "$work/slow-to-stop.sh"
"$withlock" "$lock" 5 -- "$work/slow-to-stop.sh" &
wrapper=$!
pids="$pids $wrapper"
await "$work/child-started" || bad "the guarded command never started"
kill -TERM "$wrapper"
await "$work/child-got-term" && ok "SIGTERM to withlock.py reaches the command it guards" \
  || bad "the guarded command never saw the SIGTERM"
"$withlock" "$lock" 0.5 -- true 2>/dev/null
rc=$?
if [[ -e "$work/child-done" ]]; then
  bad "the guarded command finished too early to tell"
elif [[ "$rc" -eq 75 ]]; then
  ok "the lock stays held while the command is still stopping"
else
  bad "the lock was free while the command it guards was still running (exit $rc)"
fi
wait "$wrapper" 2>/dev/null; pids=""
[[ -e "$work/child-done" ]] && ok "withlock.py waits for the command to exit" \
  || bad "withlock.py exited before the command it guards"

[[ "$fail" -eq 0 ]] && printf 'PASS: withlock tells a held lock from a broken one\n'
exit "$fail"
