#!/usr/bin/env bash
# Install this installation's self-updater as a systemd user timer.
#
#   install-self-update.sh --dry-run          print both units and change nothing
#   install-self-update.sh                    write, enable and start them
#   install-self-update.sh --ref <ref>        track <ref> instead of origin/main
#
# --ref writes FOREMAN_UPDATE_REF into the unit. An installation pinned to
# origin/release (bin/release.sh promotes main onto it) does not deploy on a
# merge to main; it deploys when a release is promoted. See docs/INSTALLING.md.
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
UPDATE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --ref) [[ $# -ge 2 ]] || die "--ref needs a value"; UPDATE_REF="$2"; shift 2 ;;
    *) die "unknown argument: $1 (expected --dry-run or --ref <ref>)" ;;
  esac
done

# By default the timer follows GitHub Releases: bin/self-update.sh polls the
# latest. --ref pins it to a git ref instead, and the same validation
# bin/self-update.sh applies at fire time runs here, so a typo is refused now.
if [[ -n "$UPDATE_REF" ]]; then
  case "$UPDATE_REF" in
    origin/*) ;;
    *) die "--ref must look like origin/<branch>, got '$UPDATE_REF'" ;;
  esac
  case "${UPDATE_REF#origin/}" in
    ""|*" "*|*".."*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@"*)
      die "--ref names an invalid branch: '$UPDATE_REF'" ;;
  esac
fi

# The unit carries FOREMAN_UPDATE_REF only when the operator pinned one; with
# none, the timer follows releases. Shown in the closing line.
if [[ -n "$UPDATE_REF" ]]; then
  REF_ENV="Environment=FOREMAN_UPDATE_REF=$UPDATE_REF"
  TRACKS="$UPDATE_REF"
else
  REF_ENV=""
  TRACKS="releases"
fi

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
# ONE FOREMAN, so the unit carries no installation segment.
UNIT_NAME="foreman-update"
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
# A BACKSTOP, NOT THE GUARD. A oneshot that never finishes stays 'activating'
# for ever, and systemd computes no next elapse for its timer while it does --
# so a single hung fire would silently end every future update. Measured on
# 2026-09-16, the first time this ran on a real host: a stalled fetch left
# NextElapseUSecMonotonic=infinity.
#
# self-update.sh bounds its own fetch, which is the real fix. This catches
# anything that bound misses. Note what it cannot do under KillMode=process: on
# timeout systemd signals only the main process, so a hung CHILD would be left
# running. That is exactly why the fetch has to end itself rather than rely on
# this -- and why this is set well above anything a healthy fire needs, so it
# only ever fires on something genuinely wedged.
TimeoutStartSec=10min
WorkingDirectory=$INSTALL_ROOT
Environment=FOREMAN_HOME=$FOREMAN_HOME
$REF_ENV
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
# SPREAD THE INSTALLATIONS APART. Every installation on a machine gets one of
# these timers, and an operator installs them back to back, so their schedules
# start within a second of each other and stay in lockstep for ever: every five
# minutes, every installation fetches the same remote at the same instant.
# Measured on 2026-09-16 with three installations installed together -- all
# three fetches stalled at once. Whether the lockstep caused the stall or only
# multiplied it, it is a thundering herd this machine inflicts on itself, and a
# random offset per fire costs nothing.
RandomizedDelaySec=90s
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

printf 'install-self-update: installed %s tracking %s. Next fire: %s\n' "$UNIT_NAME" "$TRACKS" \
  "$(systemctl --user list-timers "$UNIT_NAME.timer" --no-pager --no-legend 2>/dev/null | head -1 || echo unknown)"
