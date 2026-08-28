#!/usr/bin/env bash
# Shared configuration for the board orchestrator.
# Every value is overridable from the environment so a tick can be throttled
# without editing the skill.

# The repository this installation serves, and where its state lives.
#
# It used to be derived from this file's own `--git-common-dir`, which is right
# for a skill committed into the repository it builds and wrong for one
# installed once and pointed at many. The wrong answer was silent: the board
# would cut its worktrees inside its own installation. The instance is now told,
# and refuses to guess.
FOREMAN_HOME="${FOREMAN_HOME:-$HOME/.foreman}"
INSTANCE="${FOREMAN_INSTANCE:-}"
if [[ -z "$INSTANCE" ]]; then
  printf 'foreman: FOREMAN_INSTANCE is unset; refusing to guess which repository to build\n' >&2
  # `exit` unless a human is at a prompt: preflight.py and reconcile.py source
  # this from a `bash -c` with no `set -e`, and a bare `return` there leaves
  # them reading an empty REPO instead of stopping. An interactive shell gets
  # a `return` so a stray `. config.sh` does not close the terminal.
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
# No hyphen, no slash. worktree_path and every worktree/scratch glob in
# sweep.sh join the instance and the ticket with a HYPHEN
# (foreman-<instance>-<ticket>), which an unconstrained instance name can
# absorb: INSTANCE=alpha-x makes "foreman-alpha-x-PRA-1" match the glob
# "foreman-alpha-*", so alpha's sweep would reap alpha-x's worktrees on a
# shared REPO. agent_name/branch_name/evidence_ref are `/`-delimited and safe
# regardless, but the name is constrained here rather than changing the
# worktree delimiter -- any separator can be absorbed by an unconstrained
# name, so the name is what actually has to be closed. Underscores stay legal
# so `target_staging` is still sayable.
if [[ ! "$INSTANCE" =~ ^[A-Za-z0-9_]+$ ]]; then
  printf 'foreman: instance name %s is invalid; only letters, digits and underscore are allowed (no hyphen, no slash)\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
INSTANCE_HOME="$FOREMAN_HOME/instances/$INSTANCE"
if [[ ! -d "$INSTANCE_HOME" ]]; then
  printf 'foreman: no instance %s at %s\n' "$INSTANCE" "$INSTANCE_HOME" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
BOARD_HOME="${BOARD_HOME:-$INSTANCE_HOME}"

# instance.env and ids.env are KEY=VALUE, written by boardctl, never by hand and
# never by a target repository. Read line by line rather than sourced: the same
# rule the contract follows, for the same reason.
_foreman_read_env() {
  local file="$1" line key value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Environment wins. `-` and not `:-`: an explicitly empty override must mean
    # empty, the same distinction HIGH_RISK_PATHS depends on.
    eval "$key=\"\${$key-\$value}\""
  done <"$file"
}
_foreman_read_env "$INSTANCE_HOME/instance.env"
_foreman_read_env "$INSTANCE_HOME/ids.env"

if [[ -z "${REPO:-}" ]]; then
  printf 'foreman: instance %s declares no REPO\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# The target's own contract. Everything a repository knows about itself.
