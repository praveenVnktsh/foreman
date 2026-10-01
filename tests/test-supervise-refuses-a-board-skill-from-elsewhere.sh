#!/usr/bin/env bash
# Claim: supervise.sh starts no tick when the harness's board skill does not
# resolve to the install it runs from, and says so.
#
# Measured on 2026-09-30. ~/.claude/skills/board pointed at a
# directory that no longer existed. The tick started, could not load its skill,
# ran one pass and ended its turn. The harness kept listing it as `working`
# with no pid, and supervise.sh reported "healthy" for forty minutes while
# nothing dispatched. A tick whose skill is missing can do nothing, so the
# cheapest place to refuse is before it is started, with the fix in the message.
# Three bad links are tried: dangling, live but another install's, and absent.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supervise="$repo_root/skills/board/supervise.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

target="$work/target"
mkdir -p "$target"
git -C "$target" init -q -b main
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" demo "$target"

registry="$work/registry.json"
started="$work/started.log"
reset() { printf '[]' >"$registry"; : >"$started"; }

mkdir -p "$home/.local/bin"
cat >"$home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
registry="$registry"; started="$started"
if [[ "\$1" == "agents" ]]; then cat "\$registry"; exit 0; fi
if [[ "\$1" == "--bg" ]]; then
  name=""
  while [[ \$# -gt 0 ]]; do [[ "\$1" == "--name" ]] && name="\$2"; shift; done
  printf '%s\n' "\$name" >>"\$started"
  python3 - "\$registry" "\$name" <<'PY'
import json, sys, time
path, name = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
rows.append({"id": "tick-new", "name": name, "state": "working", "pid": 4242,
             "startedAt": int(time.time() * 1000), "cwd": "", "sessionId": "sid-new"})
json.dump(rows, open(path, "w"))
PY
  exit 0
fi
exit 0
STUB
chmod +x "$home/.local/bin/claude"

run() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      SUPERVISE_LOCK="$work/supervise.lock" \
      TICK_DRAIN_SECONDS=1 TICK_START_TIMEOUT_SECONDS=5 TICK_STOP_TIMEOUT_SECONDS=2 \
      TICK_LOCK_WAIT_SECONDS=2 \
      "$supervise" "$@" 2>&1
}

skills="$home/.claude/skills"
refused() { # <label>
  local out status
  reset
  out="$(run)"; status=$?
  [[ "$status" -ne 0 ]] \
    && ok "$1: supervise.sh exits non-zero" \
    || bad "$1: supervise.sh exited zero: $out"
  [[ ! -s "$started" ]] \
    && ok "$1: no tick was started" \
    || bad "$1: a tick was started anyway: $(cat "$started")"
  grep -q 'install-skills.sh' <<<"$out" \
    && ok "$1: the message names install-skills.sh" \
    || bad "$1: the message does not name install-skills.sh: $out"
}

# --- 1: a dangling link ------------------------------------------------------
rm -rf "$skills/board"; mkdir -p "$skills"
ln -s "$work/elsewhere/install/skills/board" "$skills/board"
refused "dangling link"

# --- 2: a live link into another install -------------------------------------
rm -rf "$skills/board"; mkdir -p "$work/other/skills/board"
ln -s "$work/other/skills/board" "$skills/board"
refused "link to another install"

# --- 3: no link at all -------------------------------------------------------
rm -rf "$skills/board"
refused "no link"

# --- 4: the link this install owns -------------------------------------------
fixture_link_board_skill "$home"
reset
out="$(run)"; status=$?
[[ "$status" -eq 0 ]] \
  && ok "with the board skill linked, supervise.sh exits zero" \
  || bad "supervise.sh failed with a good link (exit $status): $out"
grep -q 'foreman/tick' "$started" \
  && ok "and a tick is started" \
  || bad "no tick started with a good link: $out"

exit "$fail"
