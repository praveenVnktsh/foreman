#!/usr/bin/env bash
# Shared configuration for the board orchestrator.
# Every value is overridable from the environment so a tick can be throttled
# without editing the skill.

# The checkout this skill is checked into, derived from this file's own location
# so a clone at any path works.
#
# Resolved through git's *common* dir rather than the enclosing directory,
# because a dispatched agent runs in a worktree that carries its own copy of
# this file: `dirname` three levels up would give the worktree, and dispatch.sh
# creates worktrees at "$REPO/.claude/worktrees/", so every dispatch from inside
# one would nest a level deeper. --git-common-dir points at the main checkout's
# .git from any worktree, so REPO is the main checkout from either.
if [[ -z "${REPO:-}" ]]; then
  _board_skill_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  _board_git_common="$(
    git -C "$_board_skill_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
  )" || _board_git_common=""
  if [[ -z "$_board_git_common" ]]; then
    printf 'board: cannot derive REPO from %s (git rev-parse --git-common-dir failed there); set REPO in the environment\n' \
      "$_board_skill_dir" >&2
    # `exit` unless a human is at a prompt: preflight.py and reconcile.py source
    # this from a `bash -c` with no `set -e`, and a bare `return` there leaves
    # them reading an empty REPO instead of stopping. An interactive shell gets
    # a `return` so a stray `. config.sh` does not close the terminal.
    if [[ $- == *i* ]]; then return 1; else exit 1; fi
  fi
  REPO="$(dirname -- "$_board_git_common")"
  unset _board_skill_dir _board_git_common
fi
BOARD_HOME="${BOARD_HOME:-$HOME/.murmr-board}"

# Linear team PRA, project "murmr." (the trailing period is part of the name).
# The board is scoped to that project: a card outside it is none of its business.
# State IDs, never names — a renamed column must not silently change which
# column the orchestrator is allowed to write to.
LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-76b6d7f6-2d25-4566-9429-0273a80398d9}"
LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-f76b8de2-663a-4a10-8fa0-107f8ee0a695}"

LABEL_FOLLOW_UP="${LABEL_FOLLOW_UP:-db821df7-323e-4057-9031-ff1e8b466213}"
LABEL_FOLLOW_UPS_WRITTEN="${LABEL_FOLLOW_UPS_WRITTEN:-59b8152f-6fa1-4338-8d72-0b1f2e55c6a9}"
LABEL_NEEDS_MERGE="${LABEL_NEEDS_MERGE:-5aeb4ffd-c10f-4af9-90a4-a3c6354b9d38}"
LABEL_BOARD_FAILED="${LABEL_BOARD_FAILED:-e17b86be-4094-490d-b800-ca8e223beeec}"
STATE_PLANNED="${STATE_PLANNED:-d1f37faa-caef-4607-9dbe-f456c7d8354b}"      # Backlog
STATE_TO_PICK_UP="${STATE_TO_PICK_UP:-b6b17231-255c-4a11-b60b-9ff3d732daf7}" # Todo
STATE_IN_PROGRESS="${STATE_IN_PROGRESS:-4fb2fe32-5969-4a4d-9daa-f6d2d33f606f}"
STATE_IN_REVIEW="${STATE_IN_REVIEW:-e72d079d-174c-4606-ab20-39024cd94cef}"
STATE_MERGED="${STATE_MERGED:-d0e547b6-5314-4294-9c36-d356715a435e}"        # Done

# Raised to 10 at Praveen's request on 2026-08-02. It is a CEILING, not a target.
#
# Measured on mango that day, this machine cannot actually sustain 10 builds:
#   - 14GB RAM total, and /tmp is a 7.3GB tmpfs, so tmpfs competes for the same RAM
#   - ONE `just test-all` run held 2.2GB of /tmp — three concurrent runs exhaust it
#   - each agent is ~410MB RSS before its test suite, and a card in review adds
#     REVIEWERS_PER_ROUND more agents on top of its build agent
#   - each worktree is ~740MB on disk (it carries its own backend/.venv)
#
# The binding constraint is /tmp, and preflight cannot save you from it: the probe
# writes and RELEASES, so it is a point-in-time check and never a reservation. Ten
# dispatches can each pass a probe in turn and then blow the quota collectively
# once all ten reach their test suites — which is exactly the EDQUOT failure that
# cost PRA-28 two attempts.
#
# Realistic ceiling here is 3-4. To actually use 10, give each agent its own
# TMPDIR on disk (336GB free) instead of sharing the tmpfs.
MAX_CONCURRENT="${MAX_CONCURRENT:-10}"
MAX_BUILD_ATTEMPTS="${MAX_BUILD_ATTEMPTS:-2}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-2}"
REVIEWERS_PER_ROUND="${REVIEWERS_PER_ROUND:-2}"
STALL_MINUTES="${STALL_MINUTES:-30}"
MAX_FOLLOWUPS="${MAX_FOLLOWUPS:-3}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"

