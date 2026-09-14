#!/usr/bin/env bash
# Claim: install-service.sh refuses to install a watchdog for nothing, names
# every unit after the installation it watches, refuses to stand beside the
# pre-installations watchdog, and its dry run describes exactly what it would
# write.
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
skills="$work/claude-skills"; mkdir -p "$skills"
run() { env PATH="$work/bin:$PATH" FOREMAN_HOME="$fh" HOME="$work" \
          CLAUDE_SKILLS_DIR="$skills" \
          bash "$root/bin/install-service.sh" "$@" 2>&1; }
link_our_skills() { ln -sfn "$root/skills/board" "$skills/board"; }

# --- no boards declared
out="$(run --dry-run)"
case "$out" in
  *"no boards declared"*) ok "refuses to install a watchdog with no board declared" ;;
  *) bad "did not refuse with no boards: $out" ;;
esac

# --- one board declared, but the skills are not resolvable yet
printf '[boards.demo]\nrepo = "%s"\n' "$work/repo" > "$fh/boards.toml"
out="$(run --dry-run)"
case "$out" in
  *"could not find /board"*) ok "refuses while the tick could not find its own skill" ;;
  *) bad "installed a timer whose tick cannot resolve /board: $out" ;;
esac

# --- a foreign board skill is named specifically, not lumped in with absence
mkdir -p "$skills/board"; printf 'somebody else\n' > "$skills/board/SKILL.md"
out="$(run --dry-run)"
case "$out" in
  *"not this installation's board skill"*) ok "names a foreign board skill rather than reporting it missing" ;;
  *) bad "did not distinguish a foreign skill from an absent one: $out" ;;
esac
rm -rf "$skills/board"

# --- skills linked
link_our_skills
out="$(run --dry-run)"

case "$out" in
  *"Type=oneshot"*) ok "the service is a oneshot, not a long-running unit" ;;
  *) bad "service is not a oneshot" ;;
esac
case "$out" in
  *"supervise.sh"*) ok "the unit runs the watchdog" ;;
  *) bad "the unit does not run supervise.sh" ;;
esac
# The unit's stop must not reach the agents the watchdog spawned. A oneshot
# deactivates as soon as ExecStart returns, and under systemd's default
# KillMode=control-group that kills everything left in the cgroup -- which
# includes the shared claude daemon, if this unit is what first started it, and
# so every in-flight card build on the machine.
case "$out" in
  *"KillMode=process"*) ok "the unit signals only its own process, never the agents it spawned" ;;
  *) bad "unit does not set KillMode=process; deactivating it would kill every in-flight build" ;;
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

# --- the unit name carries the installation
#
# $fh declares no installation.toml, so bin/installation.py reads it as the
# lone Claude installation and the unit is foreman-claude. Two installations on
# one machine each need their own service and timer: a shared name would mean
# enabling one disables the other, and `systemctl --user stop` would stop a
# watchdog the operator did not name.
case "$out" in
  *"foreman-claude.timer"*) ok "the unit name carries the installation" ;;
  *) bad "the unit name does not carry the installation: $out" ;;
esac

# --- a dry run writes nothing
#
# Asserted against the name this script can actually produce. It used to name
# foreman.timer, which install-service.sh stopped emitting when unit names
# gained the installation, so the assertion passed whatever --dry-run did.
if [[ -e "$work/.config/systemd/user/foreman-claude.timer" ]]; then
  bad "--dry-run wrote a unit file"
else
  ok "--dry-run writes nothing"
fi

# --- an installation named beta produces foreman-beta units
#
# The name comes from the DIRECTORY, not from a flag: an installation home
# named beta under a machine root is the whole declaration of that fact. This
# is the case that proves the unit name is derived rather than constant --
# every assertion above it would also pass against a hard-coded name.
beta_root="$work/root"; beta_home="$beta_root/beta"; mkdir -p "$beta_home"
cat > "$beta_home/installation.toml" <<'TOML'
harness = "claude"
default = true
TOML
printf '[boards.demo]\nrepo = "%s"\n' "$work/repo" > "$beta_home/boards.toml"
out="$(env PATH="$work/bin:$PATH" FOREMAN_HOME="$beta_home" HOME="$work" \
        CLAUDE_SKILLS_DIR="$skills" bash "$root/bin/install-service.sh" --dry-run 2>&1)"
case "$out" in
  *"foreman-beta.timer"*) ok "an installation named beta produces foreman-beta.timer" ;;
  *) bad "an installation named beta did not produce foreman-beta.timer: $out" ;;
esac
case "$out" in
  *"installation 'beta'"*) ok "the unit says which installation it watches" ;;
  *) bad "the unit does not name the installation it watches: $out" ;;
esac

# --- the pre-installations watchdog is refused, not installed beside
#
# The old unit is named plain foreman and the new one foreman-<installation>,
# so systemd sees two unrelated units and runs both. The old one's ExecStart
# names the install/ directory `boardctl migrate` moved, so it fails every ten
# minutes forever beside a board that is otherwise healthy.
mkdir -p "$work/.config/systemd/user"
printf '[Unit]\nDescription=old foreman\n' > "$work/.config/systemd/user/foreman.timer"
out="$(run --dry-run)"
case "$out" in
  *"pre-installations watchdog"*) ok "refuses to install beside the pre-installations watchdog" ;;
  *) bad "installed beside the pre-installations watchdog: $out" ;;
esac
case "$out" in
  *"systemctl --user disable --now foreman.timer"*) ok "names the command that disables the old watchdog" ;;
  *) bad "does not name the command that disables the old watchdog: $out" ;;
esac
# Refused, never deleted: the operator did not ask for a file to be removed,
# and the unit file is the only record of what the old watchdog was.
if [[ -f "$work/.config/systemd/user/foreman.timer" ]]; then
  ok "leaves the legacy unit file alone"
else
  bad "deleted a unit file the operator did not ask to delete"
fi
rm -f "$work/.config/systemd/user/foreman.timer"

exit "$fail"
