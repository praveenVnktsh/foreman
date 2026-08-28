#!/usr/bin/env bash
# `sweep.sh` reaps the `refs/board/evidence/<pid>` refs nothing else touches.
#
# `evidence.sh` fetches into a ref private to its own process and deletes it
# before it reads the blob, so the happy path leaves nothing. The gap is a kill
# between those two, and the window is the fetch -- the slow part -- so it is
# the ordinary way an evidence read dies rather than a rare interleaving:
# `claude stop` on a stalled tick, or the tick's own budget expiring.
#
# `evidence.sh` traps HUP, INT and TERM for that, which leaves SIGKILL, and
# SIGKILL cannot be trapped. Nothing else in the board reaps that namespace --
# `sweep.sh` handled worktrees and board branches, `dispatch.sh` prunes
# worktrees, `git fetch --prune` prunes `refs/remotes/` -- so a leaked ref was
# permanent, and it pins every object its fetch brought with it, `git gc
# --prune=now` included.
#
# What is pinned here:
#
#   1. a ref whose pid is dead is deleted
#   2. a ref whose pid is ALIVE is not -- that is a read in flight, and deleting
#      its ref mid-fetch would break the answer it is about to give
#   3. a ref that is not named for a pid at all goes: no process can be asked
#      about it, so nothing can ever claim it
#   4. `BOARD_DRY_RUN` says what it would do and deletes nothing
#   5. a reap that cannot ENUMERATE the namespace says so and exits non-zero,
#      in a dry run too -- this is the last defence against the leak, and a
#      swallowed failure makes "nothing leaked" and "I could not tell" the same
#      output while the leak persists forever
#   6. a reap that cannot DELETE one ref says which, reaps the rest anyway, and
#      still exits non-zero
#
# Runs in CI's Operations job, which globs `ops/tests/*.sh` against a full
# checkout. Not part of `just test-all`, so the `.claude/` path it needs is
# never asked of mango's live checkout, which deliberately has none.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
board_dir="$repo_root/.claude/skills/board"
sweep_stem="sweep"
sweep="$board_dir/$sweep_stem.sh"

[[ -x "$sweep" ]] || {
  echo "FAIL: $sweep is missing or not executable" >&2
  exit 1
}

