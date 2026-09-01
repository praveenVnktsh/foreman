#!/usr/bin/env bash
# Make this installation's skills resolvable to every Claude Code session.
#
#   install-skills.sh --dry-run   say what would change, change nothing
#   install-skills.sh             link them into ~/.claude/skills/
#   install-skills.sh --uninstall remove only the links this script made
#   install-skills.sh --force     replace a colliding skill, backing it up first
#
# WHY THIS EXISTS. A tick agent runs `/board`, and Claude Code resolves a skill
# by name from ~/.claude/skills/ -- never from wherever this repository happens
# to be installed. Without this step the loop looks installed and is not: the
# watchdog starts a tick, the tick asks for `/board`, and it either finds
# nothing or finds SOMEBODY ELSE'S skill of the same name and runs that instead.
# The second is worse and is not hypothetical: on 2026-09-01 a foreman tick
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
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

[[ -d "$SRC" ]] || die "no skills directory at $SRC"

# `ls` rather than a glob so an empty directory is an error we can name.
SKILLS="$(cd "$SRC" && ls -1 2>/dev/null || true)"
[[ -n "$SKILLS" ]] || die "$SRC is empty; nothing to install"

# Points at this install already? Then it is ours to replace without ceremony.
ours() {
  local link="$1" target
  [[ -L "$link" ]] || return 1
  target="$(cd -- "$(dirname -- "$link")" && readlink "$link")"
  case "$target" in "$SRC"/*) return 0 ;; *) return 1 ;; esac
}

report() { printf '  %-24s %s\n' "$1" "$2"; }

if [[ "$MODE" == "uninstall" ]]; then
  removed=0
  for name in $SKILLS; do
    link="$DEST/$name"
    if ours "$link"; then rm -f "$link"; report "$name" "removed"; removed=$((removed + 1))
    elif [[ -e "$link" ]]; then report "$name" "left alone; not installed by this script"
    fi
  done
  printf 'install-skills: removed %d link(s)\n' "$removed"
  exit 0
fi

mkdir -p "$DEST"
collisions=""
for name in $SKILLS; do
  link="$DEST/$name"
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    [[ "$MODE" == "dry" ]] && { report "$name" "would link"; continue; }
    ln -s "$SRC/$name" "$link"; report "$name" "linked"
  elif ours "$link"; then
    [[ "$MODE" == "dry" ]] && { report "$name" "already linked here"; continue; }
    report "$name" "already linked here"
  elif [[ "$MODE" == "force" ]]; then
    backup="$link.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$link" "$backup"; ln -s "$SRC/$name" "$link"
    report "$name" "replaced; previous kept at $(basename "$backup")"
  else
    collisions="$collisions $name"
    report "$name" "COLLISION -- a different skill already occupies $link"
  fi
done

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