BUILD_MODEL="${BUILD_MODEL:-opus}"
REVIEW_MODEL="${REVIEW_MODEL:-opus}"

# Environment thresholds, enforced by preflight.py before anything is dispatched.
#
# PROBE_* are written for real and then released; MIN_FREE_* are read from
# statvfs. Both exist because they fail differently: on 2026-08-02 `/tmp` was a
# tmpfs mounted `usrquota` with the user over allowance, so `df` reported 1.5G
# free while every write returned EDQUOT. A free-space check alone called that
# machine healthy and the board dispatched two builds into it, losing both.
#
# The tmp probe is deliberately large. `just test-all` runs pytest, which wants
# gigabytes; a quota can admit a 1MB probe and refuse the run that follows.
MIN_FREE_TMP_MB="${MIN_FREE_TMP_MB:-2048}"
MIN_FREE_REPO_MB="${MIN_FREE_REPO_MB:-5120}"
PROBE_TMP_MB="${PROBE_TMP_MB:-1024}"
PROBE_REPO_MB="${PROBE_REPO_MB:-64}"
# `preflight.py --quick` probe, used by the heartbeat tick. Small on purpose: a
# tick every couple of minutes must not write a gigabyte to prove a machine it is
# not about to build on is healthy. dispatch.sh still runs the full gate, so
# nothing is ever spawned on the strength of this one.
QUICK_PROBE_MB="${QUICK_PROBE_MB:-16}"

# Dispatched agents run with --dangerously-skip-permissions, at Praveen's
# explicit instruction on 2026-08-01.
#
# `acceptEdits` cannot work here: it accepts file edits but still prompts for
# Bash, so an unattended agent blocks on its first git, gh or test command and
# waits forever for an operator who is not there. The symptom is
# `state: blocked, waitingFor: permission prompt` in `claude agents` — no error,
# no transcript, no exit. That is exactly how the first PRA-28 build died.
#
# What contains a dispatched agent is therefore NOT the permission prompt. It is:
# the throwaway worktree it runs in, the fact that nothing merges without an
# adversarial review, the three required checks, and migrations still parking for
# Praveen. Weakening any of those matters much more now than it did before.
AGENT_SKIP_PERMISSIONS="${AGENT_SKIP_PERMISSIONS:-1}"

# Paths whose presence in a diff park the PR for Praveen instead of merging it.
# Read from the diff, never from the ticket text.
#
# Narrowed to migrations only, at Praveen's request on 2026-08-01. Sensors,
# health, finance, ops/ and .github/workflows/ now merge autonomously once
# reviewed and green. The distinction is reversibility: a bad change in those is
# a revert and a redeploy, but a migration runs against mango's live SQLite and
# mutates the ledger in place — reverting the PR does not undo it.
#
# To restore the full carve-out, add back:
#   backend/app/sensors/ backend/app/domains/health/ backend/app/domains/finance/
#   ops/ .github/workflows/
#
# Note `-` and not `:-`: an explicitly empty value must mean "nothing is high
# risk", not "fall back to the default". With `:-`, an empty env var reads as
# absent and silently reinstates this list.
export HIGH_RISK_PATHS="${HIGH_RISK_PATHS-backend/app/events/migrations/}"

# Checks required by the `main` ruleset, by exact name.
REQUIRED_CHECKS="${REQUIRED_CHECKS:-Operations|Backend|Node integrations}"

# The workflow step 0 reads to decide whether `main` is safe to merge into and
# dispatch from. By workflow NAME, matching `name: CI` in .github/workflows/ci.yml.
CI_WORKFLOW="${CI_WORKFLOW:-CI}"

# Deployment evidence. Job success is not deployment success — a stale-revision
# stand-down also concludes `success`, so the step name is the real signal.
# Mirrors backend/app/builds/verification.py; renaming there must be matched here.
DEPLOY_WORKFLOW="${DEPLOY_WORKFLOW:-deploy-mango.yml}"
DEPLOY_STEP="${DEPLOY_STEP:-Deploy and verify murmr}"

# The self-looping tick agent, and the watchdog that keeps it alive.
#
# The board runs as ONE long-lived background agent executing `/loop <interval>
# /board`. Cron does not run ticks — it runs supervise.sh, which only ensures
# that agent exists and is healthy. Keeping dispatch out of cron is deliberate:
# a watchdog that could also dispatch would double-dispatch the moment it
# misjudged liveness.
TICK_AGENT_NAME="${TICK_AGENT_NAME:-board/tick}"
TICK_INTERVAL_MINUTES="${TICK_INTERVAL_MINUTES:-20}"
TICK_MODEL="${TICK_MODEL:-fable}"

