#!/usr/bin/env bash
# Install the foreman dashboard as a systemd user service.
#
#   install-dashboard.sh --dry-run   print the unit and change nothing
#   install-dashboard.sh             write, enable and start it
#   install-dashboard.sh --port N    serve on N instead of 8429
#
# A long-running service, not a timer: unlike the watchdog this holds a socket
# open, so `Type=simple` with `Restart=on-failure` is exactly right and a
# oneshot would be wrong.
#
# IT BINDS LOOPBACK AND STOPS THERE. bin/dashboard.py serves 127.0.0.1 and this
# unit does not change that. Publishing it is a separate, deliberate act,
# because who may see a board is not a question this repository can answer for
# an operator's network:
#
#     tailscale serve --bg --set-path /foreman 8429
#
# That puts it on the tailnet -- every device the operator already trusts, and
# nothing else -- with no port open to the internet and no credential for this
# process to check. The page is written to work under any path prefix, so the
# `--set-path` is the operator's to choose.
#
# Lingering is the part everyone forgets. A user service only runs while the
# user has a session unless `loginctl enable-linger` is set, so on a headless
# host the dashboard silently stops at logout and nothing says so -- which is
# worst for this unit in particular, since the thing an operator reaches for
# when a board looks wrong is the page that is now not there.
set -euo pipefail

die() { printf 'install-dashboard: %s\n' "$*" >&2; exit 1; }

DRY=""
PORT="8429"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --port) [[ $# -ge 2 ]] || die "--port needs a value"; PORT="$2"; shift 2 ;;
    *) die "unknown argument: $1 (expected --dry-run or --port N)" ;;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -gt 0 ]] && [[ "$PORT" -lt 65536 ]] \
  || die "--port must be a TCP port number, got '$PORT'"

[[ "$(uname -s)" == "Linux" ]] || die "systemd units are Linux-only; on macOS run bin/dashboard.py under launchd, or by hand"
command -v systemctl >/dev/null || die "systemctl not found; this host does not use systemd"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname -- "$HERE")"

# WHICH HOME THIS IS, asked of the one file that derives it -- see
# bin/install-service.sh's own comment for why this is never re-derived here.
. "$INSTALL_ROOT/bin/load-pairs.sh" || die "cannot read $INSTALL_ROOT/bin/load-pairs.sh"
unset HARNESS FOREMAN_ROOT
_foreman_load_pairs "foreman's declaration" "$INSTALL_ROOT/bin/installation.py" \
  || die "installation.py could not read foreman's declaration"
[[ -n "$FOREMAN_HOME" ]] || die "installation.py did not report a home"

DASHBOARD="$INSTALL_ROOT/bin/dashboard.py"
[[ -x "$DASHBOARD" ]] || die "no executable dashboard at $DASHBOARD"

# Refuse to serve a page about nothing, the same refusal install-service.sh
# makes: a dashboard with no board declared renders an empty machine forever,
# which looks exactly like a machine whose boards all went quiet.
BOARDS="$(FOREMAN_HOME="$FOREMAN_HOME" "$INSTALL_ROOT/bin/boards.py" --list 2>/dev/null | tr '\0' '\n' | grep -c . || true)"
[[ "${BOARDS:-0}" -gt 0 ]] \
  || die "no boards declared in $FOREMAN_HOME/boards.toml; run 'boardctl add <name> --repo <path>' first"

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/foreman-dashboard.service"

# UNQUOTED DELIMITER, because $DASHBOARD, $FOREMAN_HOME and $PORT have to be
# expanded into the unit. That makes everything else in here live too: the
# comments below are shell text, so a `$name` in one is expanded and a
# backtick pair in one is RUN. Measured 2026-09-20 -- the first version of
# this block said "$HARNESS_SH list" and "too old for `tomllib`" in its own
# prose, and installing printed "HARNESS_SH: unbound variable" and
# "tomllib: command not found" while writing a unit with two sentences that
# stopped mid-clause. Anything literal in here is escaped; nothing in a
# comment is worth a command substitution.
read -r -d '' UNIT_TEXT <<UNIT_EOF || true
[Unit]
Description=foreman dashboard (one page: what this foreman is doing)
After=network-online.target

[Service]
Type=simple
# THE HARNESS BINARY IS IN ~/.local/bin, and a systemd user unit is given
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin and nothing
# else. Without this the page renders "the agent registry could not be read"
# forever, because \$HARNESS_SH list shells out to a CLI that is not on its
# PATH -- measured 2026-09-20, where the first install of this unit did
# exactly that while the tick beside it was healthy.
#
# ~/.local/bin LEADS and the system directories TRAIL, the same order
# skills/board/supervise.sh carries and for the same two reasons: the harness
# binary is what has to be found first, and putting /usr/bin ahead of the
# operator's own PATH shadows their python3 with one too old for tomllib.
Environment=PATH=%h/.local/bin:%h/bin:/usr/local/bin:/usr/bin:/bin
# The installed clone, never a working tree -- the same pin the tick runs on,
# for the same reason: a dashboard reading uncommitted code would report a
# machine that does not exist.
ExecStart=$DASHBOARD
Environment=FOREMAN_HOME=$FOREMAN_HOME
Environment=FOREMAN_DASHBOARD_PORT=$PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF

if [[ -n "$DRY" ]]; then
  printf '# %s\n%s\n' "$UNIT" "$UNIT_TEXT"
  exit 0
fi

mkdir -p "$UNIT_DIR"
printf '%s\n' "$UNIT_TEXT" >"$UNIT"
systemctl --user daemon-reload
systemctl --user enable foreman-dashboard.service
# RESTART, not `enable --now`. `--now` only STARTS, and a unit that is already
# active is left exactly as it is -- so re-running this after an upgrade
# rewrote the unit file and kept serving the old process, from the old path,
# on the same port. Measured 2026-09-20, replacing the pre-repository
# dashboard: the unit said what was wanted and the socket answered with what
# was there before.
systemctl --user restart foreman-dashboard.service

printf 'install-dashboard: foreman-dashboard.service is serving http://127.0.0.1:%s\n' "$PORT"
printf '\npublish it to your tailnet (optional, and yours to choose):\n'
printf '  tailscale serve --bg --set-path /foreman %s\n' "$PORT"
printf '\nif this host is headless, keep it running after logout:\n'
printf '  loginctl enable-linger %s\n' "$(id -un)"
