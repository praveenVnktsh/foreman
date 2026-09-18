#!/usr/bin/env bash
# Shared configuration for the board orchestrator.
# Every value is overridable from the environment so a tick can be throttled
# without editing the skill.
#
# Sourced once per board, in a subshell. ONE tick agent walks every board this
# installation serves, so it must never hold every board's values -- or every
# board's credential -- in one environment. That is why KEY_FILE below is a
# PATH and why nothing here opens it: the key stays out of the calling process,
# and the subprocess that actually talks to Linear is the only thing that reads
# it.

# This installation's own clone. Derived once, from this file's location:
# config.sh lives in skills/board/, so the root of the clone is two directories
# up. The target repository is not obliged to ship any of these scripts.
#
# THREE ROOTS, and they are not each other. This one is the CLONE
# (~/.foreman/<installation>/install). `FOREMAN_HOME` is the installation's own
# directory, the clone's parent. `FOREMAN_ROOT` is the MACHINE root that holds
# every installation, one level above that. This local used to be called
# `_foreman_root`, one character from the machine root's name, in a file that
# exports both.
_foreman_install_root="$(dirname -- "$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")")"

# The reader for this installation's loaders -- bin/installation.py,
# bin/boards.py, bin/contract.py. bin/load-pairs.sh carries the bash 3.2
# temp-file rule behind it, and bin/boardctl and the three installers source
# the same file.
#
# From THIS installation's root, the same root every path below is derived
# from. A missing file is refused here, by name: without it every load below
# would fail as "command not found" and blame the loader it ran.
if ! . "$_foreman_install_root/bin/load-pairs.sh"; then
  printf 'foreman: cannot read %s/bin/load-pairs.sh\n' "$_foreman_install_root" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# Which installation this is: its home, the root it shares with its siblings,
# its harness, whether it owns the cards that carry no label, and the four
# stage models further down. bin/installation.py reads all of that out of
# $FOREMAN_HOME/installation.toml, and answers for a home that has none by
# naming it a lone Claude installation -- which is what every machine looked
# like before installations existed.
#
# FOREMAN_HOME has NO default here any more. One machine now runs several
# installations under one root, and identity comes from the path: the home is
# the parent of this clone. installation.py owns that derivation and this file
# copies none of it -- two derivations of one home agree only until one of
# them is edited, and the half that disagreed would read a sibling's
# boards.toml. An explicit FOREMAN_HOME still wins, which is how a test points
# everything at a temporary directory.
#
# Exported BEFORE the load rather than with the rest at the end: both
# installation.py here and bin/boards.py below read $FOREMAN_HOME themselves
# to find their file, so an unexported home leaves this shell and the loaders
# it runs answering for two different installations. `export` on an unset
# variable exports nothing, so this never turns an absent home into an empty
# one.
export FOREMAN_HOME
# These four come from the loader ALONE, so they are unset first. Every other
# key in this file is environment-wins, and these four cannot be: they say who
# this installation is, and the environment is not allowed to answer that.
#
# Two failures, both silent. `IS_DEFAULT=1` in the environment makes a
# non-default installation claim every card carrying no `foreman:*` label,
# straight past bin/installation.py's one-default check -- two ticks then
# dispatch the same unlabelled card. `INSTALLATION=a-b` reopens the
# hyphen-absorption hole this file documents for INSTANCE below, one segment
# earlier: worktree_path joins the installation with a hyphen, so a-b's
# worktrees match installation a's sweep glob on a shared REPO.
#
# LEGACY_NAMES is the third silent failure. `LEGACY_NAMES=1` in the
# environment gives a scoped installation the legacy shapes below: its sweep
# then globs foreman-<board>-* and reaps the worktrees of a legacy sibling
# that serves the same repository, and its reconcile reads that sibling's pull
# requests as its own.
#
# FOREMAN_HOME above is deliberately NOT in this list. An explicit home is how
# every test in tests/ points a whole installation at a temporary directory,
# and it selects a home rather than contradicting what that home declares.
unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT LEGACY_NAMES
if ! _foreman_load_pairs "this installation's declaration" "$_foreman_install_root/bin/installation.py"; then
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
if [[ -z "${FOREMAN_HOME:-}" ]]; then
  # installation.py never emits an empty home, so an empty one here can only
  # come from an explicitly empty environment override, which the `-` above
  # honours. It would resolve boards.toml, instances/ and supervise.lock
  # against "/", quietly.
  printf 'foreman: FOREMAN_HOME resolved empty; leave it unset to derive it from this installation\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# ONE MODEL PER STAGE, AND A STAGE MAY NAME CANDIDATES. installation.py emits
