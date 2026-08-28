#!/usr/bin/env bash
# `preflight.py` touches `origin` only where the answer gates something.
#
# It used to report `behind_origin_main` -- how far this checkout trailed
# `origin/main` -- and to fetch in BOTH modes to compute it. That number was
# added after 2026-08-03, when a tick overruled a `blocking` finding by grepping
# `ops/deploy.sh` in a checkout 169 commits behind, merged, and broke the
# deploy on the target host for half an hour. It never fixed that and could
# not: it measures against `refs/remotes/origin/main`, which is the very ref
# the tick misread.
# `evidence.sh` fixed it, by fetching per read.
#
# What was left was a number with no consumer. `dispatch.sh` reads the exit code
# and discards the JSON, nothing in `.claude/skills/board/` parsed the field, it
# was advisory in both modes, and `SKILL.md` said in terms that no value of it
# licensed reading the working tree. So it bought a `git fetch origin` on every
# heartbeat -- every couple of minutes, against a `.git` shared with every live
# build worktree -- to compute something nobody read and the prose forbade
# acting on. Both are gone.
#
# What is pinned here:
#
#   1. `--quick` runs NO `git` at all. Proven with a stub on PATH that records
#      every invocation, not by reading the verdict -- a check can be deleted
#      from the report while the command it ran stays.
#   2. ...and it is fit anyway with an origin that does not exist, because the
#      heartbeat needs nothing from the network. That is the regression the
#      advisory flag used to paper over, now structural.
#   3. the FULL gate does fetch, and there the fetch GATES: an unreachable
#      origin makes it unfit, because `dispatch.sh` cannot cut a worktree from a
#      ref this machine cannot reach.
#   4. no verdict carries `behind_origin_main`, and no check measures this
#      checkout against `origin/main`. Re-adding either is re-adding a fetch
#      nobody reads; if a consumer ever appears, this case is where to argue it.
#
# This runs against a full checkout, via tests/run-all.sh (Task 9 wires this
# into CI; see docs/plans/2026-08-27-foreman-layer-1.md).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

board_dir="$repo_root/skills/board"
preflight="$board_dir/preflight.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$preflight" ]] || {
  echo "FAIL: $preflight is missing or not executable" >&2
  exit 1
}

# The scratch root is asked of bin/tmp-dir.sh, never worked out here -- see
# bin/tmp-dir.sh's own header for why one derivation has to stay singular.
tmp_root="$("$repo_root/bin/tmp-dir.sh")"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git_q() {
  git -c user.name="Preflight Test" -c user.email="preflight-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# `preflight.py` shells out to config.sh, which since Task 2/3 requires a
# FOREMAN_INSTANCE and an instance directory declaring a REPO whose board.toml
# passes bin/contract.py -- regardless of what REPO is overridden to per call
# below. One fixture instance, reused for every fixture checkout in this file.
inst_home="$work_dir/foreman-home"
fixture_add_instance "$inst_home" fixture

origin="$work_dir/origin.git"
seed="$work_dir/seed"
git_q init -q --bare "$origin"
git_q init -q -b main "$seed"
echo "first" > "$seed/file.txt"
fixture_board_toml "$seed"
git_q -C "$seed" add file.txt board.toml
git_q -C "$seed" commit -q -m "Seed"
git_q -C "$seed" remote add origin "$origin"
git_q -C "$seed" push -q origin main

clone="$work_dir/clone"
git_q clone -q "$origin" "$clone"

# A `git` that writes down what it was asked to do and then does it. This is the
# only way to assert that a mode runs no fetch: the verdict says which checks
# were REPORTED, and a check can be dropped from the report while the command it
# ran stays behind.
shim_dir="$work_dir/shim"
mkdir -p "$shim_dir"
real_git="$(command -v git)"
cat > "$shim_dir/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GIT_SHIM_LOG"
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

# Thresholds are overridden to the smallest thing that still exercises the write
# probe. This harness is about the network, not the disk; a real gigabyte here
# would make the Operations job pay a build's disk cost to prove a fetch.
run_preflight() {
  local mode="$1" repo="$2" out status=0
  # An array rather than an unquoted "$mode", so the full-gate case passes no
  # argument at all instead of relying on word-splitting to erase an empty one.
  local flags=()
  [[ -z "$mode" ]] || flags=("$mode")
  : > "$work_dir/git.log"
  out="$(
    REPO="$repo" HOME="$inst_home" FOREMAN_INSTANCE=fixture \
    PATH="$shim_dir:$PATH" GIT_SHIM_LOG="$work_dir/git.log" \
    QUICK_PROBE_MB=1 PROBE_TMP_MB=1 PROBE_REPO_MB=1 \
    MIN_FREE_TMP_MB=1 MIN_FREE_REPO_MB=1 \
    "$preflight" ${flags[@]+"${flags[@]}"} 2>"$work_dir/preflight.err"
  )" || status=$?
  [[ -n "$out" ]] || {
    echo "  preflight stderr:" >&2
    cat "$work_dir/preflight.err" >&2
    fail "preflight printed no verdict (exit $status)"
  }
  printf '%s' "$out"
}

