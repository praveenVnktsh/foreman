#!/usr/bin/env bash
# Claim: bin/install-self-update.sh writes the updater's service and timer,
# enables the timer, follows releases by default, pins a branch with --ref,
# KEEPS the pinned branch when re-run with neither flag, and goes back to
# releases with --releases.
#
# The failure it prevents: re-running the installer to pick up a unit change
# used to write a unit with no ref, and a machine that followed origin/main
# moved back onto releases without anyone choosing it.
#
# The real script runs from this clone and writes under a temporary HOME.
# Only the host is stubbed: `uname` answers Linux so this runs on any
# developer's machine, `systemctl` records its argv, and `loginctl` answers
# lingering from a file.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

mkdir -p "$work/bin" "$work/home/.foreman"
printf '#!/usr/bin/env bash\ncat "%s/os"\n' "$work" >"$work/bin/uname"
printf 'Linux\n' >"$work/os"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/systemctl.log"\n' "$work" >"$work/bin/systemctl"
printf '#!/usr/bin/env bash\ncat "%s/linger" 2>/dev/null\n' "$work" >"$work/bin/loginctl"
printf 'Linger=yes\n' >"$work/linger"
chmod +x "$work/bin/uname" "$work/bin/systemctl" "$work/bin/loginctl"

home="$work/home"
unit="$home/.config/systemd/user/foreman-update.service"
timer="$home/.config/systemd/user/foreman-update.timer"
run() {
  env -u HARNESS -u FOREMAN_ROOT PATH="$work/bin:$PATH" HOME="$home" \
    FOREMAN_HOME="$home/.foreman" bash "$root/bin/install-self-update.sh" "$@" 2>&1
}
ref_in_unit() { sed -n 's/^Environment=FOREMAN_UPDATE_REF=//p' "$unit" 2>/dev/null; }

# --- the first install follows releases
out="$(run)"; rc=$?
if [[ $rc -eq 0 && -f "$unit" && -f "$timer" && -z "$(ref_in_unit)" ]] \
   && [[ "$out" == *"tracking releases"* ]]; then
  ok "a first install writes both units and follows releases"
else
  bad "first install rc=$rc: $out"
fi
grep -qx "ExecStart=$root/bin/self-update.sh" "$unit" \
  && grep -qx "Environment=FOREMAN_HOME=$home/.foreman" "$unit" \
  && grep -qx "WorkingDirectory=$root" "$unit" \
  && ok "the service runs this clone's self-update.sh for this home" \
  || bad "service unit is: $(cat "$unit")"
grep -qx 'OnUnitActiveSec=5min' "$timer" \
  && grep -qx 'WantedBy=timers.target' "$timer" \
  && ok "the timer fires every five minutes and is installable" \
  || bad "timer unit is: $(cat "$timer")"
grep -qx -- '--user daemon-reload' "$work/systemctl.log" \
  && grep -qx -- '--user enable --now foreman-update.timer' "$work/systemctl.log" \
  && ok "reloads systemd and enables the timer" \
  || bad "systemctl was called with: $(cat "$work/systemctl.log")"

# --- --ref pins a branch
out="$(run --ref origin/main)"
[[ "$(ref_in_unit)" == "origin/main" && "$out" == *"tracking origin/main"* ]] \
  && ok "--ref writes the branch into the unit" \
  || bad "--ref -> $out; unit ref [$(ref_in_unit)]"

# --- a re-run with neither flag keeps it
out="$(run)"
[[ "$(ref_in_unit)" == "origin/main" && "$out" == *"tracking origin/main"* ]] \
  && ok "a re-run without --ref keeps the branch the unit tracked" \
  || bad "re-run lost the ref -> $out; unit ref [$(ref_in_unit)]"

# --- --releases switches back, and a re-run then stays on releases
out="$(run --releases)"
[[ -z "$(ref_in_unit)" && "$out" == *"tracking releases"* ]] \
  && ok "--releases goes back to following releases" \
  || bad "--releases -> $out; unit ref [$(ref_in_unit)]"
out="$(run)"
[[ -z "$(ref_in_unit)" && "$out" == *"tracking releases"* ]] \
  && ok "a re-run after --releases stays on releases" \
  || bad "re-run after --releases -> $out; unit ref [$(ref_in_unit)]"

# --- a bad ref is refused and the unit is left alone
run --ref origin/main >/dev/null
before="$(cat "$unit")"
out="$(run --ref main)"
[[ $? -ne 0 && "$out" == *"must look like origin/<branch>"* && "$(cat "$unit")" == "$before" ]] \
  && ok "a ref that is not origin/<branch> is refused and the unit is untouched" \
  || bad "bad ref -> $out"

# --- lingering off is reported, not fatal
printf 'Linger=no\n' >"$work/linger"
out="$(run)"
[[ $? -eq 0 && "$out" == *"lingering is OFF"* ]] \
  && ok "lingering off is reported and the install still succeeds" \
  || bad "linger off -> $out"

# --- a host that is not Linux is refused before anything is written
rm -rf "$home/.config"
printf 'Darwin\n' >"$work/os"
out="$(run)"
[[ $? -ne 0 && "$out" == *"Linux-only"* && ! -e "$unit" ]] \
  && ok "a host that is not Linux is refused and nothing is written" \
  || bad "non-Linux -> $out"

exit "$fail"
