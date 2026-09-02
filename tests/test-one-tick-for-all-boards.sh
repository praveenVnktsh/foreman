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
argv_log="$work/argv.log"
cat > "$work/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then echo '[]'; exit 0; fi
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$*" >>"$argv_log"
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

# `-u FOREMAN_INSTANCE`, because supervise.sh reads it: with a board named in
# the environment it skips the boards.toml lookup entirely and sources that
# board's config, so every case below asserted against the caller's machine
# instead of the fixture. It passes in CI, where nothing sets the variable, and
# fails on any developer machine and inside every agent the board dispatches --
# which is where this suite actually runs on every build attempt.
run_supervise() {
  env -u FOREMAN_INSTANCE HOME="$home" FOREMAN_HOME="$fh" PATH="$work/bin:$PATH" \
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

# --- the tick is given foreman's OWN mcp config, not the cwd's ---------------
#
# Claude Code resolves MCP servers per project, keyed on the working directory.
# The tick runs from the install and serves every board, so it inherits none --
# measured on a real host, where it read the board correctly and then had no
# write path to move a single card.
: >"$argv_log"; : >"$spawn_log"
printf '{"mcpServers":{}}\n' > "$fh/mcp.json"
run_supervise >/dev/null
if grep -q -- "--mcp-config $fh/mcp.json" "$argv_log"; then
  ok "the tick is started with this installation's own mcp config"
else
  bad "no --mcp-config in: $(cat "$argv_log")"
fi

# and the prompt must still survive: --mcp-config is variadic, so anything after
# it is eaten as another config path. dispatch.sh documents the same trap.
if grep -qE -- "--permission-mode [a-zA-Z]+ /loop /board|--permission-mode [a-zA-Z]+ /board" "$argv_log"; then
  ok "a non-variadic flag sits between --mcp-config and the prompt"
else
  bad "the prompt may have been swallowed by --mcp-config: $(cat "$argv_log")"
fi

# --- absent mcp.json is not an error; a dry run still starts --------------
rm -f "$fh/mcp.json"
: >"$argv_log"; : >"$spawn_log"
out="$(run_supervise)"
if grep -q -- "--mcp-config" "$argv_log"; then
  bad "passed --mcp-config with no config file present"
else
  ok "no config file means no flag, not a failure"
fi

exit "$fail"
