#!/usr/bin/env bash
# Make foreman's skills resolvable to its harness.
#
#   install-skills.sh --dry-run   say what would change, change nothing
#   install-skills.sh             link them into the harness's skill directory
#   install-skills.sh --uninstall remove only the links this script made
#   install-skills.sh --force     replace a colliding skill, backing it up first
#
# WHY THIS EXISTS. A tick agent runs the board skill through whichever harness
# this foreman declares, and each harness resolves skills by name from its
# own directory -- never from wherever this repository happens to be installed.
# Without this step the loop looks installed and is not: the watchdog starts a
# tick, the tick asks for the board skill, and the harness either finds nothing
# or finds SOMEBODY ELSE'S skill of the same name and runs that instead. The
# second is worse and is not hypothetical: on 2026-09-01 a foreman tick
# resolved `/board` to a different project's board skill left at that path and
# ran its loop against a live board, as a second dispatcher.
#
# SYMLINKS, NOT COPIES. The install directory is already the pin -- README.md:
# "The running loop uses the installed clone, never a working tree", and
# `git -C ~/.foreman/install pull` moves the pin deliberately. A copy here would
# be a SECOND pin that drifts from the first, and the failure is silent: skills
# one version behind the code that calls them. A link cannot drift.
set -euo pipefail

die() { printf 'install-skills: %s\n' "$*" >&2; exit 1; }

MODE="install"
case "${1:-}" in
  --dry-run)   MODE="dry" ;;
  --uninstall) MODE="uninstall" ;;
  --force)     MODE="force" ;;
  "")          ;;
  *)           die "unknown argument: $1 (expected --dry-run, --uninstall or --force)" ;;
esac

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname -- "$HERE")"
SRC="$INSTALL_ROOT/skills"

# WHICH HARNESS, AND WHICH HOME. bin/installation.py is the one place that
# derives both from where this clone sits, so a second derivation here would
# be a copy that drifts from it -- exactly the failure bin/install.sh's own
# comment names. bin/load-pairs.sh is the shared reader of its NUL-separated
# pairs and its comment carries the bash 3.2 temp-file rule. This is that
# reader, not a source of skills/board/config.sh: config.sh also picks a
# board, so it requires FOREMAN_INSTANCE, which installing skills has no
# reason to know.
. "$INSTALL_ROOT/bin/load-pairs.sh" || die "cannot read $INSTALL_ROOT/bin/load-pairs.sh"

# Foreman's own declaration, never the operator's shell: the reader
# lets the environment win, and a stray HARNESS would link these skills into a
# harness this clone does not run. FOREMAN_HOME is left alone -- installation.py
# reads it itself to pick the home it answers for, which is how a test points
# this at a temporary directory.
unset HARNESS FOREMAN_ROOT
_foreman_load_pairs "foreman's declaration" "$INSTALL_ROOT/bin/installation.py" \
  || die "installation.py could not read foreman's declaration"
[[ -n "$HARNESS" ]] || die "installation.py did not report a harness"
[[ -n "$FOREMAN_HOME" ]] || die "installation.py did not report a home"

HARNESS_SH="$INSTALL_ROOT/skills/board/harness/$HARNESS.sh"
[[ -x "$HARNESS_SH" ]] || die "no adapter at $HARNESS_SH for harness '$HARNESS'"
DEST="$("$HARNESS_SH" skills-dir)"
[[ -n "$DEST" ]] || die "$HARNESS_SH skills-dir printed nothing"

# WHERE THE MANIFEST LIVES, AND WHY IT IS NOT THE OBVIOUS PLACE. The manifest
# describes this foreman, so it belongs with foreman's own state.
# It does not belong at either end of the link, and both mistakes are on record.
#
#   * Not `$DEST/<name>/`. That path is a SYMLINK into $SRC, so writing "the
#     manifest next to the installed skill" writes THROUGH the link and lands
#     the file inside the install clone -- an untracked file in the one
#     repository whose whole job is to be a clean pin. Found on 2026-09-08:
#     `~/.claude/skills/board` was a link to the clone and `.installed.json`
#     was sitting in the clone's own skills/board directory.
#   * Not `$DEST/` either. That is the harness's directory, shared with every
#     other project that installs a skill of its own. One manifest filename
#     there means two installers taking turns overwriting each other's record.
#     That is how the 2026-09-08 manifest came to list `question.py`, a file
#     belonging to a DIFFERENT project's board skill, as something this install
#     had put there.
#
# $FOREMAN_HOME is foreman's state root -- the same one bin/boardctl
# and bin/install-service.sh use -- and it is not shared with anyone.
MANIFEST="$FOREMAN_HOME/installed-skills"

[[ -d "$SRC" ]] || die "no skills directory at $SRC"

# `ls` rather than a glob so an empty directory is an error we can name.
SKILLS="$(cd "$SRC" && ls -1 2>/dev/null || true)"
[[ -n "$SKILLS" ]] || die "$SRC is empty; nothing to install"

