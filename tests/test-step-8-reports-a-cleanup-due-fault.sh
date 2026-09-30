#!/usr/bin/env bash
# Claim: SKILL.md step 8's own block reports a `--cleanup-due` fault as a
# fault, and never as "not due". `reconcile.py` exits 1 for "not due" and
# nothing else, even when it fails in a way nobody anticipated.
#
# The failure it prevents: the block branched with `if reconcile.py
# --cleanup-due`, so exit 1 ("not due"), exit 2 (a config that will not load)
# and exit 3 (an unreadable agent registry) all took the same silent `else`. A
# broken board skipped its cleanup on every tick and the report said nothing
# was wrong. An uncaught exception exited 1 as well, Python's default, so a
# registry row with a number for a name read as "not due" too.
#
# It runs the block EXTRACTED from SKILL.md, not a copy, in a shell with no
# `set -e`, the way the tick runs it. Only `claude` is stubbed: it is the agent
# registry, the external boundary here.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/without-board.sh
source "$root/tests/lib/without-board.sh"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"

# The registry answers whatever `$work/agents` holds, and fails when it is
# missing. Any spawn is recorded, so a block that dispatched is caught.
stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then
  [[ -f "$work/agents" ]] || exit 1
  cat "$work/agents"; exit 0
fi
printf '%s\n' "\$*" >> "$work/spawned"
exit 0
STUB
chmod +x "$stub_bin/claude"

block="$work/step8.sh"
if ! python3 - "$root/skills/board/SKILL.md" "$block" "$root/skills/board" <<'PY'
import pathlib, re, sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.index("\n### 8.")
end = text.find("\n### ", start + 1)
blocks = re.findall(r"```bash\n(.*?)```", text[start:end], re.S)
due = [b for b in blocks if "--cleanup-due" in b]
if len(due) != 1:
    sys.exit(f"step 8 has {len(due)} bash blocks asking --cleanup-due; wanted 1")
block = due[0].replace("<board>", "demo")
pathlib.Path(sys.argv[2]).write_text(
    block.replace("~/.foreman/install/skills/board", sys.argv[3]))
PY
then
  bad "could not extract step 8's --cleanup-due block from SKILL.md"
  exit "$fail"
fi

run_step8() {
  ( export HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo PATH="$stub_bin:$PATH"
    # shellcheck disable=SC1091
    . "$root/skills/board/config.sh"
    eval "$(cat "$block")" ) 2>&1
}

dispatched() { [[ -s "$fh/instances/demo/last-cleanup" || -s "$work/spawned" ]]; }

rm -f "$work/agents"
out="$(run_step8)"
if [[ "$out" == *"FAILED (exit 3)"* && "$out" != *"not due"* ]] && ! dispatched; then
  ok "an unreadable registry is reported as a fault, and nothing is dispatched"
else
  bad "an unreadable registry is reported as a fault: [$out]"
fi

printf '[{"name": 5}]\n' > "$work/agents"
out="$(run_step8)"
if [[ "$out" == *"FAILED (exit 2)"* && "$out" == *"Traceback"* && "$out" != *"not due"* ]] \
    && ! dispatched; then
  ok "a failure nothing anticipated exits 2, and the block reports it as a fault"
else
  bad "a failure nothing anticipated is reported as a fault: [$out]"
fi

printf '[]\n' > "$work/agents"
date -u +%Y-%m-%dT%H:%M:%SZ > "$fh/instances/demo/last-cleanup"
out="$(run_step8)"
case "$out" in
  "cleanup not due: "*"next due"*) ok "a board cleaned just now is reported as not due, with the reason" ;;
  *) bad "a board cleaned just now is reported as not due: [$out]" ;;
esac

[[ "$fail" -eq 0 ]] && printf 'PASS: step 8 never reports a cleanup-due fault as not due\n'
exit "$fail"