#
# A temp file, not a `$(...)` capture: bash 3.2 silently discards NUL bytes in
# command substitution (measured on this machine -- `printf 'a\0b\0'` captured
# through `$(...)` comes back 2 bytes, not 4), which would make every contract
# key end up unset with a zero exit status. A file preserves the NUL delimiters
# and lets the read loop and the exit-status check both work.
_foreman_skill_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_foreman_contract="$(dirname -- "$(dirname -- "$_foreman_skill_dir")")/bin/contract.py"
_foreman_pairs_file="$(mktemp)" || {
  printf 'foreman: mktemp failed; cannot read the contract\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
}
if ! "$_foreman_contract" "$REPO/board.toml" >"$_foreman_pairs_file"; then
  rm -f "$_foreman_pairs_file"
  printf 'foreman: %s/board.toml did not load (see above)\n' "$REPO" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
  [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  eval "$_k=\"\${$_k-\$_v}\""
done <"$_foreman_pairs_file"
rm -f "$_foreman_pairs_file"
unset _foreman_skill_dir _foreman_contract _foreman_pairs_file _k _v
export REPO INSTANCE INSTANCE_HOME BOARD_HOME FOREMAN_HOME

MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"

BUILD_MODEL="${BUILD_MODEL:-opus}"
REVIEW_MODEL="${REVIEW_MODEL:-opus}"

# The MACHINE's ceiling, across every instance sharing it -- not this
# repository's `MAX_CONCURRENT`, which is a per-instance limit declared in
# board.toml and has no idea another instance's cards exist. Two instances
# each dispatching up to their own MAX_CONCURRENT can still jointly exceed
# what one machine's RAM and /tmp can sustain, which is the same class of
# failure PROBE_TMP_MB/MIN_FREE_TMP_MB guard against for a single instance.
# `reconcile.py --host-slots` does the counting, across
# `~/.foreman/instances/*/cards/`; this is the ceiling it is checked against
# before a dispatch, in addition to the instance's own MAX_CONCURRENT.
HOST_MAX_CONCURRENT="${HOST_MAX_CONCURRENT:-4}"

# How stale a card's LAST history.jsonl entry may be before --host-slots stops
# counting it, even without an explicit `{"action":"released",...}`.
#
# The marker is the primary mechanism -- SKILL.md logs it when a card reaches
# `Done` or `board-failed` -- but it is written by hand-followed prose, not
# enforced by any type checker, and this sidecar is documented elsewhere as "a
# cache, never truth: delete it and the next tick must still reconstruct every
# card's position." A slot releasable ONLY by an LLM remembering one specific
# line violates that. A THIRD terminal exit added later and never wired to the
# marker -- the exact failure a reviewer caught in this feature's first round
# -- would otherwise wedge dispatch on EVERY instance on this machine forever,
# recoverable only by hand-editing history.jsonl: four cumulative board-failed
# cards is enough to pin HOST_MAX_CONCURRENT's default of 4, and nothing ever
# reclaims it, because sweep.sh deliberately never deletes history.jsonl.
#
# 12 hours is long enough that it should never fire during a card's ordinary
# lifecycle -- ticks run every TICK_INTERVAL_MINUTES and a card usually
# resolves in a handful of them -- and short enough to self-heal a leaked slot
# same-day rather than needing an operator to notice and hand-edit a file.
# Empty disables the backstop entirely, relying on the marker alone.
HOST_SLOT_STALE_MINUTES="${HOST_SLOT_STALE_MINUTES:-720}"

# Dispatched agents run with --dangerously-skip-permissions, at the operator's
# explicit instruction on 2026-08-01.
#
# `acceptEdits` cannot work here: it accepts file edits but still prompts for
# Bash, so an unattended agent blocks on its first git, gh or test command and
# waits forever for an operator who is not there. The symptom is
# `state: blocked, waitingFor: permission prompt` in `claude agents` — no error,
# no transcript, no exit. That is exactly how the first of two consecutive
# attempts on one card died.
#
# What contains a dispatched agent is therefore NOT the permission prompt. It is:
# the throwaway worktree it runs in, the fact that nothing merges without an
# adversarial review, the three required checks, and migrations still parking for
# the operator. Weakening any of those matters much more now than it did before.
AGENT_SKIP_PERMISSIONS="${AGENT_SKIP_PERMISSIONS:-1}"

# The self-looping tick agent, and the watchdog that keeps it alive.
#
# The board runs as ONE long-lived background agent executing `/loop <interval>
# /board`. Cron does not run ticks — it runs supervise.sh, which only ensures
# that agent exists and is healthy. Keeping dispatch out of cron is deliberate:
# a watchdog that could also dispatch would double-dispatch the moment it
# misjudged liveness.
TICK_AGENT_NAME="${TICK_AGENT_NAME:-foreman/$INSTANCE/tick}"
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
# Deliberately OUTSIDE the repo. A target's own test suite may rglob the
# checkout looking for source files -- one such test's own comment records
# being burned by sibling worktrees inflating a basename set to 15,934 names;
# a scratch tree full of test vaults would feed exactly that. It is also on
# the nvme rather than the /tmp tmpfs, which is 50% of RAM and quota-capped
# near 5.5G per user.
#
# The path is derived from the WORKTREE, never from the environment. Agents
# inherit their env from the shared `claude daemon`, not from the dispatch.sh
# that spawned them — measured 2026-08-02, when every live agent including a
# reviewer and a different ticket's build all reported the same ticket and
# role in their environment. Anything per-agent keyed on that env is silently
# wrong for every agent after the first.
#
# Asked of bin/tmp-dir.sh rather than computed here, and no longer separately
# overridable: the justfile's test recipes used to export the same path as
# TMPDIR, and while the two derivations were independent they agreed only
# because two hardcoded strings matched. Setting the board's knob moved what
# dispatch created and what sweep reaped while the tests kept writing to the
# old path, and setting the justfile's knob did the reverse — either way the
# scratch accumulates forever and nothing says so. `FOREMAN_TMP_ROOT` (and
# `BOARD_HOME`) now move both at once because there is only one derivation
# left to move.
if ! AGENT_TMP_ROOT="$(BOARD_HOME="$BOARD_HOME" \
    "$(dirname -- "$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")")/bin/tmp-dir.sh" --root)"; then
  printf 'foreman: bin/tmp-dir.sh failed; cannot derive the agent scratch root\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

card_dir() { printf '%s/cards/%s\n' "$BOARD_HOME" "$1"; }
# The scratch dir paired with a worktree path. Same basename, so a sweep that
# reaps the worktree can reap the scratch without tracking anything.
agent_tmp_for() { BOARD_HOME="$BOARD_HOME" "$REPO/ops/tmp-dir.sh" "$1"; }
# Every name carries the instance. `claude agents` is one flat registry shared
# by every installation on this machine, matched by prefix in reconcile.py and
# by regex in watch-agents.py; without this segment two instances reap each
# other's agents, and two projects may legitimately both use the team key PRA.
agent_name() { printf 'foreman/%s/%s/%s-%s\n' "$INSTANCE" "$1" "$2" "$3"; }
worktree_path() { printf '%s/.claude/worktrees/foreman-%s-%s\n' "$REPO" "$INSTANCE" "$1"; }
branch_name() { printf 'foreman/%s/%s\n' "$INSTANCE" "$1"; }
evidence_ref() { printf 'refs/foreman/%s/evidence/%s\n' "$INSTANCE" "$1"; }

# Append one line to a card's transition log. Never rewritten, only appended.
card_log() {
  local ticket="$1" event="$2"
  local dir
  dir="$(card_dir "$ticket")"
  mkdir -p "$dir"
  printf '{"at":"%s","event":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" >>"$dir/history.jsonl"
}

die() { printf 'foreman: %s\n' "$*" >&2; exit 1; }