# <STAGE>_MODEL (the first candidate) beside <STAGE>_MODELS (the whole list,
# newline-separated). _foreman_load_pairs is environment-wins, so an operator's
# `PLAN_MODEL=sonnet` -- or an explicit `PLAN_MODEL=` meaning "inherit" -- makes
# the two disagree. That override says "this one model, no fallback", so the
# list collapses to it. Everything downstream reads <STAGE>_MODELS.
# See docs/specs/2026-09-18-project-level-installs-design.md.
for _stage in TICK PLAN BUILD REVIEW; do
  eval "_model_val=\"\${${_stage}_MODEL-}\""
  eval "_models_val=\"\${${_stage}_MODELS-}\""
  if [[ "$_model_val" != "${_models_val%%$'\n'*}" ]]; then
    eval "${_stage}_MODELS=\"\$_model_val\""
  fi
done
unset _stage _model_val _models_val
# No hyphen, no slash, the same rule INSTANCE is held to below and for the same
# glob: worktree_path and every sweep glob join the installation and the
# instance with a HYPHEN, so INSTALLATION=a-b makes "foreman-a-b-demo-PRA-1"
# match installation a's glob "foreman-a-*" on a repository both serve.
#
# Re-checked HERE even though bin/installation.py applies the rule when it
# reads the name. The loader above is not the only way a value arrives, and a
# name this shell pastes into a glob is worth one line to re-establish. It is
# also the check that catches a loader whose own rule is one day loosened.
if [[ ! "$INSTALLATION" =~ ^[A-Za-z0-9_]+$ ]]; then
  printf 'foreman: installation name %s is invalid; only letters, digits and underscore are allowed (no hyphen, no slash)\n' "$INSTALLATION" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# THE ONE PLACE A NAME'S SHAPE IS DECIDED. Every agent name, worktree, branch
# and evidence ref below, and every glob in sweep.sh, reconcile.py and
# watch-agents.py, reads these two segments instead of spelling the
# installation in again.
#
#   scoped (every installation created with an installation.toml that does
#   not say otherwise):
#     foreman/<installation>/<board>/<ticket>/<role>-<attempt>
#     foreman/<installation>/tick
#     $REPO/.claude/worktrees/foreman-<installation>-<board>-<ticket>
#     foreman/<installation>/<board>/<ticket>                (branch)
#     refs/foreman/<installation>/<board>/evidence/<n>
#
#   legacy (a home with no installation.toml, and the home `boardctl migrate`
#   writes with `names = "legacy"`):
#     foreman/<board>/<ticket>/<role>-<attempt>
#     foreman/tick
#     $REPO/.claude/worktrees/foreman-<board>-<ticket>
#     foreman/<board>/<ticket>                               (branch)
#     refs/foreman/<board>/evidence/<n>
#
# Legacy exists because a Claude home installed before installations has open
# pull requests on foreman/<board>/<ticket>. reconcile.py finds a card's pull
# request by that branch, so renaming it under a live card reads as "no PR"
# and the board builds the card again on top of the open one. The installation
# that already exists keeps its names; bin/installation.py refuses a second
# legacy sibling, and a legacy board named like a scoped sibling, because
# either one makes these globs match another installation's work.
#
# Assigned here, never read from the environment, for the reason LEGACY_NAMES
# is unset above. The same holds for every name composed from them:
# NAME_SCOPE, WORKTREE_SCOPE, BOARD_NAME_PREFIX, BOARD_WORKTREE_PREFIX and
# TICK_AGENT_NAME.
if [[ -n "$LEGACY_NAMES" ]]; then
  NAME_SCOPE=""
  WORKTREE_SCOPE=""
else
  NAME_SCOPE="$INSTALLATION/"
  WORKTREE_SCOPE="$INSTALLATION-"
fi
export FOREMAN_HOME FOREMAN_ROOT INSTALLATION HARNESS IS_DEFAULT LEGACY_NAMES NAME_SCOPE WORKTREE_SCOPE