# Read with python3 rather than grep: the point is that the verdict is
# machine-readable, and a grep would pass on a field that had become a string or
# moved into prose.
verdict_field() {
  local json="$1" expr="$2"
  printf '%s' "$json" | /usr/bin/env python3 -c '
import json
import sys

verdict = json.load(sys.stdin)
checks = {c["name"]: c for c in verdict["checks"]}
print(eval(sys.argv[1], {"v": verdict, "c": checks}))
' "$expr"
}

expect() {
  local want="$1" got="$2" what="$3"
  [[ "$got" == "$want" ]] || fail "$what: expected [$want], got [$got]"
}

# --- 1. the heartbeat runs no git ---------------------------------------------

json="$(run_preflight --quick "$clone")"
if grep -q "fetch" "$work_dir/git.log"; then
  fail "the quick preflight fetched. It runs every couple of minutes against a
  \`.git\` shared with every live build worktree, and the number that fetch used
  to compute is gone -- so this is a network round trip nothing reads.
  git calls: $(cat "$work_dir/git.log")"
fi
[[ ! -s "$work_dir/git.log" ]] || {
  fail "the quick preflight ran git at all: $(cat "$work_dir/git.log")"
}
expect True "$(verdict_field "$json" 'v["fit"]')" \
  "a heartbeat on a healthy disk is fit"
echo "  ok: --quick runs no git, and is fit"

# --- 2. ...and an unreachable origin is not its problem ------------------------
#
# This is the regression the advisory flag used to hold off, made structural:
# making the heartbeat unfit on a git-transport failure halted merges, `Done`
# moves and dispatch outright. It now cannot happen, because the heartbeat never
# asks.

unreachable="$work_dir/unreachable"
git_q clone -q "$origin" "$unreachable"
git_q -C "$unreachable" remote set-url origin "$work_dir/no-such-origin.git"

json="$(run_preflight --quick "$unreachable")"
expect True "$(verdict_field "$json" 'v["fit"]')" \
  "an expired git credential does not make the heartbeat unfit"
[[ ! -s "$work_dir/git.log" ]] || {
  fail "the quick preflight ran git against a broken origin: $(cat "$work_dir/git.log")"
}
echo "  ok: --quick is fit with no reachable origin, having never asked"

# --- 3. the full gate fetches, and the fetch gates ----------------------------
#
# `fit` is not asserted on the healthy run: the full gate also wants `gh` and
# `claude`, which a CI runner has no reason to carry. What is asserted is the
# fetch check itself, and then that a failed one is fatal.

json="$(run_preflight "" "$clone")"
grep -q "fetch" "$work_dir/git.log" || {
  fail "the full gate did not fetch. dispatch.sh cannot cut a worktree from a
  ref this machine has never reached, and finding that out inside a spawned
  agent costs the ticket an attempt.
  git calls: $(cat "$work_dir/git.log")"
}
expect True "$(verdict_field "$json" 'c["git fetch origin"]["ok"]')" \
  "the full gate's fetch succeeds against a reachable origin"

json="$(run_preflight "" "$unreachable")"
expect False "$(verdict_field "$json" 'c["git fetch origin"]["ok"]')" \
  "the fetch fails when origin is gone"
expect False "$(verdict_field "$json" 'v["fit"]')" \
  "the full gate is unfit when it cannot fetch -- nothing may be dispatched"
echo "  ok: the full gate fetches, and an unreachable origin makes it unfit"

# --- 4. nothing measures this checkout against origin/main --------------------
#
# Asserted as an absence, deliberately. A staleness number is the shape that
# grows back: it reads as diligence, it is one `rev-list` away, and it costs a
# fetch on whichever cadence computes it. It was advisory in both modes for the
# whole of its life, which is the tell -- nothing could act on it, because
# `evidence.sh` fetches per read and the prose forbade reading the tree at all.
# If a consumer ever genuinely appears, delete this case in the same diff that
# adds it, and say what reads the number.

for mode in --quick ""; do
  json="$(run_preflight "$mode" "$clone")"
  expect False "$(verdict_field "$json" '"behind_origin_main" in v')" \
    "${mode:-full}: the verdict carries no staleness number"
  expect False "$(verdict_field "$json" 'any("origin/main" in n for n in c)')" \
    "${mode:-full}: no check measures the checkout against origin/main"
  expect False "$(verdict_field "$json" 'any("advisory" in x for x in c.values())')" \
    "${mode:-full}: no check is advisory -- every check here gates"
done
echo "  ok: no verdict reports a distance from origin/main, in either mode"

echo "PASS: preflight fetches only where the answer gates a dispatch"
