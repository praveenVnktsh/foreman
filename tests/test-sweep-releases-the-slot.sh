#!/usr/bin/env bash
# Claim: sweeping a terminal card releases its concurrency slot.
#
# config.sh predicted this failure where it explains HOST_SLOT_STALE_MINUTES:
# "A slot releasable ONLY by an LLM remembering one specific line violates that
# ... would otherwise wedge dispatch on EVERY instance on this machine forever."
#
# Measured on 2026-09-01. A card was built, reviewed and merged. Its history
# recorded `merged`. No `released` marker was ever written, because writing one
# was prose in SKILL.md rather than something any code did. The board went on
# counting five held slots with nothing running, and once dispatch.sh began
# enforcing the ceiling, that count refused every new card until the 12-hour
# staleness backstop expired.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"; target="$work/target"
mkdir -p "$target"
git init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
fixture_add_board "$home" demo "$target"

# sweep.sh asks `claude agents` which worktrees are live before reaping any.
# CI has no claude binary, so without this stub the script dies before it reaches
# the release -- which is exactly how this test passed on a developer machine and
# failed on Linux. An empty registry means nothing is live, which is what a
# terminal card looks like.
stub="$work/bin"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nif [[ "$1" == "agents" ]]; then echo "[]"; fi\nexit 0\n' > "$stub/claude"
chmod +x "$stub/claude"
export PATH="$stub:$PATH"

cards="$home/.foreman/instances/demo/cards"
hold() {
  mkdir -p "$cards/$1"
  printf '{"at":"%s","event":{"action":"spawn","name":"x","attempt":"1"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$cards/$1/history.jsonl"
}
slots() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" --host-slots 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'
}
sweep() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    bash "$root/skills/board/sweep.sh" "$@" 2>&1
}

hold ABC-1; hold ABC-2
[[ "$(slots)" == "2" ]] && ok "two cards hold two slots" || bad "expected 2, got $(slots)"

sweep ABC-1 >/dev/null 2>&1
[[ "$(slots)" == "1" ]] \
  && ok "sweeping a card releases its slot" \
  || bad "after sweeping ABC-1 the count is $(slots), not 1"

grep -q '"action":"released"' "$cards/ABC-1/history.jsonl" \
  && ok "the release is recorded in the card's history" \
  || bad "no released marker in ABC-1's history"

# The audit trail must survive: history.jsonl is the card's record, and the
# release is appended to it rather than replacing anything.
grep -q '"action":"spawn"' "$cards/ABC-1/history.jsonl" \
  && ok "the earlier history is kept, not overwritten" \
  || bad "sweeping destroyed the card's history"

# Releasing twice is a no-op, not a corruption: card_holds_slot reads the last
# entry, and a tick that sweeps the same terminal card twice is ordinary.
sweep ABC-1 >/dev/null 2>&1
[[ "$(slots)" == "1" ]] \
  && ok "sweeping an already-released card changes nothing" \
  || bad "a second sweep moved the count to $(slots)"

# A dry run must not write the marker, or BOARD_DRY_RUN stops meaning anything.
before="$(wc -l < "$cards/ABC-2/history.jsonl")"
env BOARD_DRY_RUN=1 HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
  bash "$root/skills/board/sweep.sh" ABC-2 >/dev/null 2>&1
after="$(wc -l < "$cards/ABC-2/history.jsonl")"
[[ "$before" == "$after" && "$(slots)" == "1" ]] \
  && ok "a dry run releases nothing" \
  || bad "dry run wrote to history ($before -> $after) or changed the count"

exit "$fail"