# The adapter for this installation's harness: Claude Code, Codex or OpenCode.
# Every script that ran `claude` itself runs this instead, so one file knows
# how a CLI spells its flags. The five verbs are in
# docs/specs/2026-09-14-installations-per-harness-design.md.
#
# Refused HERE, where the installation is read, and not at the spawn. An
# adapter that is missing or not executable otherwise surfaces inside
# dispatch.sh, after the worktree is cut and the branch pushed, once for every
# card the board takes.
HARNESS_SH="$_foreman_install_root/skills/board/harness/$HARNESS.sh"
if [[ ! -x "$HARNESS_SH" ]]; then
  printf 'foreman: harness %s has no executable adapter at %s\n' "$HARNESS" "$HARNESS_SH" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
export HARNESS_SH

# Which board this is, where its repository is, and where its runtime lives.
#
# REPO used to be derived from this file's own `--git-common-dir`, which is
# right for a skill committed into the repository it builds and wrong for one
# installed once and pointed at many. The wrong answer was silent: the board
# would cut its worktrees inside its own installation. The board is now told
# which repository it serves, and refuses to guess.
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
# sweep.sh join the installation, the instance and the ticket with a HYPHEN
# (foreman-<installation>-<instance>-<ticket>), which an unconstrained instance
# name can absorb: INSTANCE=alpha-x makes "foreman-claude-alpha-x-PRA-1" match
# the glob "foreman-claude-alpha-*", so alpha's sweep would reap alpha-x's
# worktrees on a shared REPO. bin/installation.py applies this same rule to the
# installation segment, for this same reason.
# agent_name/branch_name/evidence_ref are `/`-delimited and safe
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
# Its absence is not a refusal any more. $FOREMAN_HOME/boards.toml is what
# declares which boards exist, so bin/boards.py is what refuses an unknown
# board, by name. This directory is derived state that a board which has never
# run has never created, and every writer of it -- card_log below,
# bin/resolve-ids.py -- makes it on first use. Refusing here would fail a
# freshly declared board's first tick with "no instance", which names the
# wrong problem.
INSTANCE_HOME="$FOREMAN_HOME/instances/$INSTANCE"
BOARD_HOME="${BOARD_HOME:-$INSTANCE_HOME}"

# This board's two name roots, composed once from the scope above. Every
# per-card name is one of these plus the ticket: the functions at the bottom of
# this file, sweep.sh's globs, and reconcile.py and watch-agents.py, which read
# both through reconcile.py's _load_config. Not environment-wins, for the
# reason NAME_SCOPE is not.
BOARD_NAME_PREFIX="foreman/$NAME_SCOPE$INSTANCE"
BOARD_WORKTREE_PREFIX="foreman-$WORKTREE_SCOPE$INSTANCE"

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

# What this installation declares about this board: REPO, and the KEY_FILE
# holding the credential for the Linear workspace that board lives in. Two
# facts, one file, $FOREMAN_HOME/boards.toml -- the Linear team and project come
# from the target repository's own board.toml below, because the repository
# declares itself and a second copy here would drift.
if ! _foreman_load_pairs "$FOREMAN_HOME/boards.toml" "$_foreman_install_root/bin/boards.py" "$INSTANCE"; then
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
if ! _foreman_load_pairs "$REPO/board.toml" "$_foreman_install_root/bin/contract.py" "$REPO/board.toml"; then
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
# contract.py emits "" for an absent cleanup.model: it deliberately depends on
# nothing and cannot see this installation's models, which is bin/installation.py's
# job. Unlike the four stage models above, an empty cleanup model has no
# "inherit the caller's model" reading of its own -- it means the plan's model,
# because a cleanup pass is graphplan's own work in miniature.
CLEANUP_MODEL="${CLEANUP_MODEL:-$PLAN_MODEL}"
# These three are deliberately NOT exported, like MAX_CONCURRENT and for the
# same reason. bin/load-pairs.sh resolves every key as
# `eval "$key=\"\${$key-\$value}\""`, so THE ENVIRONMENT WINS OVER THE
# CONTRACT: exporting them makes the first board a shell loads the authority on
# every board it loads afterwards. A board declaring `every_days = 0` -- the
# documented off switch -- would still get cleanups, and one declaring
# `max_plan_nodes = 0` would get its cleanup cards filed with no `needs-plan`
# and built unattended. Every consumer reads them in the sourcing shell
# instead: dispatch.sh sources this file, and reconcile.py and brief.py each
# use a same-shell `bash -c ". config.sh; printf ..."`.
# The list is named so a script that loops over boards -- supervise.sh asking
# starved.py about each one -- can strip exactly these from a child's
# environment. A hand-kept copy there leaks the first board's values into the
# next the day a name is added here.
FOREMAN_BOARD_EXPORTS="REPO KEY_FILE INSTANCE INSTANCE_HOME BOARD_HOME BOARD_NAME_PREFIX BOARD_WORKTREE_PREFIX"
# shellcheck disable=SC2086 # split on purpose: one name per word
export $FOREMAN_BOARD_EXPORTS

MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"

# One model per STAGE, because the stages need different things.
#
# The four values are loaded above, from bin/installation.py. The defaults this
# file used to hold now live there, because an installation declares its own:
# `claude` keeps exactly what was typed here (`fable`, `fable`, `opus`,
# `opus`), and a `codex` or `opencode` installation has no defaults at all and
# must name all four. A wrong model name on those two harnesses is not refused
# at the spawn -- the agent fails inside its own log and the card simply never
# moves -- so installation.py refuses an unnamed one in front of the operator.
#
# The TICK follows the prose in skills/board/SKILL.md and holds no state, so a
# tick that gets a pass wrong costs one pass: the next one re-derives every
# card's position from Linear, gh and git. It is not where strength is spent.
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
# The environment still wins over all four, with `-` and not `:-`, because
# _foreman_load_pairs applies `-` to every key it reads: `PLAN_MODEL=` must
# reach the CLI as an empty `--model`, which Claude Code reads as "inherit this
# session's model" -- the way back to the previous behaviour, and the same
# distinction every other override in this file makes.

# How many times a card may FAIL to be planned before it is parked, separate
# from MAX_BUILD_ATTEMPTS and MAX_PLAN_ROUNDS.
#
# MAX_PLAN_ROUNDS counts an operator revising a plan already posted -- the
# plan agent is doing its job, just not done yet. This counts the other kind
# of failure: the plan agent dies, times out, or never posts a valid comment
# at all, and a fresh attempt is dispatched from scratch. Sharing a counter
# with MAX_BUILD_ATTEMPTS would let a card that burned through failed plan
# attempts arrive at the build stage with its build budget already spent on
# a stage that never even produced a plan -- the card would then fail build
# almost immediately, for a reason that has nothing to do with the build
# agent. Keeping the two separate means a card that cannot be planned is
# parked for that reason, named as that reason, with the build budget still
# whole for the card that replaces it.
#
# `:-`, not `-`: this is a numeric cap like HOST_MAX_CONCURRENT below, not a
# value where an explicitly empty override must reach through -- there is no
# "disabled" reading of an empty attempt count, only a nonsensical one.
MAX_PLAN_ATTEMPTS="${MAX_PLAN_ATTEMPTS:-2}"

# The MACHINE's ceiling, across every instance of every installation sharing it
# -- not this repository's `MAX_CONCURRENT`, which is a per-instance limit
# declared in board.toml and has no idea another instance's cards exist. Two
# instances each dispatching up to their own MAX_CONCURRENT can still jointly
# exceed what one machine's RAM and /tmp can sustain, which is the same class of
# failure PROBE_TMP_MB/MIN_FREE_TMP_MB guard against for a single instance. A
# second installation is that same arithmetic again, on a harness this one
# cannot see.
#
# `reconcile.py --host-slots` does the counting, across every sibling's
# `instances/*/cards/` under $FOREMAN_ROOT, and nothing here counts anything:
# one number stays one number for the machine, and the file that can see every
# installation is the one that adds them up. This is the ceiling it is checked
# against before a dispatch, in addition to the instance's own MAX_CONCURRENT.
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
# This INSTALLATION runs ONE long-lived background agent executing the board
# skill on a loop. Cron does not run ticks — it runs supervise.sh, which only
# ensures that agent exists and is healthy. Keeping dispatch out of cron is
# deliberate: a watchdog that could also dispatch would double-dispatch the
# moment it misjudged liveness.
#
# The name carries the installation scope and no board segment, unlike
# agent_name, branch_name, worktree_path and evidence_ref below. There is ONE
# tick for every board this installation serves -- it walks them in turn -- so
# a per-board name would ask supervise.sh to keep N agents alive and let N
# ticks dispatch against one machine-wide HOST_MAX_CONCURRENT. The installation
# segment is the other half: a machine runs one tick per installation, on a
# different harness each, and two ticks named `foreman/tick` in one registry
# would each read the other as the one supervise.sh must stop before starting a
# replacement. The legacy installation keeps `foreman/tick`; installation.py
# allows only one of those per root, so the name stays unique.
#
# NOT environment-wins, unlike the knobs around it. Found in review on
# 2026-09-14: an operator shell exporting TICK_AGENT_NAME=foreman/tick gave a
# scoped sibling the legacy tick's name, and `supervise.sh --restart` there
# would stop the legacy installation's live tick.
TICK_AGENT_NAME="foreman/${NAME_SCOPE}tick"
TICK_INTERVAL_MINUTES="${TICK_INTERVAL_MINUTES:-20}"

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

