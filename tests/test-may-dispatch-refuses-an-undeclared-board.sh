#!/usr/bin/env bash
# Claim: `reconcile.py --may-dispatch <board>` refuses a board `boards.toml`
# does not declare, with a non-zero exit and the name on stderr -- the same
# refusal `--served`, `--wants-slot` and `--cleanup-due` already make.
#
# The failure it prevents: an undeclared board has no floor, and the answer
# for one was "" -- which is how `--may-dispatch` says "take a slot". So a
# typo, or a removed board's leftover FOREMAN_INSTANCE, dispatched on a machine
# whose every slot was already held. dispatch.sh reads any non-zero exit as a
# refusal, so the refusal needs no change there.
#
# It drives the real script over real history files; nothing is stubbed,
# because `--may-dispatch` reads local files only.
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
fixture_add_board "$home" beta "$repo"

# demo holds both of the machine's slots.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for ticket in PRA-1 PRA-2; do
  mkdir -p "$fh/instances/demo/cards/$ticket"
  printf '{"at":"%s","event":{"action":"spawn","role":"build","attempt":"1"}}\n' "$now" \
    > "$fh/instances/demo/cards/$ticket/history.jsonl"
done

may_dispatch() {
  env HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo HOST_MAX_CONCURRENT=2 \
    "$root/skills/board/reconcile.py" --may-dispatch "$1" 2>"$work/err"
}

out="$(may_dispatch beta)"; status=$?
case "$status:$out" in
  0:*"2 of 2 slots"*) ok "a declared board on a full machine is refused by a line" ;;
  *) bad "a declared board on a full machine is refused by a line: status=$status out=$out $(cat "$work/err")" ;;
esac

out="$(may_dispatch nosuchboard)"; status=$?
if [[ "$status" -ne 0 ]] && grep -q "no board named nosuchboard" "$work/err"; then
  ok "an undeclared board is refused with a non-zero exit, by name"
else
  bad "an undeclared board is refused with a non-zero exit, by name: status=$status out=[$out] err=$(cat "$work/err")"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: --may-dispatch lets no undeclared board through\n'
exit "$fail"
