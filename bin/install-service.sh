#!/usr/bin/env bash
# Install the foreman watchdog as a systemd user timer.
#
#   install-service.sh --dry-run     print both units and change nothing
#   install-service.sh               write, enable and start them
#
# The timer runs supervise.sh, never a tick. supervise.sh starts the tick if it
# is missing and restarts it if it is wedged; it cannot dispatch a card. That
# separation is why this is safe to fire on a schedule -- see the comment at the
# top of skills/board/supervise.sh.
#
# A oneshot plus a timer, not a long-running service. The watchdog exits in
# under a second; a Type=simple unit would look "failed" every time it finished
# doing exactly its job.
#
# Lingering is the part everyone forgets. A user timer only runs while the user
# has a session unless `loginctl enable-linger` is set, so on a headless host the
# board silently stops at logout and nothing says so.
set -euo pipefail

die() { printf 'install-service: %s\n' "$*" >&2; exit 1; }

DRY=""
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ "$(uname -s)" == "Linux" ]] || die "systemd units are Linux-only; on macOS use launchd or cron (see skills/board/SKILL.md)"
command -v systemctl >/dev/null || die "systemctl not found; this host does not use systemd"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname -- "$HERE")"

# WHICH INSTALLATION THIS IS. bin/installation.py is the one place that derives
# name, home and harness from where this clone sits, so a second derivation
# here would be a copy that drifts from it -- the same reasoning bin/install.sh
# and bin/install-skills.sh give. bin/load-pairs.sh is the shared reader of its
# NUL-separated pairs and its comment carries the bash 3.2 temp-file rule. This
# is that reader, not a source of skills/board/config.sh: config.sh also picks a
# board, so it requires FOREMAN_INSTANCE, which a systemd unit for the whole
# installation's watchdog has no reason to know.
. "$INSTALL_ROOT/bin/load-pairs.sh" || die "cannot read $INSTALL_ROOT/bin/load-pairs.sh"

# This installation's own declaration, never the operator's shell: the reader
# lets the environment win, and a stray INSTALLATION would write units named
# for an installation this clone is not. FOREMAN_HOME is left alone --
# installation.py reads it itself to pick the home it answers for, which is how
# a test points this at a temporary directory.
unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT
_foreman_load_pairs "this installation's declaration" "$INSTALL_ROOT/bin/installation.py" \
  || die "installation.py could not read this installation's declaration"
[[ -n "$INSTALLATION" ]] || die "installation.py did not report an installation name"
[[ -n "$FOREMAN_HOME" ]] || die "installation.py did not report a home"
[[ -n "$HARNESS" ]] || die "installation.py did not report a harness"

# The unit names carry the installation: two installations on one machine each
# get their own service and timer, so enabling one never disables the other's
# and `systemctl --user stop foreman-<name>.timer` stops exactly one watchdog.
UNIT_NAME="foreman-$INSTALLATION"

HARNESS_SH="$INSTALL_ROOT/skills/board/harness/$HARNESS.sh"
[[ -x "$HARNESS_SH" ]] || die "no adapter at $HARNESS_SH for harness '$HARNESS'"

SUPERVISE="$INSTALL_ROOT/skills/board/supervise.sh"
[[ -x "$SUPERVISE" ]] || die "no supervise.sh at $SUPERVISE"

# Refuse to install a watchdog for nothing. An enabled timer with no board
# declared wakes every ten minutes forever to discover there is no work, which
# looks identical to a board that is merely quiet.
BOARDS="$(FOREMAN_HOME="$FOREMAN_HOME" "$INSTALL_ROOT/bin/boards.py" --list 2>/dev/null | tr '\0' '\n' | grep -c . || true)"
[[ "${BOARDS:-0}" -gt 0 ]] \
  || die "no boards declared in $FOREMAN_HOME/boards.toml; run 'boardctl add <name> --repo <path>' first"

