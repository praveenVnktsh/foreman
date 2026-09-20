#!/usr/bin/env bash
# The dashboard unit has to be able to run what the dashboard shells out to.
#
# A systemd user service is given /usr/local/sbin:/usr/local/bin:/usr/sbin:
# /usr/bin:/sbin:/bin and nothing else. The harness binary lives in
# ~/.local/bin, so a unit with no PATH renders "the agent registry could not be
# read" on every refresh while the tick beside it is perfectly healthy --
# measured 2026-09-20 on the first host this was installed on.
#
# Prove the unit carries a PATH, that ~/.local/bin leads it (the harness
# binary) and the system directories trail it (so /usr/bin cannot shadow a
# python3 new enough for `tomllib`, the failure skills/board/supervise.sh
# carries its own comment about), and that installing REPLACES a running
# service rather than leaving the old process on the port.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/bin/install-dashboard.sh"

[[ -x "$installer" ]] || { echo "FAIL: $installer is missing or not executable" >&2; exit 1; }

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# The unit text, without a systemd to install it into. `--dry-run` prints
# exactly what would be written, which is the whole point of having it.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

home="$work_dir/home"; mkdir -p "$home"
target="$work_dir/target"; mkdir -p "$target"
fixture_board_toml "$target"
printf '[boards.demo]\nrepo = "%s"\n' "$target" >"$home/boards.toml"

# The installer refuses on a non-Linux host before it prints anything, so on
# macOS the unit text is read from the source instead. Either way the
# assertions below are about the same lines.
if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null; then
  unit="$(FOREMAN_HOME="$home" "$installer" --dry-run)"
  source_of_truth="the unit --dry-run prints"
else
  unit="$(grep -A40 '^read -r -d .. UNIT_TEXT' "$installer")"
  source_of_truth="the unit text in the installer"
fi

path_line="$(printf '%s\n' "$unit" | grep -E '^Environment=PATH=' || true)"
if [[ -n "$path_line" ]]; then
  ok "$source_of_truth sets a PATH"
else
  not_ok "$source_of_truth sets no PATH; the harness binary will not be found"
fi

value="${path_line#Environment=PATH=}"
first="${value%%:*}"
if [[ "$first" == *".local/bin" ]]; then
  ok "~/.local/bin leads the PATH, so the harness binary is found first"
else
  not_ok "~/.local/bin does not lead the PATH: $value"
fi

# /usr/bin must come AFTER anything the operator installed. The rule is the one
# supervise.sh learned: a leading /usr/bin shadows a newer python3, and every
# loader here needs 3.11 for tomllib.
before_usr="${value%%/usr/bin*}"
if [[ "$value" == *"/usr/bin"* ]] && [[ "$before_usr" == *".local/bin"* ]]; then
  ok "/usr/bin trails the operator's own directories, so it cannot shadow python3"
else
  not_ok "/usr/bin does not trail: $value"
fi

# A unit that is already active is NOT restarted by `enable --now`. Re-running
# the installer after an upgrade has to replace the running process, or the
# socket keeps answering with the old code from the old path.
if grep -qE '^systemctl --user restart foreman-dashboard\.service' "$installer"; then
  ok "installing restarts the service, so an upgrade replaces a running one"
else
  not_ok "the installer does not restart; an already-active unit keeps the old process"
fi

# A COMMAND LINE, not a mention. Anchored to the start of a line so the comment
# above that command -- which has to say `enable --now` to explain why it is
# wrong -- does not read as the thing it warns about. The same distinction
# bin/release.sh draws for its own opt-out marker.
if grep -qE '^systemctl --user enable --now' "$installer"; then
  not_ok "the installer still runs 'enable --now', which leaves an active unit alone"
else
  ok "the installer does not rely on 'enable --now' to replace a running service"
fi

# =============================================================================
# Case: the unit heredoc expands only what it means to
#
# The delimiter is unquoted, because $DASHBOARD and $FOREMAN_HOME have to reach
# the unit. That makes the COMMENTS in it live shell too: a `$name` in one is
# expanded to nothing and a backtick pair is executed. The first version of
# this block wrote "$HARNESS_SH list" and "too old for `tomllib`" in its own
# prose; installing printed "HARNESS_SH: unbound variable" and
# "tomllib: command not found", and wrote a unit whose explanation stopped
# mid-sentence twice.
heredoc="$(awk '/^read -r -d/,/^UNIT_EOF$/' "$installer")"

if ! printf '%s' "$heredoc" | grep -q '`'; then
  ok "no backticks inside the unit heredoc, so no comment can run a command"
else
  not_ok "a backtick inside the unit heredoc will be executed at install time"
fi

# Every unescaped $NAME is expanded. Only the three the unit actually needs may
# be there; anything else is prose that will silently become empty.
live="$(printf '%s' "$heredoc" | grep -oE '(^|[^\\])\$[A-Za-z_][A-Za-z0-9_]*' \
  | grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' | sort -u | tr '\n' ' ')"
if [[ "$live" == "\$DASHBOARD \$FOREMAN_HOME \$PORT " ]]; then
  ok "the heredoc expands exactly the three values the unit needs"
else
  not_ok "the heredoc expands more than it means to: $live"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
