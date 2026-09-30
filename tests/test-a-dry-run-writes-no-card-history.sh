#!/usr/bin/env bash
# Claim: under BOARD_DRY_RUN, config.sh's card_log writes nothing to a card's
# history and says on stderr what it would have written.
#
# history.jsonl is what every later pass counts: a slot held or released, an
# attempt spent, a plan round used. card_log appended under a dry run like any
# other run, so an operator asking to be told what a pass would do changed what
# the next real pass decided.
set -uo pipefail
# shellcheck source=lib/without-board.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/without-board.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work/target"
git init -q -b main "$target"
fixture_board_toml "$target"
home="$work/home"
fixture_add_board "$home" alpha "$target"
history="$home/.foreman/instances/alpha/cards/ABC-1/history.jsonl"

log_one() { # <BOARD_DRY_RUN>
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=alpha BOARD_DRY_RUN="$1" \
    bash -c '. "$1" && card_log ABC-1 "{\"action\":\"released\"}"' _ "$root/skills/board/config.sh" 2>&1
}

out="$(log_one 1)"
[[ ! -e "$history" ]] && ok "a dry run writes no history" || bad "a dry run wrote: $(cat "$history")"
grep -q 'DRY RUN: would append' <<<"$out" && grep -q '"action":"released"' <<<"$out" \
  && ok "and says what it would have written" || bad "the dry run said: $out"

log_one "" >/dev/null
grep -q '"action":"released"' "$history" 2>/dev/null && ok "a real run still writes it" \
  || bad "a real run wrote no history"

[[ "$fail" -eq 0 ]] && printf 'PASS: a dry run writes no card history\n'
exit "$fail"
