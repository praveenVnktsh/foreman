#!/usr/bin/env bash
# Claim: install-service.sh refuses to install a watchdog for nothing, and its
# dry run describes exactly what it would write.
#
# The refusal matters more than it looks. An enabled timer with no board
# declared wakes every ten minutes forever to find no work, and that is
# indistinguishable from a board that is merely quiet -- so the operator learns
# nothing from the timer being green.
#
# `uname` and `systemctl` are stubbed so this runs on the machine a developer
# has, not only on the host it installs to. It never writes a unit file: every
# assertion here is against --dry-run.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

mkdir -p "$work/bin" "$work/repo"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$work/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/loginctl"
chmod +x "$work/bin/uname" "$work/bin/systemctl" "$work/bin/loginctl"

cat > "$work/repo/board.toml" <<'TOML'
[linear]
team = "ABC"
project = "demo"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
TOML

fh="$work/foreman-home"; mkdir -p "$fh"
run() { env PATH="$work/bin:$PATH" FOREMAN_HOME="$fh" HOME="$work" \
          bash "$root/bin/install-service.sh" "$@" 2>&1; }

# --- no boards declared
out="$(run --dry-run)"
case "$out" in
  *"no boards declared"*) ok "refuses to install a watchdog with no board declared" ;;
  *) bad "did not refuse with no boards: $out" ;;
esac

# --- one board declared
printf '[boards.demo]\nrepo = "%s"\n' "$work/repo" > "$fh/boards.toml"
out="$(run --dry-run)"

case "$out" in
  *"Type=oneshot"*) ok "the service is a oneshot, not a long-running unit" ;;
  *) bad "service is not a oneshot" ;;
esac
case "$out" in
  *"supervise.sh"*) ok "the unit runs the watchdog" ;;
  *) bad "the unit does not run supervise.sh" ;;
esac
case "$out" in
  *"Persistent=true"*) ok "a missed fire is caught up after a reboot" ;;
  *) bad "timer is not persistent; a sleeping host silently stops ticking" ;;
esac
case "$out" in
  *"enable-linger"*) ok "says lingering must be enabled or the timer dies at logout" ;;
  *) bad "never mentions lingering" ;;
esac
case "$out" in
  *"FOREMAN_HOME=$fh"*) ok "the unit pins FOREMAN_HOME rather than inheriting it" ;;
  *) bad "unit does not pin FOREMAN_HOME" ;;
esac

# --- a dry run writes nothing
if [[ -e "$work/.config/systemd/user/foreman.timer" ]]; then
  bad "--dry-run wrote a unit file"
else
  ok "--dry-run writes nothing"
fi

exit "$fail"