# Wedged: mid-turn and silent. A tick genuinely working is never quiet this long.
TICK_STALL_MINUTES="${TICK_STALL_MINUTES:-45}"
# Loop dead: idle between ticks for longer than the interval can explain, which
# means the loop stopped rescheduling itself and no further tick is ever coming.
# MUST exceed TICK_INTERVAL_MINUTES or the watchdog kills healthy agents that are
# merely waiting for their next turn; supervise.sh refuses to run if it does not.
TICK_DEAD_MINUTES="${TICK_DEAD_MINUTES:-60}"
# Recycle: a self-looping agent accumulates context on every iteration forever.
# Restarting it on a schedule bounds that, and costs nothing — the tick holds no
# state, so a fresh agent re-derives the identical picture from Linear, gh and git.
TICK_MAX_AGE_HOURS="${TICK_MAX_AGE_HOURS:-12}"

# Convergence: how long one tick may keep working before handing over.
#
# A tick runs passes until nothing changes, waiting for work it started itself
# rather than ending and leaving it for the next fire. Without that, a card
# walking from build to deployed costs five ticks that are almost entirely idle.
#
# These are BUDGETS, not deadlines. Ending a tick early is always correct — the
# next one re-derives the same picture from Linear, gh and git — so every limit
# here may be hit without anything being wrong.
TICK_BUDGET_MINUTES="${TICK_BUDGET_MINUTES:-12}"
TICK_MAX_PASSES="${TICK_MAX_PASSES:-6}"
WAIT_REVIEW_SECONDS="${WAIT_REVIEW_SECONDS:-300}"
WAIT_CHECKS_SECONDS="${WAIT_CHECKS_SECONDS:-900}"
WAIT_DEPLOY_SECONDS="${WAIT_DEPLOY_SECONDS:-600}"
# A build is long and its output is a pull request the next pass can see anyway,
# so the default is not to sit on one. Raise it only for a deliberately
# synchronous run.
WAIT_BUILD_SECONDS="${WAIT_BUILD_SECONDS:-0}"

# When set, mutating operations print what they would do and exit.
BOARD_DRY_RUN="${BOARD_DRY_RUN:-}"

# Scratch root for dispatched agents, paired one-to-one with worktrees.
#
# Deliberately OUTSIDE the repo. `backend/tests/test_design_invariants.py`
# rglobs the checkout, and its own comment records being burned by sibling
# worktrees inflating a basename set to 15,934 names; a scratch tree full of
# test vaults would feed exactly that. It is also on the nvme rather than the
# /tmp tmpfs, which is 50% of RAM and quota-capped near 5.5G per user.
#
# The path is derived from the WORKTREE, never from the environment. Agents
# inherit their env from the shared `claude daemon`, not from the dispatch.sh
# that spawned them — measured 2026-08-02, when every live agent including a
# reviewer and a different ticket's build all reported `TICKET=PRA-29
# ROLE=build`. Anything per-agent keyed on that env is silently wrong for every
# agent after the first.
#
# Asked of ops/tmp-dir.sh rather than computed here, and no longer separately
# overridable: the justfile's test recipes export the same path as TMPDIR, and
# while the two derivations were independent they agreed only because two
# hardcoded strings matched. Setting the board's knob moved what dispatch
# created and what sweep reaped while the tests kept writing to the old path,
# and setting the justfile's knob did the reverse — either way the scratch
# accumulates forever and nothing says so. `MURMR_TMP_ROOT` (and `BOARD_HOME`)
# now move both at once because there is only one derivation left to move.
if ! AGENT_TMP_ROOT="$(BOARD_HOME="$BOARD_HOME" "$REPO/ops/tmp-dir.sh" --root)"; then
  printf 'board: %s/ops/tmp-dir.sh failed; cannot derive the agent scratch root\n' "$REPO" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

card_dir() { printf '%s/cards/%s\n' "$BOARD_HOME" "$1"; }
# The scratch dir paired with a worktree path. Same basename, so a sweep that
# reaps the worktree can reap the scratch without tracking anything.
agent_tmp_for() { BOARD_HOME="$BOARD_HOME" "$REPO/ops/tmp-dir.sh" "$1"; }
agent_name() { printf 'board/%s/%s-%s\n' "$1" "$2" "$3"; }
worktree_path() { printf '%s/.claude/worktrees/board-%s\n' "$REPO" "$1"; }

# Append one line to a card's transition log. Never rewritten, only appended.
card_log() {
  local ticket="$1" event="$2"
  local dir
  dir="$(card_dir "$ticket")"
  mkdir -p "$dir"
  printf '{"at":"%s","event":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" >>"$dir/history.jsonl"
}

die() { printf 'board: %s\n' "$*" >&2; exit 1; }
