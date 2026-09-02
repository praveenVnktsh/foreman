#!/usr/bin/env bash
# Shared configuration for the board orchestrator.
# Every value is overridable from the environment so a tick can be throttled
# without editing the skill.
#
# Sourced once per board, in a subshell. ONE tick agent walks every board on
# this machine, so it must never hold every board's values -- or every board's
# credential -- in one environment. That is why KEY_FILE below is a PATH and
# why nothing here opens it: the key stays out of the calling process, and the
# subprocess that actually talks to Linear is the only thing that reads it.

# Which board this is, where its repository is, and where its runtime lives.
#
# REPO used to be derived from this file's own `--git-common-dir`, which is
# right for a skill committed into the repository it builds and wrong for one
# installed once and pointed at many. The wrong answer was silent: the board
# would cut its worktrees inside its own installation. The board is now told
# which repository it serves, and refuses to guess.
FOREMAN_HOME="${FOREMAN_HOME:-$HOME/.foreman}"
# Exported here rather than with the rest at the end: bin/boards.py below reads
# $FOREMAN_HOME itself to find boards.toml, and a test that points this at a
# temporary directory has to move both halves at once or the loader and its
# parser disagree about which machine's boards they are reading.
export FOREMAN_HOME
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
#
# Checked HERE and not left to bin/boards.py, which applies the same rule to
# every name it reads: boards.py refuses an UNDECLARED alpha-x with "no board
# named alpha-x", which is a different, weaker answer. A name this shell will
# later paste into a glob is refused before anything downstream is reached.
if [[ ! "$INSTANCE" =~ ^[A-Za-z0-9_]+$ ]]; then
  printf 'foreman: instance name %s is invalid; only letters, digits and underscore are allowed (no hyphen, no slash)\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
# The per-board runtime directory: cards/, HALT, and the ids.env cache.
#
# Its absence is not a refusal any more. ~/.foreman/boards.toml is what
# declares which boards exist, so bin/boards.py is what refuses an unknown
# board, by name. This directory is derived state that a board which has never
# run has never created, and every writer of it -- card_log below,
# bin/resolve-ids.py -- makes it on first use. Refusing here would fail a
# freshly declared board's first tick with "no instance", which names the
# wrong problem.
INSTANCE_HOME="$FOREMAN_HOME/instances/$INSTANCE"
BOARD_HOME="${BOARD_HOME:-$INSTANCE_HOME}"

# This installation's own bin/. Derived once, from this file's location:
# config.sh lives in skills/board/, so the root is two directories up. The
# target repository is not obliged to ship any of these scripts.
_foreman_root="$(dirname -- "$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")")"

# Read one of this installation's loaders -- bin/boards.py, bin/contract.py --
# into this shell. Both emit NUL-separated KEY, VALUE pairs and always emit
# every key.
#
# Through a TEMP FILE, never a `$(...)` capture: bash 3.2 silently discards NUL
# bytes in command substitution (measured on this machine -- `printf 'a\0b\0'`
# captured through `$(...)` comes back 2 bytes, not 4), which would make every
# key end up unset with a zero exit status. A file preserves the NUL delimiters
# and lets the read loop and the exit-status check both work.
#
# The locals are lowercase and the key regex is uppercase-only, so a loader can
# never emit a key that overwrites this function's own state.
_foreman_load_pairs() { # <what> <loader> [args...]
  local what="$1"; shift
  local file key value
  file="$(mktemp)" || {
    printf 'foreman: mktemp failed; cannot read %s\n' "$what" >&2
    return 1
  }
  if ! "$@" >"$file"; then
    rm -f "$file"
    printf 'foreman: %s did not load (see above)\n' "$what" >&2
    return 1
  fi
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Environment wins. `-` and not `:-`: an explicitly empty override must
    # mean empty, the same distinction HIGH_RISK_PATHS depends on.
    eval "$key=\"\${$key-\$value}\""
  done <"$file"
  rm -f "$file"
}

# ids.env is KEY=VALUE, written by bin/resolve-ids.py, never by hand and never
# by a target repository. Read line by line rather than sourced: the same rule
# the contract follows, for the same reason.
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