# How long `supervise.sh --stop` and `--restart` wait for another supervisor to
# release the machine lock before refusing.
#
# Only an operator's gesture waits. A timer fire that finds the lock held stands
# down, because the next fire is TICK_INTERVAL_MINUTES away and loses nothing;
# nothing re-runs a gesture an operator typed, so standing down there reported
# success without restarting anything.
#
# 240 seconds because that exceeds the longest a supervisor can legitimately
# hold the lock: another operator's restart, which is TICK_DRAIN_SECONDS plus
# TICK_STOP_TIMEOUT_SECONDS plus TICK_START_TIMEOUT_SECONDS, 210 with the
# defaults. Waiting less would refuse a gesture that was only ever queued.
TICK_LOCK_WAIT_SECONDS="${TICK_LOCK_WAIT_SECONDS:-240}"

# How long supervise.sh waits for a tick it asked the adapter to `stop` to
# actually leave the registry, before refusing to start a replacement.
#
# THIS BOUND IS A CORRECTNESS BOUND, unlike TICK_DRAIN_SECONDS above. `stop` is
# not instantaneous and it can fail, and a replacement started beside a tick
# that never stopped gives one installation two ticks, both looping the board
# skill against one HOST_MAX_CONCURRENT -- the double-dispatch
# supervise.sh exists to prevent. Worse, it is invisible: the registry read
# reports only the NEWEST agent of that name, so every later fire sees the
# healthy replacement and never the survivor behind it. supervise.sh therefore
# proves EVERY live tick is gone BEFORE it starts a new one, and refuses when it
# cannot -- which leaves the machine with the ticks it already had.
#
# The stop is re-issued on every poll inside this bound, not once at the top:
# the tick whose stop is slowest to land is the wedged one the watchdog exists
# to replace, so one attempt followed by a wait gave up on the case that matters.
#
# 30 seconds is far longer than a `stop` takes on a healthy harness and short
# enough that an operator waiting on a restart is not left guessing.
TICK_STOP_TIMEOUT_SECONDS="${TICK_STOP_TIMEOUT_SECONDS:-30}"

# How long a ticket-mode sweep waits for a terminal card's idle agents to leave
# the registry after it asks `claude stop`, before leaving them and saying so.
#
# A background agent idles at `done` when its turn ends and nothing else ever
# stops it, so the sweep does, under the same rule as TICK_STOP_TIMEOUT_SECONDS:
# the stop is re-issued on every poll, and the registry -- never the exit code
# -- says when it landed. Past the bound the agent is left, its worktree and
# record with it, and the sweep exits non-zero. A session that lingers must not
# read as a clean sweep.
AGENT_STOP_TIMEOUT_SECONDS="${AGENT_STOP_TIMEOUT_SECONDS:-30}"

# How long `supervise.sh --restart` waits for the REPLACEMENT tick to appear in
# the agent registry before reporting failure.
#
# The adapter's `spawn` returns as soon as the agent is SPAWNED, so the
# "started" line supervise.sh prints is not evidence that a tick exists. A
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