# A skill name has to be typed after a slash to invoke it, and every loop here
# relies on word-splitting a newline-joined list. A name with a space in it
# splits into two names that both look fine, so the manifest would record two
# skills that do not exist and neither would resolve. Refuse it by name.
usable() { case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

while IFS= read -r name; do
  usable "$name" || die "unusable skill name in $SRC: '$name' (letters, digits, '.', '_' and '-' only)"
done <<<"$SKILLS"

# What the last run recorded. Absent on a first install, which is not an error.
# The manifest is NOT the authority on ownership -- `ours` below reads the link
# itself, which cannot go stale. The manifest answers the one question the link
# cannot: which names this install put at $DEST that it no longer ships.
#
# One name per line and nothing else. This script is the bootstrap step on a
# fresh machine, so its state file has to be readable without python3, a JSON
# parser, or anything else that is not installed yet.
PREVIOUS=""
if [[ -f "$MANIFEST" ]]; then PREVIOUS="$(cat "$MANIFEST")"; fi

# Points at this install already? Then it is ours to replace without ceremony.
ours() {
  local link="$1" target
  [[ -L "$link" ]] || return 1
  target="$(cd -- "$(dirname -- "$link")" && readlink "$link")"
  case "$target" in "$SRC"/*) return 0 ;; *) return 1 ;; esac
}

# Is <name> one of the newline-separated names in <list>? `case` rather than
# grep, so a name is never read as a pattern.
listed() {
  local needle="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<<"$2"
  return 1
}

# Names this install recorded last time and does not ship now. Every other loop
# here walks $SRC, so nothing else would ever visit them: the link outlives the
# skill and keeps resolving, either to a path the pin has deleted or to one a
# later pin refills with something else entirely. An install must not leave
# behind a file it did not put there on this run.
dropped() {
  local name
  [[ -n "$PREVIOUS" ]] || return 0
  while IFS= read -r name; do
    usable "$name" || continue
    listed "$name" "$SKILLS" || printf '%s\n' "$name"
  done <<<"$PREVIOUS"
}
DROPPED="$(dropped)"

report() { printf '  %-24s %s\n' "$1" "$2"; }

# Replace the manifest through a temporary file. A write cut short half way
# leaves a manifest that under-reports what this install owns, and the next
# uninstall then walks past its own links and leaves them behind.
write_manifest() {
  local tmp
  mkdir -p "$FOREMAN_HOME"
  tmp="$MANIFEST.new.$$"
  printf '%s' "$1" > "$tmp"
  mv -f "$tmp" "$MANIFEST"
}

if [[ "$MODE" == "uninstall" ]]; then
  removed=0
  for name in $SKILLS $DROPPED; do
    link="$DEST/$name"
    if ours "$link"; then rm -f "$link"; report "$name" "removed"; removed=$((removed + 1))
    elif [[ -e "$link" ]]; then report "$name" "left alone; not installed by this script"
    fi
  done
  rm -f "$MANIFEST"
  printf 'install-skills: removed %d link(s)\n' "$removed"
  exit 0
fi

for name in $DROPPED; do
  link="$DEST/$name"
  if ours "$link"; then
    if [[ "$MODE" == "dry" ]]; then report "$name" "would remove; no longer in this install"; continue; fi
    rm -f "$link"; report "$name" "removed; no longer in this install"
  elif [[ -e "$link" || -L "$link" ]]; then
    report "$name" "left alone; no longer ours"
  fi
done

mkdir -p "$DEST"
collisions=""
installed=""
for name in $SKILLS; do
  link="$DEST/$name"
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    [[ "$MODE" == "dry" ]] && { report "$name" "would link"; continue; }
    ln -s "$SRC/$name" "$link"; report "$name" "linked"
    installed="$installed$name"$'\n'
  elif ours "$link"; then
    [[ "$MODE" == "dry" ]] && { report "$name" "already linked here"; continue; }
    report "$name" "already linked here"
    installed="$installed$name"$'\n'
  elif [[ "$MODE" == "force" ]]; then
    backup="$link.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$link" "$backup"; ln -s "$SRC/$name" "$link"
    report "$name" "replaced; previous kept at $(basename "$backup")"
    installed="$installed$name"$'\n'
  else
    collisions="$collisions $name"
    report "$name" "COLLISION -- a different skill already occupies $link"
  fi
done

# Record before refusing, not after. A run that links three skills and refuses
# on the fourth still put three links at $DEST, and a manifest written only on
# the happy path would forget them.
[[ "$MODE" == "dry" ]] || write_manifest "$installed"

if [[ -n "$collisions" ]]; then
  # Refuse rather than replace. A skill of the same name at that path is very
  # likely another project's live loop, and clobbering it stops that project
  # dead with no message. `--force` keeps a timestamped copy of whatever it
  # moves aside, so the decision is recoverable but never silent.
  die "refusing to replace:$collisions
Each is a directory or link this script did not create. Inspect it, then either
move it aside yourself or re-run with --force, which backs it up first."
fi

[[ "$MODE" == "dry" ]] && { printf 'install-skills: dry run; nothing changed\n'; exit 0; }
printf 'install-skills: %s is now resolvable from %s\n' "$(echo $SKILLS | tr ' ' ',')" "$DEST"
