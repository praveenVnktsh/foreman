#!/usr/bin/env bash
# Fast-forward this installation's clone to its tracked ref and restart its tick.
# The ref is FOREMAN_UPDATE_REF, default origin/main; a release pin sets it to
# origin/release, so a merge to main reaches this installation only when the
# release is promoted (bin/release.sh).
#
#   self-update.sh --dry-run   say what it would do, change nothing
#   self-update.sh             do it
#
# FOREMAN UPDATES ITSELF BY PULLING. Nothing inbound ever executes on this
# host: CI runs on GitHub-hosted runners, and the only way a merged commit
# reaches an installation is the installation fetching it. That is the whole
# design, and it is why there is no deploy workflow to read. A self-hosted
# Actions runner would be the alternative, and on a public repository it hands
# a stranger's fork the user that owns this machine's gh token, its harness
# sessions and every board instance under ~/.foreman -- `pull_request` builds
# the contributor's branch, and the workflow file is a file in that branch.
#
# THIS SCRIPT NEVER MERGES, REBASES OR RESETS. A fast-forward is the only
# update it performs, so an operator's clone can never be rewritten under them
# by a timer. Everything it cannot do that way, it refuses.
set -euo pipefail

die() { printf 'self-update: %s\n' "$*" >&2; exit 1; }

# WHY THIS SCRIPT RE-EXECS A COPY OF ITSELF, before anything else happens.
#
# bash reads a script INCREMENTALLY as it executes it, seeking by byte offset.
# This file lives inside the clone it is about to fast-forward, so a pull that
# rewrites bin/self-update.sh while bash is still reading it makes bash resume
# at an offset into DIFFERENT CONTENT -- executing a fragment of some other
# line, with no error and no way to notice. The longer this file grows, the
# likelier that is: only the part bash has already buffered is safe.
#
# So the real work always runs from a copy outside the clone, and the copy
# deletes itself on the way out. The copy is made unconditionally rather than
# only on the update path: one code path is worth more here than one saved
# file copy per fire, and "did we re-exec in time" is not a question anyone
# should have to answer while reading this.
#
# FOREMAN_SELF_UPDATE_ROOT carries the install root across the exec, because
# the copy's own $0 is in a temp directory and can no longer derive it.
if [[ -z "${FOREMAN_SELF_UPDATE_ROOT:-}" ]]; then
  HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  copy="$(mktemp)" || die "mktemp failed; cannot copy this script out of the clone"
  cat -- "${BASH_SOURCE[0]}" >"$copy" || die "could not copy this script to $copy"
  FOREMAN_SELF_UPDATE_ROOT="$(dirname -- "$HERE")" \
    exec bash "$copy" "$@"
fi
INSTALL_ROOT="$FOREMAN_SELF_UPDATE_ROOT"
trap 'rm -f -- "$0"' EXIT

MODE="${1:-run}"

# The usage block in this file's own header is the only copy, for the reason
# skills/board/supervise.sh gives: a second one in a here-doc drifts the day a
# mode is added, and the operator who just mistyped a flag is shown the older
# of the two.
usage() { sed -n 's/^#   \(self-update\.sh.*\)/  \1/p' "$0"; }

case "$MODE" in
  run|--dry-run) ;;
  *)
    printf 'self-update: unrecognised argument %s\n' "$MODE" >&2
    usage >&2
    exit 2
    ;;
esac
DRY=""
[[ "$MODE" == "--dry-run" ]] && DRY=1

# WHICH INSTALLATION THIS IS. bin/installation.py is the one place that derives
# name, home and harness from where this clone sits, so a second derivation
# here would be a copy that drifts from it -- the same reasoning
# bin/install-service.sh, bin/install.sh and bin/install-skills.sh all give.
# bin/load-pairs.sh is the shared reader of its NUL-separated pairs and its
# comment carries the bash 3.2 temp-file rule.
. "$INSTALL_ROOT/bin/load-pairs.sh" || die "cannot read $INSTALL_ROOT/bin/load-pairs.sh"

# This installation's own declaration, never the operator's shell: the reader
# lets the environment win, and a stray INSTALLATION would restart a tick this
# clone does not own. FOREMAN_HOME is left alone -- installation.py reads it
# itself to pick the home it answers for, which is how a test points this at a
# temporary directory.
unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT
_foreman_load_pairs "this installation's declaration" "$INSTALL_ROOT/bin/installation.py" \
  || die "installation.py could not read this installation's declaration"
[[ -n "$INSTALLATION" ]] || die "installation.py did not report an installation name"
[[ -n "$FOREMAN_HOME" ]] || die "installation.py did not report a home"