# See design/build_system.md, invariant 10: scratch is asked of ops/tmp-dir.sh.
tmp_root="$("$repo_root/ops/tmp-dir.sh")"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git_q() {
  git -c user.name="Sweep Test" -c user.email="sweep-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# `config.sh` asks `$REPO/ops/tmp-dir.sh` for the scratch root, so the fixture
# has to be shaped enough like this repository to answer that. The real script
# is copied in rather than stubbed, so this does not become a second derivation
# of the path `ops/tests/test-tmp-dir.sh` exists to keep singular.
fixture="$work_dir/repo"
git_q init -q -b main "$fixture"
mkdir -p "$fixture/ops"
cp "$repo_root/ops/tmp-dir.sh" "$fixture/ops/tmp-dir.sh"
chmod +x "$fixture/ops/tmp-dir.sh"
echo "seed" > "$fixture/file.txt"
git_q -C "$fixture" add file.txt ops/tmp-dir.sh
git_q -C "$fixture" commit -q -m "Seed"
sha="$(git -C "$fixture" rev-parse HEAD)"

# `--orphans` reads the live agent list before it touches anything, and refuses
# outright if it cannot. An empty list is the shape of "nothing is running",
# which is what makes this fixture a sweep with no worktrees to reap.
stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
STUB
chmod +x "$stub_dir/claude"

# The ref the `delete` failure mode refuses to remove. Named for no pid, so the
# reap treats it as reapable and actually attempts the delete.
wedged_ref="wedged"

# A `git` that is the real one, except where the test asks it to fail. Failing
# for real would mean a chmod on the ref directory, which does nothing when the
# suite runs as root -- and CI's container does. `SWEEP_TEST_FAIL` picks which
# of the two calls inside the reap breaks; while it is unset -- which is every
# section that does not set it -- this is plain git.
real_git="$(command -v git)"
cat > "$stub_dir/git" <<STUB
#!/usr/bin/env bash
args="\$*"
if [[ "\${SWEEP_TEST_FAIL:-}" == enumerate && "\$args" == *"for-each-ref"*"refs/board/evidence/"* ]]; then
  echo "fatal: simulated failure listing refs/board/evidence" >&2
  exit 128
fi
if [[ "\${SWEEP_TEST_FAIL:-}" == delete && "\$args" == *"update-ref -d refs/board/evidence/$wedged_ref"* ]]; then
  echo "fatal: simulated failure deleting $wedged_ref" >&2
  exit 128
fi
exec $real_git "\$@"
STUB
chmod +x "$stub_dir/git"

# A pid that is definitely gone: started, waited for, and never signalled again.
sleep 0 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
# ...and one that is definitely alive, because it is this test.
live_pid=$$

plant_refs() {
  git -C "$fixture" update-ref "refs/board/evidence/$dead_pid" "$sha"
  git -C "$fixture" update-ref "refs/board/evidence/$live_pid" "$sha"
  git -C "$fixture" update-ref "refs/board/evidence/not-a-pid" "$sha"
}

surviving_refs() {
  git -C "$fixture" for-each-ref --format='%(refname)' 'refs/board/evidence/*'
}

run_sweep() {
  REPO="$fixture" BOARD_HOME="$work_dir/board-home" PATH="$stub_dir:$PATH" \
    "$sweep" --orphans
}

# --- 1. a dry run deletes nothing and says what it would do ------------------

plant_refs
out="$(BOARD_DRY_RUN=1 run_sweep)"
[[ "$out" == *"would delete leaked evidence ref refs/board/evidence/$dead_pid"* ]] || {
  fail "a dry run did not name the ref it would reap: [$out]"
}
[[ "$(surviving_refs | wc -l)" == "3" ]] || {
  fail "a dry run deleted something:
$(surviving_refs)"
}
echo "  ok: BOARD_DRY_RUN names the leaked ref and deletes nothing"

# --- 2. the real sweep reaps the dead and spares the living ------------------

out="$(run_sweep)"
survivors="$(surviving_refs)"

[[ "$survivors" == *"refs/board/evidence/$live_pid"* ]] || {
  fail "the sweep deleted the ref of a LIVE read. That read is mid-fetch and
  about to answer a question about the code; taking its ref out from under it
  is worse than the leak this reaper exists for.
survivors: [$survivors]"
}
[[ "$survivors" != *"refs/board/evidence/$dead_pid"* ]] || {
  fail "the leaked ref of a dead read survived the sweep:
$survivors"
}
[[ "$survivors" != *"not-a-pid"* ]] || {
  fail "a ref named for no process survived. Nothing can ever claim it, so
  nothing will ever reap it either:
$survivors"
}
[[ "$out" == *"removed leaked evidence ref refs/board/evidence/$dead_pid"* ]] || {
  fail "the sweep did not say what it reaped: [$out]"
}
echo "  ok: a dead read's ref is reaped, a live one's is left alone"

# --- 3. and it is idempotent -------------------------------------------------

run_sweep >/dev/null
[[ "$(surviving_refs)" == "refs/board/evidence/$live_pid" ]] || {
  fail "a second sweep changed the answer:
$(surviving_refs)"
}
echo "  ok: a second sweep leaves the live ref exactly where it was"

# --- 4. a namespace it cannot even list is an error, not an empty list -------
#
# The reap is the LAST defence against these refs: `evidence.sh` traps HUP, INT
# and TERM, and this is what catches the SIGKILL it cannot. If a failed listing
# reads as "nothing leaked", a permissions problem or a corrupt ref keeps the
# leak forever while every sweep reports success.

plant_refs
set +e
out="$(SWEEP_TEST_FAIL=enumerate run_sweep 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  fail "a sweep that could not list refs/board/evidence/* exited 0. The tick
  reads that as a clean namespace, so the leak it could not see is never
  reported and never reaped:
$out"
}
[[ "$out" == *"could not list refs/board/evidence/*"* ]] || {
  fail "the sweep did not say the listing failed: [$out]"
}
[[ "$(surviving_refs | wc -l)" == "3" ]] || {
  fail "a sweep that could not list the namespace deleted something in it:
$(surviving_refs)"
}

set +e
out="$(BOARD_DRY_RUN=1 SWEEP_TEST_FAIL=enumerate run_sweep 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  fail "a DRY RUN that could not list the namespace exited 0. A dry run is how
  the leak is inspected by hand; reporting nothing there is the same lie:
$out"
}
echo "  ok: a namespace that cannot be listed exits non-zero, dry run included"

# --- 5. a ref it cannot delete is named, and the rest are still reaped -------
#
# The failure is held to the end rather than propagated where it happens: the
# other leaked refs are still worth reaping, and so is the review prune that
# follows, which is unrelated and would otherwise stop running for as long as
# the ref problem lasts.

git -C "$fixture" update-ref "refs/board/evidence/$wedged_ref" "$sha"
plant_refs

stale_review="$work_dir/board-home/cards/PRA-1/reviews/round-1.json"
mkdir -p "$(dirname "$stale_review")"
echo '{}' > "$stale_review"
touch -t 202001010000 "$stale_review"

set +e
out="$(SWEEP_TEST_FAIL=delete run_sweep 2>&1)"
status=$?
set -e
survivors="$(surviving_refs)"

[[ "$status" -ne 0 ]] || {
  fail "a sweep that could not delete a leaked ref exited 0. That ref pins every
  object its fetch brought with it, and nothing will ever say so:
$out"
}
[[ "$out" == *"could not delete leaked evidence ref refs/board/evidence/$wedged_ref"* ]] || {
  fail "the sweep did not name the ref it failed to delete: [$out]"
}
[[ "$survivors" == *"refs/board/evidence/$wedged_ref"* ]] || {
  fail "the ref the delete failed on is gone, so the failure was not real and
  this section proves nothing:
$survivors"
}
[[ "$survivors" != *"refs/board/evidence/$dead_pid"* ]] || {
  fail "one undeletable ref stopped the reap. Every other leak in the namespace
  survives a problem that has nothing to do with it:
$survivors"
}
[[ ! -f "$stale_review" ]] || {
  fail "a failed reap skipped the review prune that follows it. The failure is
  meant to be held to the end precisely so the rest of the sweep still runs."
}
echo "  ok: an undeletable ref is named, the rest are reaped, the sweep still fails"

git -C "$fixture" update-ref -d "refs/board/evidence/$live_pid"
git -C "$fixture" update-ref -d "refs/board/evidence/$wedged_ref"

echo "PASS: the sweep reaps leaked evidence refs, spares reads in flight, and says so when it cannot"