# The tick runs `/board`, and the harness resolves a skill by name from its own
# skills-dir -- never from this install directory. A timer whose tick cannot
# find its own skill is the worst of both worlds: it looks installed, reports
# healthy, and does nothing. Worse, if some other project left a skill of the
# same name at that path, the tick runs THAT instead -- which happened on
# 2026-09-01, putting a second dispatcher on a live board.
SKILLS_DIR="$("$HARNESS_SH" skills-dir)"
[[ -n "$SKILLS_DIR" ]] || die "$HARNESS_SH skills-dir printed nothing"
BOARD_LINK="$SKILLS_DIR/board"
board_is_ours() {
  [[ -L "$BOARD_LINK" ]] || return 1
  case "$(cd -- "$(dirname -- "$BOARD_LINK")" && readlink "$BOARD_LINK")" in
    "$INSTALL_ROOT/skills"/*) return 0 ;; *) return 1 ;;
  esac
}
if ! board_is_ours; then
  if [[ -e "$BOARD_LINK" ]]; then
    die "$BOARD_LINK exists but is not this installation's board skill.
A tick started now would run that skill instead of this one. Inspect it, then run
  $INSTALL_ROOT/bin/install-skills.sh          (refuses to replace it)
  $INSTALL_ROOT/bin/install-skills.sh --force  (replaces it, keeping a backup)"
  fi
  die "this installation's skills are not resolvable; a tick could not find /board.
Run: $INSTALL_ROOT/bin/install-skills.sh"
fi

UNIT_DIR="$HOME/.config/systemd/user"

# THE PRE-INSTALLATIONS WATCHDOG, still enabled beside this one. It is named
# plain `foreman`, this one `foreman-$INSTALLATION`, so systemd sees two
# unrelated units and starts both. Its ExecStart names the install/ directory
# `boardctl migrate` moved, so it wakes every ten minutes and fails for as long
# as it is enabled -- and a machine whose board is healthy grows a permanently
# red unit that nobody can explain. `boardctl migrate` prints the disable as
# its third step; this is what happens when that step is skipped.
#
# NOTHING IS DELETED HERE. The operator did not ask for a file to be removed,
# and a unit file is the only record of what the old watchdog was.
for legacy in foreman.service foreman.timer; do
  [[ -e "$UNIT_DIR/$legacy" ]] || continue
  die "$UNIT_DIR/$legacy is the pre-installations watchdog, and it is still installed.
It runs the install/ directory that migration moved, so it fails every fire, and
enabling $UNIT_NAME.timer beside it would leave two watchdogs on this machine.
Disable it first, then run this again:
  systemctl --user disable --now foreman.timer
The unit files are left where they are; remove them by hand once you are sure."
done

service_unit() {
  cat <<UNIT
[Unit]
Description=foreman watchdog for installation '$INSTALLATION' ($HARNESS; keeps one tick alive for every declared board)
Documentation=file://$INSTALL_ROOT/skills/board/SKILL.md

[Service]
Type=oneshot
# Signal only this unit's own main process. The default, KillMode=control-group,
# kills every process left in the cgroup when the unit deactivates, and a
# oneshot deactivates as soon as ExecStart returns -- a second after
# supervise.sh has spawned the tick. On a host where nothing had started the
# shared claude daemon yet, 'claude --bg' starts it inside this unit's cgroup,
# and every card agent that daemon later spawns lives there too. Under the
# default, 'systemctl --user restart foreman.service' -- the gesture an operator
# reaches for -- kills every in-flight build on the machine, and the ordinary
# timer fire kills the tick it just started.
KillMode=process
WorkingDirectory=$INSTALL_ROOT
Environment=FOREMAN_HOME=$FOREMAN_HOME
# systemd gives a user unit a minimal PATH. The claude CLI usually lives under
# ~/.local/bin, and without it the watchdog finds nothing to run and the board
# simply stops, with a log full of "command not found".
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$SUPERVISE
UNIT
}

timer_unit() {
  cat <<UNIT
[Unit]
Description=foreman watchdog for installation '$INSTALLATION' every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
# A host that sleeps would otherwise skip every fire it was off for, and the
# tick would stay dead until someone noticed.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

if [[ -n "$DRY" ]]; then
  printf '=== %s/%s.service ===\n' "$UNIT_DIR" "$UNIT_NAME"; service_unit
  printf '\n=== %s/%s.timer ===\n' "$UNIT_DIR" "$UNIT_NAME"; timer_unit
  printf '\nwould run: systemctl --user daemon-reload\n'
  printf 'would run: systemctl --user enable --now %s.timer\n' "$UNIT_NAME"
  printf 'would run: loginctl enable-linger %s\n' "$(whoami)"
  exit 0
fi

mkdir -p "$UNIT_DIR"
service_unit > "$UNIT_DIR/$UNIT_NAME.service"
timer_unit   > "$UNIT_DIR/$UNIT_NAME.timer"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME.timer"

# Without lingering the timer stops at logout. Report rather than fail: enabling
# it can need a password, and a timer that runs while logged in is still better
# than no timer at all.
if ! loginctl show-user "$(whoami)" 2>/dev/null | grep -q 'Linger=yes'; then
  printf 'install-service: lingering is OFF. The timer stops at logout.\n'
  printf 'install-service: enable it with: sudo loginctl enable-linger %s\n' "$(whoami)"
fi

printf 'install-service: installed %s. Next fire: %s\n' "$UNIT_NAME" \
  "$(systemctl --user list-timers "$UNIT_NAME.timer" --no-pager --no-legend 2>/dev/null | head -1 || echo unknown)"