# WHICH REF THIS INSTALLATION TRACKS. Default origin/main. An installation
# pinned to a release sets FOREMAN_UPDATE_REF=origin/release (written into its
# unit by bin/install-self-update.sh --ref), so a merge to main reaches it only
# when the release is promoted with bin/release.sh. See docs/INSTALLING.md.
#
# The local clone stays on its own branch; a fast-forward to origin/release
# advances that branch to the released commit. The ref is never interpolated
# into a shell, but it is validated anyway: git would accept some of these as
# revision syntax, and a typo should name itself rather than fetch something
# else.
UPDATE_REF="${FOREMAN_UPDATE_REF:-origin/main}"
case "$UPDATE_REF" in
  origin/*) ;;
  *) die "FOREMAN_UPDATE_REF must look like origin/<branch>, got '$UPDATE_REF'" ;;
esac
UPDATE_BRANCH="${UPDATE_REF#origin/}"
case "$UPDATE_BRANCH" in
  ""|*" "*|*".."*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@"*)
    die "FOREMAN_UPDATE_REF names an invalid branch: '$UPDATE_BRANCH'" ;;
esac

SUPERVISE="$INSTALL_ROOT/skills/board/supervise.sh"
[[ -x "$SUPERVISE" ]] || die "no supervise.sh at $SUPERVISE; this clone is not a foreman install root"

git_ro() { git -C "$INSTALL_ROOT" "$@"; }

git_ro rev-parse --git-dir >/dev/null 2>&1 \
  || die "$INSTALL_ROOT is not a git repository; expected the clone bin/install.sh made"

# EVERY REFUSAL BELOW LEAVES THE CLONE EXACTLY AS IT FOUND IT. A timer that
# fires every few minutes must never be the thing that loses an operator's
# work, so each of these is a stop, not a recovery.

# A clone parked on a branch is somebody mid-investigation. Fast-forwarding it
# to origin/main would move them off whatever they were reading, silently.
BRANCH="$(git_ro symbolic-ref --short -q HEAD || true)"
[[ -n "$BRANCH" ]] || die "the clone has a detached HEAD; expected it on main"
[[ "$BRANCH" == "main" ]] || die "the clone is on '$BRANCH'; expected main. Nothing was changed."

# Local modifications to TRACKED files are never discarded here. --ff-only
# would refuse a conflicting pull anyway, but it would refuse AFTER the fetch
# and with git's wording, which does not say whose edits are at stake.
#
# UNTRACKED FILES DO NOT BLOCK AN UPDATE, and --untracked-files=no is what says
# so. Measured on 2026-09-16, deploying this to its first real machine: one of
# three installations there had a stray 25KB API-response dump sitting in its
# install root, written by nothing in this repository. Under a bare
# `status --porcelain` that clone was permanently dirty, so it would have
# refused every fire for ever -- an installation that silently stops updating
# because of a file nobody remembers leaving there.
#
# It is safe because a fast-forward cannot quietly eat an untracked file: if an
# incoming commit adds a path that exists untracked in the tree, git aborts the
# merge itself with "untracked working tree file would be overwritten", before
# moving HEAD. The refusal below is about an operator's EDITS, and an untracked
# file is not an edit to anything this repository ships.
DIRTY="$(git_ro status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" ]]; then
  printf 'self-update: the clone at %s has local modifications; expected a clean tree.\n' "$INSTALL_ROOT" >&2
  printf 'self-update: nothing was changed. What is dirty:\n%s\n' "$DIRTY" >&2
  exit 1
fi

# A DRY RUN STILL FETCHES. It cannot answer "what would this do" without
# knowing what origin/main is, and there is no read-only way to learn that. A
# fetch writes only remote-tracking refs: it moves refs/remotes/origin/*, never
# the working tree, HEAD or any local branch. So the dry run's one side effect
# is the same one an operator's own `git fetch` has.
# THE FETCH MUST NOT BE ABLE TO HANG, and these four options are why.
#
# Measured on 2026-09-16, the first time this ran from a systemd timer rather
# than a terminal: three installations fired within two seconds of each other,
# and all three `git fetch` processes stalled -- connected to the remote, then
# silent. They were still stalled two minutes later. A fresh run a moment
# afterwards completed in two seconds, so this is a transient the network can
# produce at any time, not a broken credential.
#
# What made it serious is what a stall does to the timer. A `Type=oneshot`
# service that never finishes stays `activating` for ever, and systemd will not
# compute the next elapse of a timer whose service has not finished:
# `NextElapseUSecMonotonic=infinity`. One stalled fetch therefore does not cost
# one update -- it silently ends every future update for that installation, and
# nothing anywhere reports it. A board would go on ticking healthily against
# code that quietly stopped being refreshed.
#
# So a stall has to end by itself, here, rather than being something the unit
# is asked to survive:
#   BatchMode=yes          a missing or passphrased key fails now, not at a
#                          prompt nobody can answer under systemd
#   ConnectTimeout         bounds the connect
#   ServerAlive*           bounds the SILENCE AFTER connecting, which is the
#                          case actually observed; without it ssh waits for
#                          ever on a peer that has stopped talking
#   GIT_TERMINAL_PROMPT=0  the same guarantee for an https remote, which would
#                          otherwise block asking for a username
#
# ssh's own options rather than timeout(1): macOS ships no timeout(1), and this
# suite runs there as well as on Linux. bin/install-self-update.sh sets
# TimeoutStartSec as a second, unconditional backstop for anything these miss.
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
GIT_TERMINAL_PROMPT=0 \
  git_ro fetch --quiet origin "$UPDATE_BRANCH" \
  || die "git fetch $UPDATE_REF failed or timed out; expected a reachable origin and a credential usable with no terminal. Nothing was changed."

OLD="$(git_ro rev-parse HEAD)"
NEW="$(git_ro rev-parse FETCH_HEAD)"
OLD_SHORT="$(git_ro rev-parse --short "$OLD")"
NEW_SHORT="$(git_ro rev-parse --short "$NEW")"

# NOTHING TO DO IS THE COMMON CASE, and it must not restart the tick. A timer
# that restarted on every fire would kill and respawn the tick every few
# minutes forever, and a board whose tick is always seconds old looks healthy
# while getting nothing done.
if [[ "$OLD" == "$NEW" ]]; then
  printf 'self-update: %s is already at %s; nothing to do.\n' "$INSTALLATION" "$OLD_SHORT"
  exit 0
fi

# A force-push, or a clone that has diverged. Either way the update is not a
# fast-forward, and this script has no business deciding what to keep.
git_ro merge-base --is-ancestor "$OLD" "$NEW" \
  || die "$UPDATE_REF ($NEW_SHORT) is not a descendant of HEAD ($OLD_SHORT); expected a fast-forward. Nothing was changed."

# WHICH SKILLS EXIST, as a sorted list of directory names under skills/.
#
# bin/install-skills.sh links skills with SYMLINKS, not copies, precisely so
# the links cannot drift from the clone -- a fast-forward moves the code under
# a link that keeps pointing at it. So an ordinary update needs NO relink.
# What a link cannot follow is a skill whose DIRECTORY APPEARS OR DISAPPEARS,
# because the links are one per skill name. That, and only that, is what this
# compares.
skill_names() { git_ro ls-tree --name-only "$1" -- skills/ | sed 's#^skills/##; s#/.*##' | sort -u; }
SKILLS_BEFORE="$(skill_names "$OLD")"
SKILLS_AFTER="$(skill_names "$NEW")"

if [[ -n "$DRY" ]]; then
  printf 'self-update: would fast-forward %s from %s to %s\n' "$INSTALLATION" "$OLD_SHORT" "$NEW_SHORT"
  if [[ "$SKILLS_BEFORE" != "$SKILLS_AFTER" ]]; then
    printf 'would run: %s/bin/install-skills.sh   (the set of skills changed)\n' "$INSTALL_ROOT"
  else
    printf 'would not run install-skills.sh; the set of skills is unchanged\n'
  fi
  printf 'would run: %s --restart\n' "$SUPERVISE"
  exit 0
fi

git_ro merge --ff-only "$NEW" >/dev/null \
  || die "the fast-forward to $NEW_SHORT failed; see the error above. The clone is unchanged."

RELINKED="no"
if [[ "$SKILLS_BEFORE" != "$SKILLS_AFTER" ]]; then
  "$INSTALL_ROOT/bin/install-skills.sh" \
    || die "fast-forwarded to $NEW_SHORT, but install-skills.sh failed. The tick was NOT restarted; it is still running $OLD_SHORT."
  RELINKED="yes"
fi

# supervise.sh --restart replaces the tick and leaves in-flight cards alone.
# It is the only correct way to pick up new code: `systemctl --user restart`
# on the watchdog finds a healthy tick and leaves it running the code it
# started with, which is the failure AGENTS.md's "What to use" table names.
#
# FOREMAN_HOME is the only variable it needs from here, exactly as the unit
# bin/install-service.sh writes passes it.
FOREMAN_HOME="$FOREMAN_HOME" "$SUPERVISE" --restart \
  || die "fast-forwarded to $NEW_SHORT, but supervise.sh --restart failed. The clone is updated and the tick may still be running $OLD_SHORT."

printf 'self-update: %s %s -> %s; skills relinked: %s; tick restarted.\n' \
  "$INSTALLATION" "$OLD_SHORT" "$NEW_SHORT" "$RELINKED"