# Settings every dispatched card agent -- plan, build, review, and a resumed
# build -- starts with, as the JSON string `claude --settings` takes. The tick
# does NOT get these; see below.
#
# `disableRemoteControl`: a `claude --bg` session registers a Remote Control
# session with the operator's claude.ai account, and that registration
# outlives the process. Measured 2026-09-14 on Claude Code 2.1.270: every
# agent one board had ever spawned, 932 of them, was still listed in the
# desktop app as "Remote Control · offline" after its process, its
# `~/.claude/jobs` record and its transcript were all gone. No CLI command,
# setting or API removes one; only archiving each by hand in the app does, and
# sweep.sh cannot reach it. So the registration has to not happen, at the one
# place every spawn passes through.
#
# Card agents only. The tick is the one session worth attaching to from a
# phone -- it is what runs the board -- and it is one row that restarts
# rarely. A card costs three to six rows every time it is built, and those are
# what filled the list. Passed per spawn rather than written into the
# operator's settings.json, so their own sessions on the machine keep Remote
# Control too.
#
# NOT REGISTERING BY DEFAULT ANY MORE. Measured 2026-09-16 on Claude Code
# 2.1.273: a plain `claude --bg` tick did not appear in the desktop app at all,
# so "the tick does not get this setting" no longer makes it visible. It is
# visible because supervise.sh asks for it by name, through the adapter's
# `--remote-control`. This setting stays on card agents regardless: it costs
# nothing on a version that does not register them, and a version that goes
# back to registering every `--bg` session would otherwise refill the list.
#
# dispatch.sh hands it to the harness adapter as `--settings`. Only Claude Code
# registers a Remote Control session, so only harness/claude.sh forwards it;
# the codex and opencode adapters accept it and drop it, because nothing on
# those harnesses registers with a claude.ai account for it to turn off.
CARD_AGENT_SETTINGS='{"disableRemoteControl":true}'

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
# $_foreman_install_root and kept, rather than derived a second time, because
# agent_tmp_for() below needs the identical path: two independent derivations
# of one path agree only until one of them is edited.
_foreman_tmp_dir_sh="$_foreman_install_root/bin/tmp-dir.sh"
if ! AGENT_TMP_ROOT="$(BOARD_HOME="$BOARD_HOME" "$_foreman_tmp_dir_sh" --root)"; then
  printf 'foreman: bin/tmp-dir.sh failed; cannot derive the agent scratch root\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

card_dir() { printf '%s/cards/%s\n' "$BOARD_HOME" "$1"; }
# The scratch dir paired with a worktree path. Same basename, so a sweep that
# reaps the worktree can reap the scratch without tracking anything.
# THIS INSTALLATION's bin/tmp-dir.sh -- see the comment above AGENT_TMP_ROOT.
agent_tmp_for() { BOARD_HOME="$BOARD_HOME" "$_foreman_tmp_dir_sh" "$1"; }
# Every name carries the installation and then the instance. The agent registry
# is one flat list shared by everything on this machine, matched by prefix in
# reconcile.py and sweep.sh and by regex in watch-agents.py; without the
# INSTANCE segment two boards reap each other's agents, and two projects may
# legitimately both use the team key PRA.
#
# The INSTALLATION segment closes the same hole one level up: two installations
# on this machine may serve one repository -- that is the point of running a
# second harness -- and they then share a board name, a ticket key, a REPO and
# so every worktree, branch and evidence ref under it. Without this segment the
# codex installation's sweep reaps the claude installation's worktree, and its
# dispatch pushes onto the branch a live build is committing to. The legacy
# installation goes without it; see NAME_SCOPE near the top of this file for
# why, and for the two refusals that keep it apart from its siblings.
#
# The prefix is its own function because sweep.sh matches on it: everything a
# card ever dispatched -- plan, build, review, every attempt and every resume
# fork -- shares `$BOARD_NAME_PREFIX/<ticket>/`, and a second spelling of that
# shape here or there is how a sweep starts missing sessions.
card_agents_prefix() { printf '%s/%s/\n' "$BOARD_NAME_PREFIX" "$1"; }
agent_name() { printf '%s%s-%s\n' "$(card_agents_prefix "$1")" "$2" "$3"; }
worktree_path() { printf '%s/.claude/worktrees/%s-%s\n' "$REPO" "$BOARD_WORKTREE_PREFIX" "$1"; }
branch_name() { printf '%s/%s\n' "$BOARD_NAME_PREFIX" "$1"; }
evidence_ref() { printf 'refs/%s/evidence/%s\n' "$BOARD_NAME_PREFIX" "$1"; }

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