# What this machine declares about this board: REPO, and the KEY_FILE holding
# the credential for the Linear workspace that board lives in. Two facts, one
# file, ~/.foreman/boards.toml -- the Linear team and project come from the
# target repository's own board.toml below, because the repository declares
# itself and a second copy on this machine would drift.
if ! _foreman_load_pairs "$FOREMAN_HOME/boards.toml" "$_foreman_root/bin/boards.py" "$INSTANCE"; then
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# The ids the board moves cards by. A CACHE of what bin/resolve-ids.py read out
# of Linear, never truth: every id in it is derived from the target's board.toml
# plus Linear, so an absent ids.env costs one re-resolve and never a broken
# board. _foreman_read_env returns quietly when the file is not there.
_foreman_read_env "$INSTANCE_HOME/ids.env"

# boards.py emits both keys for every board and refuses to emit either one
# empty, so an empty value here can only come from an explicitly empty
# environment override, which the `-` above honours. Both refuse rather than
# degrade.
if [[ -z "${REPO:-}" ]]; then
  # An empty REPO resolves every worktree path, glob and git command below
  # against "/", quietly.
  printf 'foreman: board %s resolved an empty REPO\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
if [[ -z "${KEY_FILE:-}" ]]; then
  # An empty KEY_FILE reads downstream as "use the default credential", which
  # is the wrong Linear workspace for the one board that declares a key of its
  # own -- the mix-up boards.py refuses `key = ""` to prevent.
  printf 'foreman: board %s resolved an empty KEY_FILE\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
# Whether that file EXISTS is deliberately not checked here. config.sh is
# sourced by sweeps, preflights and dispatches that never talk to Linear, and
# failing all of them on a missing credential would name the wrong problem.
# The one process that reads the key refuses by path when it cannot.

# The target's own contract. Everything a repository knows about itself.
if ! _foreman_load_pairs "$REPO/board.toml" "$_foreman_root/bin/contract.py" "$REPO/board.toml"; then
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
export REPO KEY_FILE INSTANCE INSTANCE_HOME BOARD_HOME

# Where a build agent's plan lands, relative to REPO.
#
# The one place this path is written. brief.py renders it into the build
# prompt, and reconcile.py reads the pushed branch for a file under it. A
# prompt that names one path and a check that reads another leaves every card
# stuck in the Plan column, with its plan committed and pushed and sitting
# right there.
#
# skills/graphplan/SKILL.md writes to this same path by default. An override
# therefore moves the instruction and the check together, and does not move
# the skill's own default.
#
# `-`, not `:-`: an explicitly empty override must mean empty, the same
# distinction every other override in this file makes.
PLAN_DIR="${PLAN_DIR-docs/plans}"

MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"

# One model per STAGE, because the three stages need different things.
#
# The PLAN is where the strongest model is spent. It is drawn once, before any
# code exists, and every build agent afterwards is only as good as the graph it
# was handed: a node whose label is wrong is wrong in every file that node
# owns. `skills/graphplan/SKILL.md` is the contract that plan is drawn under.
#
# The BUILD executes a plan whose design decisions are already made, so `opus`
# is its ceiling and a graphplan node names `opus`, `sonnet` or `haiku` --
# never `fable`. The inverse arrangement was proposed once and closed
# unmerged: fable for every build node, opus for the planner. It spends the
# strongest model on typing out a plan the weakest one drew.
#
# The REVIEW reads a diff nobody else will read again before it merges, and a
# missed blocking finding is discovered in production. It stays at `opus`.
#
# `-`, not `:-`: `PLAN_MODEL=` must reach the CLI as an empty `--model`, which
# Claude Code reads as "inherit this session's model" -- the way back to the
# previous behaviour, and the same distinction every other override in this
# file makes.
PLAN_MODEL="${PLAN_MODEL-fable}"
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
# Empty disables the backstop entirely, relying on the marker alone -- which
# means `-`, not `:-`, for the same reason HIGH_RISK_PATHS and every
# `_foreman_read_env` key above are `-`: an explicitly empty override must
# mean empty. Reconcile.py already gets this right on its own side
# (`float(...) if _CFG["HOST_SLOT_STALE_MINUTES"] else None`), so `:-` here
# was the one place in the chain that silently reinstated 720 for an operator
# who set `HOST_SLOT_STALE_MINUTES=` meaning "disabled".
HOST_SLOT_STALE_MINUTES="${HOST_SLOT_STALE_MINUTES-720}"

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
#
# `-`, not `:-`: an operator debugging the acceptEdits path on purpose must be
# able to turn this off by setting it explicitly empty, the same distinction
# every other override in this file makes. dispatch.sh:95 also treats the
# literal string "0" as off (`-n` alone reads "0" as non-empty, i.e. "on" --
# the one value an operator would most naturally reach for), so there are now
# two ways to say "off" and both work: `AGENT_SKIP_PERMISSIONS=` and
# `AGENT_SKIP_PERMISSIONS=0`.
AGENT_SKIP_PERMISSIONS="${AGENT_SKIP_PERMISSIONS-1}"

