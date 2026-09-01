#!/usr/bin/env bash
# sweep.sh must hold `$REPO/.git/board-worktree.lock` for the ACTUAL worktree
# mutation, not merely check that it is free and let go before touching
# anything.
#
# It used to take the lock around `true`: acquired, `true` ran and exited
# instantly, released -- all before `git worktree remove`/`prune` ran. That
# proved the lockfile was momentarily free at ONE instant, not that the
# mutation itself was serialized against dispatch.sh's own `git worktree add`,
# which takes the SAME lock around ITS mutation. Two processes racing
# `git worktree add` and `git worktree remove`/`prune` on the same
# `.git/worktrees` metadata is exactly what the lock exists to prevent.
#
# A timing race (hold the lock externally, see if sweep.sh waits) does not
# distinguish the old code from the new: the old code's own `withlock.py --
# true` check ALSO contends for the lock and so ALSO waits out an external
# holder, even though the mutation that follows is unprotected. What actually
# differs is whether the lock is held DURING `git worktree remove`/`prune`
# itself -- so this stubs `git` to check, at the exact moment sweep.sh invokes
# a worktree-mutating subcommand, whether a FRESH file descriptor on the
# lockfile can take it. flock(2): a new fd on the same file is denied by a
# lock a process (or its parent) already holds on another fd, even within one
# process tree -- so if sweep.sh's own ancestor (withlock.py) is holding the
# lock at that moment, this stub's own attempt is denied ("held"); if the
# lock was already released before the mutation ran, it succeeds ("free").
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"
sweep="$board_dir/sweep.sh"
real_git="$(command -v git)"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

fixture="$work_dir/target"
mkdir -p "$fixture"
"$real_git" -C "$fixture" init -q -b main
fixture_board_toml "$fixture"

home="$work_dir/home"
fixture_add_instance "$home" alpha "$fixture"

wt="$fixture/.claude/worktrees/foreman-alpha-PRA-1"
mkdir -p "$wt"

lockfile="$fixture/.git/board-worktree.lock"
lockstate_log="$work_dir/lockstate.log"
: >"$lockstate_log"

stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*|*" worktree prune "*)
    python3 - "$lockfile" "$lockstate_log" <<'PY'
import fcntl, os, sys
lockfile, log = sys.argv[1], sys.argv[2]
fd = os.open(lockfile, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(fd, fcntl.LOCK_UN)
    state = "free"
except OSError:
    state = "held"
finally:
    os.close(fd)
with open(log, "a") as f:
    f.write(state + "\n")
PY
    ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stub_dir/git"

# sweep.sh asks `claude agents --json --all` which cards still have a live agent,
# and refuses to sweep anything if it cannot read that list. Without a stub this
# test passes on a developer's machine, where the real binary happens to be on
# PATH, and fails in CI, where it is not -- which is exactly what it did.
# Stubbed at the external boundary, like every other sweep test here.
cat >"$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
STUB
chmod +x "$stub_dir/claude"

sweep_out="$work_dir/sweep.out"
if ! HOME="$home" FOREMAN_INSTANCE=alpha PATH="$stub_dir:$PATH" "$sweep" PRA-1 \
    >"$sweep_out" 2>&1; then
  bad "sweep.sh PRA-1 exited non-zero: $(cat "$sweep_out")"
fi

[[ -d "$wt" ]] && bad "sweep.sh did not remove the worktree at all: $(cat "$sweep_out")"

observed="$(cat "$lockstate_log")"
if [[ -z "$observed" ]]; then
  bad "the git stub was never invoked for worktree remove/prune -- test fixture is broken"
elif [[ "$observed" == *held* && "$observed" != *free* ]]; then
  ok "the worktree lock is held for every worktree-mutating git call sweep.sh makes"
else
  bad "at least one worktree-mutating git call ran with the lock FREE -- the mutation is not actually protected (observed: $(tr '\n' ' ' < "$lockstate_log"))"
fi


# The old code reported EVERY withlock failure as "repository lock is held",
# because the only thing it ever ran under the lock was `true`, which cannot
# fail. Re-executing the whole script under the lock means a real failure
# inside (not lock contention) can now happen there too, and it must be
# reported as itself -- not relabeled "lock is held", which would send an
# operator looking for a contending process that does not exist.
usage_out="$(HOME="$home" FOREMAN_INSTANCE=alpha "$sweep" 2>&1)" && \
  bad "sweep.sh with no arguments should refuse (usage error), not succeed"
case "$usage_out" in
  *"usage: sweep.sh"*) ok "a real failure inside the lock is reported as itself, not as \"lock is held\"" ;;
  *"lock is held"*) bad "a plain usage error was misreported as \"repository lock is held\": $usage_out" ;;
  *) bad "unexpected error for a no-argument invocation: $usage_out" ;;
esac

[[ "$fail" -eq 0 ]] && printf 'PASS: sweep.sh holds the worktree lock across its actual mutation\n'
exit "$fail"
