#!/usr/bin/env bash
# Claim: a history line whose `event` is not a JSON object -- a string, a list,
# null -- reads as an event with no action. `--host-slots`, `--overview` and a
# card's own record all still answer.
#
# The failure it prevents: `_read_jsonl` guarantees each LINE is an object, and
# nothing guaranteed its `event` was. Every reader reached for `.get` on it, so
# one hand-edited line on one card raised AttributeError inside a walk over
# every card of every board: `--host-slots` failed, so dispatch.sh refused
# every dispatch on the machine, and `--overview` rendered nothing.
#
# It drives the real script over real history files. Only `gh` and `claude`
# are stubbed.
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
git init -q -b main "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"
cards="$fh/instances/demo/cards"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "pr" && "$2" == "list" ]] && { printf '[]\n'; exit 0; }
exit 1
STUB
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
card() {  # $1 ticket, $2 the event's JSON
  mkdir -p "$cards/$1"
  printf '{"at":"%s","event":{"action":"spawn","role":"build","attempt":"1"}}\n' "$now" \
    > "$cards/$1/history.jsonl"
  printf '{"at":"%s","event":%s}\n' "$now" "$2" >> "$cards/$1/history.jsonl"
}
card PRA-1 '"released"'
card PRA-2 'null'
card PRA-3 '["resume", "plan"]'
card PRA-4 '{"action":"resume","role":"build","reason":"ci-fix"}'

reconcile() {
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$@" 2>"$work/err"
}

out="$(reconcile --host-slots)"; status=$?
held="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["instances"]["demo"])' 2>/dev/null)"
# A malformed event is not a `released` one, so each of those cards still holds
# its slot -- the safe reading -- until HOST_SLOT_STALE_MINUTES lets it go.
if [[ "$status" -eq 0 && "$held" == "4" ]]; then
  ok "--host-slots counts every card, malformed events included"
else
  bad "--host-slots counts every card, malformed events included: status=$status held=$held $(cat "$work/err")"
fi

out="$(reconcile --overview)"; status=$?
actions="$(printf '%s' "$out" | python3 -c '
import json, sys
cards = json.load(sys.stdin)["boards"][0]["cards"]
print(" ".join("%s=%s" % (c["ticket"], c["last_action"]) for c in cards))
' 2>/dev/null)"
if [[ "$status" -eq 0 && "$actions" == "PRA-1=None PRA-2=None PRA-3=None PRA-4=resume" ]]; then
  ok "--overview reports a malformed event as no action"
else
  bad "--overview reports a malformed event as no action: status=$status actions=[$actions] $(cat "$work/err")"
fi

out="$(reconcile PRA-1 PRA-2 PRA-3 PRA-4)"; status=$?
attempts="$(printf '%s' "$out" | python3 -c '
import json, sys
print(" ".join(str(r["build_attempts"]) for r in json.load(sys.stdin)))
' 2>/dev/null)"
if [[ "$status" -eq 0 && "$attempts" == "1 1 1 2" ]]; then
  ok "a card's record reads a malformed event as no action"
else
  bad "a card's record reads a malformed event as no action: status=$status attempts=[$attempts] $(cat "$work/err")"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: a malformed history event crashes nothing\n'
exit "$fail"
