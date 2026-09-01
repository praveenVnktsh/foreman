#!/usr/bin/env bash
# Claim: supervise.sh keeps ONE tick for the whole machine, and starts none when
# no board is declared.
#
# There used to be a tick per board and a cron line per board. The failure that
# replaced is subtle: two cron fires that resolved different boards would take
# two different locks, both see no tick of their own, and both start one. Two
# ticks dispatching into the same slots is precisely what the lock exists to
# prevent, and a per-board lock could not prevent it once the tick stopped being
# per-board.
#
# The claude CLI is stubbed on PATH. This test must never reach the real one.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
fh="$home/.foreman"
mkdir -p "$fh/instances" "$work/bin" "$work/alpha" "$work/beta"
printf 'k\n' > "$fh/linear.key"; chmod 600 "$fh/linear.key"

for d in alpha beta; do
  cat > "$work/$d/board.toml" <<'TOML'
[linear]
team = "ABC"
project = "fixture"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
TOML
done

spawn_log="$work/spawned.log"
cat > "$work/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then echo '[]'; exit 0; fi
if [[ "\$1" == "--bg" ]]; then
  shift
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--name" ]]; then printf '%s\n' "\$2" >>"$spawn_log"; fi
    shift
  done
  echo "stub-session"; exit 0
fi
exit 0
STUB
chmod +x "$work/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/flock"; chmod +x "$work/bin/flock"

run_supervise() {
  env HOME="$home" FOREMAN_HOME="$fh" PATH="$work/bin:$PATH" \
    SUPERVISE_LOCK="$work/supervise.lock" \
    "$root/skills/board/supervise.sh" 2>&1
}

# --- no boards: nothing to supervise, and nothing started
: >"$spawn_log"
out="$(run_supervise)"
if [[ -s "$spawn_log" ]]; then
  bad "started a tick with no board declared: $(cat "$spawn_log")"
else
  ok "no board declared starts no tick"
fi
case "$out" in
  *"no boards declared"*) ok "says why it stood down" ;;
  *) bad "stood down without saying why: $out" ;;
esac

# --- two boards: exactly one tick, and it carries no board in its name
printf '[boards.alpha]\nrepo = "%s"\n[boards.beta]\nrepo = "%s"\n' \
  "$work/alpha" "$work/beta" > "$fh/boards.toml"
: >"$spawn_log"
out="$(run_supervise)"
started="$(grep -c . "$spawn_log" 2>/dev/null || echo 0)"
[[ "$started" == "1" ]] \
  && ok "two boards start exactly one tick" \
  || bad "two boards started $started ticks: $(cat "$spawn_log")"
name="$(head -1 "$spawn_log" 2>/dev/null || true)"
[[ "$name" == "foreman/tick" ]] \
  && ok "the tick carries no board in its name" \
  || bad "tick was named '$name', expected foreman/tick"

exit "$fail"
