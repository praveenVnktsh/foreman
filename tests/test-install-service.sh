#!/usr/bin/env bash
# Claim: install-service.sh refuses to install a watchdog for nothing, names
# every unit after the installation it watches, refuses to stand beside the
# pre-installations watchdog while it can still run, and its dry run describes
# exactly what it would write.
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
# is-enabled and is-active answer from files under $work/unit-state, so a claim
# sets the legacy watchdog's state by writing one. An absent file answers as
# systemd does for a unit it has never loaded. Every other verb succeeds silently.
mkdir -p "$work/unit-state"
cat > "$work/bin/systemctl" <<STUB
#!/usr/bin/env bash
[[ "\$1" == --user ]] && shift
case "\$1" in
  is-enabled) cat "$work/unit-state/\$2.enabled" 2>/dev/null || echo not-found ;;
  is-active)  cat "$work/unit-state/\$2.active" 2>/dev/null || echo inactive ;;
esac
exit 0
STUB
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
  *"not foreman's board skill"*) ok "names a foreign board skill rather than reporting it missing" ;;
  *) bad "did not distinguish a foreign skill from an absent one: $out" ;;
esac
rm -rf "$skills/board"

# --- skills linked
link_our_skills
out="$(run --dry-run)"

case "$out" in
  *"pre-installations watchdog"*) bad "refused with no legacy unit file: $out" ;;
  *) ok "no legacy unit file is not refused" ;;
esac

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

# --- the unit is named plain foreman; there is no installation segment
case "$out" in
  *"foreman.timer"*) ok "the unit is named plain foreman" ;;
  *) bad "the unit is not named foreman: $out" ;;
esac

# --- a dry run writes nothing
if [[ -e "$work/.config/systemd/user/foreman.timer" ]]; then
  bad "--dry-run wrote a unit file"
else
  ok "--dry-run writes nothing"
fi

exit "$fail"
