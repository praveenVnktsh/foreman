#!/usr/bin/env bash
# Claim: `reconcile.py --overview` calls the tick stale when its transcript has
# been silent too long, and never merely because the tick has been up a while.
#
# The failure it prevents: `tick-stale` fired on the tick's AGE. One tick walks
# every board and runs for hours by design, so every healthy tick read as a
# problem 90 minutes after it started, and the operator learned to ignore the
# line. The comment on the threshold always said "without a new turn": silence
# is the symptom. The transcript's mtime is the same evidence supervise.sh
# judges the tick's health on.
#
# It drives the real script and the real claude adapter. Only `claude agents`
# is stubbed; the transcript is a real file where the adapter says it lives.
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
: > "$fh/mcp.json"

# A tick started ten hours ago.
started_ms="$(python3 -c 'import time; print(int((time.time() - 10 * 3600) * 1000))')"
stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then
  printf '[{"name":"foreman/tick","id":"t1","sessionId":"s-tick","cwd":"/ticks","state":"working","pid":4242,"startedAt":%s}]\n' "$started_ms"
fi
exit 0
STUB
chmod +x "$stub_bin/claude"

# The adapter prints the path whether or not the file exists yet, and exits
# non-zero while it does not.
transcript="$(HOME="$home" "$root/skills/board/harness/claude.sh" transcript /ticks s-tick 2>/dev/null)"
[[ -n "$transcript" ]] || { echo "FAIL the claude adapter named no transcript path" >&2; exit 1; }
mkdir -p "$(dirname "$transcript")"
: > "$transcript"

kinds() {
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" --overview 2>"$work/err" \
    | python3 -c '
import json, sys
print(" ".join(p["kind"] for p in json.load(sys.stdin)["problems"]))
'
}

out="$(kinds)"
case " $out " in
  *" tick-stale "*) bad "a tick up ten hours that wrote just now is not stale: [$out] $(cat "$work/err")" ;;
  *) ok "a tick up ten hours that wrote just now is not stale" ;;
esac

# Silent for three hours.
python3 -c 'import os, sys, time; t = time.time() - 3 * 3600; os.utime(sys.argv[1], (t, t))' "$transcript"
out="$(kinds)"
case " $out " in
  *" tick-stale "*) ok "a tick silent for three hours is stale" ;;
  *) bad "a tick silent for three hours is stale: [$out] $(cat "$work/err")" ;;
esac

[[ "$fail" -eq 0 ]] && printf 'PASS: a tick is stale by its silence, not its age\n'
exit "$fail"