# The self-looping tick agent, and the watchdog that keeps it alive.
#
# This machine runs ONE long-lived background agent executing `/loop <interval>
# /board`. Cron does not run ticks — it runs supervise.sh, which only ensures
# that agent exists and is healthy. Keeping dispatch out of cron is deliberate:
# a watchdog that could also dispatch would double-dispatch the moment it
# misjudged liveness.
#
# The name carries NO board segment, unlike agent_name, branch_name,
# worktree_path and evidence_ref below. There is ONE tick for every board on
# this machine -- it walks them in turn -- so a per-board name would ask
# supervise.sh to keep N agents alive and let N ticks dispatch against one
# machine-wide HOST_MAX_CONCURRENT. The per-CARD names keep their board
# segment, which is what stops two boards reaping each other's work.
TICK_AGENT_NAME="${TICK_AGENT_NAME:-foreman/tick}"
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

# How long `supervise.sh --restart` waits for the tick to finish the turn it is
# in before stopping it anyway.
#
# NOT a correctness bound. Stopping a tick mid-turn is safe: it holds no state,
# and its replacement re-derives every card's position from Linear, gh and git.
# This exists for the operator. A restart that routinely cuts a half-finished
# merge or dispatch in two leaves a transcript that stops mid-sentence, and the
# person reading it next cannot tell that from a crash.
#
# 120 seconds is longer than a merge or a dispatch and far shorter than a wedged
# turn, which TICK_STALL_MINUTES already covers.
TICK_DRAIN_SECONDS="${TICK_DRAIN_SECONDS:-120}"

# How long `supervise.sh --restart` waits for the REPLACEMENT tick to appear in
# the agent registry before reporting failure.
#
# `claude --bg` returns as soon as the agent is SPAWNED, so the "started
# foreman/tick" line supervise.sh prints is not evidence that a tick exists. A
# restart that reports success over a tick which never came up leaves the board
# silently stopped until the next timer fire, and the operator has just been
# told it worked, so nobody looks. A restart is the one gesture that cannot
# afford to be believed on faith.
TICK_START_TIMEOUT_SECONDS="${TICK_START_TIMEOUT_SECONDS:-60}"

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
#
# THIS INSTALLATION's own bin/tmp-dir.sh, never the target's. A target repo
# is not obliged to ship any particular directory of its own scripts --
# asking it for a scratch-dir helper of its own was a leftover from before
# foreman was extracted from the project it grew up in, and it made every
# dispatch onto a target that (like every target except that one) ships no
# such file die right after the worktree was cut,
# under `set -euo pipefail` (dispatch.sh's `mkdir -p "$(agent_tmp_for
# "$WORKTREE")"`) or silently reap nothing (sweep.sh's `remove_agent_tmp
# "$(agent_tmp_for "$path")"`, where an empty argument passes
# `[[ -d "" ]] || return 0` and reports success). Named here from
# $_foreman_root and kept, rather than derived a second time, because
# agent_tmp_for() below needs the identical path: two independent derivations
# of one path agree only until one of them is edited.
_foreman_tmp_dir_sh="$_foreman_root/bin/tmp-dir.sh"
if ! AGENT_TMP_ROOT="$(BOARD_HOME="$BOARD_HOME" "$_foreman_tmp_dir_sh" --root)"; then
  printf 'foreman: bin/tmp-dir.sh failed; cannot derive the agent scratch root\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

card_dir() { printf '%s/cards/%s\n' "$BOARD_HOME" "$1"; }
# The scratch dir paired with a worktree path. Same basename, so a sweep that
# reaps the worktree can reap the scratch without tracking anything.
# THIS INSTALLATION's bin/tmp-dir.sh -- see the comment above AGENT_TMP_ROOT.
agent_tmp_for() { BOARD_HOME="$BOARD_HOME" "$_foreman_tmp_dir_sh" "$1"; }
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
