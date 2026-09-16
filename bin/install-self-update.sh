#!/usr/bin/env bash
# Install this installation's self-updater as a systemd user timer.
#
#   install-self-update.sh --dry-run   print both units and change nothing
#   install-self-update.sh             write, enable and start them
#
# This file is to bin/self-update.sh what bin/install-service.sh is to
# skills/board/supervise.sh, and it is deliberately the same shape. The two
# timers are separate because they answer different questions: the watchdog
# asks "is a tick alive", the updater asks "is this clone current". A machine
# can want either without the other -- an installation pinned to a known
# commit still wants its watchdog.
set -euo pipefail

die() { printf 'install-self-update: %s\n' "$*" >&2; exit 1; }

DRY=""
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ "$(uname -s)" == "Linux" ]] || die "systemd units are Linux-only; expected a Linux host. On macOS use launchd or cron to run bin/self-update.sh"
command -v systemctl >/dev/null || die "systemctl not found; expected a systemd host"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname -- "$HERE")"

# WHICH INSTALLATION THIS IS, derived the one place it is derived: see
# bin/install-service.sh's comment, which this follows rather than repeats.
. "$INSTALL_ROOT/bin/load-pairs.sh" || die "cannot read $INSTALL_ROOT/bin/load-pairs.sh"

unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT
_foreman_load_pairs "this installation's declaration" "$INSTALL_ROOT/bin/installation.py" \
  || die "installation.py could not read this installation's declaration"
[[ -n "$INSTALLATION" ]] || die "installation.py did not report an installation name"
[[ -n "$FOREMAN_HOME" ]] || die "installation.py did not report a home"

UPDATER="$INSTALL_ROOT/bin/self-update.sh"

# REFUSE TO SCHEDULE SOMETHING THAT CANNOT RUN. A timer whose ExecStart is
# missing fails every fire, and a machine whose board is healthy grows a
# permanently red unit nobody can explain -- the failure bin/install-service.sh
# describes for the pre-installations watchdog.
[[ -x "$UPDATER" ]] || die "no executable self-updater at $UPDATER"
git -C "$INSTALL_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$INSTALL_ROOT is not a git repository; there is nothing for a self-updater to fast-forward"

# self-update.sh's OWN refusals -- a dirty clone, a clone off main, a
# force-pushed origin -- are deliberately not repeated here. They are
# conditions at FIRE time, not at install time: a clone that is dirty this
# afternoon is the normal state of a machine someone is working on, and
# refusing to install a timer over it would be refusing the wrong question.
# One fact, one place.

# THE UNIT NAMES CARRY THE INSTALLATION, for the reason install-service.sh
# gives: two installations on one machine must each be startable and stoppable
# alone. They also carry `update`, so the pair is distinguishable at a glance
# from that installation's watchdog in `systemctl --user list-timers`.
#
# The segment order matters. `foreman-update-<installation>` can never collide
# with install-service.sh's `foreman-<installation>`, whatever an installation
# is called: reaching this name from there would need an installation named
# `update-<installation>`, which yields `foreman-update-update-<installation>`
# here, not this.
UNIT_NAME="foreman-update-$INSTALLATION"
UNIT_DIR="$HOME/.config/systemd/user"

service_unit() {
  cat <<UNIT
[Unit]
Description=foreman self-updater for installation '$INSTALLATION' (fast-forwards the clone, restarts the tick)
Documentation=file://$INSTALL_ROOT/README.md

[Service]
Type=oneshot
# Signal only this unit's own main process, for the reason
# bin/install-service.sh gives at length: self-update.sh runs supervise.sh,
# which spawns the tick, and a oneshot deactivates the moment ExecStart
# returns -- a second after the tick was started. Under the default
# KillMode=control-group, every process left in the cgroup is killed then, so
# each fire that updated anything would kill the very tick it just started,
# and with it every card agent sharing that cgroup.
KillMode=process
WorkingDirectory=$INSTALL_ROOT
Environment=FOREMAN_HOME=$FOREMAN_HOME
# systemd gives a user unit a minimal PATH. supervise.sh runs the harness CLI,
# which usually lives under ~/.local/bin; without it the restart finds nothing
# to run and the board stops, with a log full of "command not found".
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$UPDATER
UNIT
}

timer_unit() {
  cat <<UNIT
[Unit]
Description=foreman self-updater for installation '$INSTALLATION' every 5 minutes

[Timer]
OnBootSec=3min
# Five minutes is a choice about how long a merged card should take to reach
# the machine that merged it. A fire that finds nothing costs one fetch of one
# branch and exits without touching the clone, so the poll is cheap enough to
# be frequent; the expensive part -- the restart -- happens only when the SHA
# actually moved.
OnUnitActiveSec=5min
# A host that sleeps would otherwise skip every fire it was off for, and the
# clone would stay behind until someone noticed.
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
  exit 0
fi

mkdir -p "$UNIT_DIR"
service_unit > "$UNIT_DIR/$UNIT_NAME.service"
timer_unit   > "$UNIT_DIR/$UNIT_NAME.timer"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME.timer"

# Without lingering the timer stops at logout, exactly as install-service.sh
# reports for the watchdog. Report rather than fail: enabling it can need a
# password, and an updater that runs while logged in beats none at all.
if ! loginctl show-user "$(whoami)" 2>/dev/null | grep -q 'Linger=yes'; then
  printf 'install-self-update: lingering is OFF. The timer stops at logout.\n'
  printf 'install-self-update: enable it with: sudo loginctl enable-linger %s\n' "$(whoami)"
fi

printf 'install-self-update: installed %s. Next fire: %s\n' "$UNIT_NAME" \
  "$(systemctl --user list-timers "$UNIT_NAME.timer" --no-pager --no-legend 2>/dev/null | head -1 || echo unknown)"
