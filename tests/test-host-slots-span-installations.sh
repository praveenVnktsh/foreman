#!/usr/bin/env bash
# Claim: "Host slots across installations" in
# docs/specs/2026-09-14-installations-per-harness-design.md -- `--host-slots`
# on a root with two installations counts both, keyed `<installation>/<board>`,
# and `--may-dispatch` weighs the ceiling against everything on the machine,
# not just the installation asking.
#
# `reconcile.py --host-slots` already walks `siblings()` (bin/installation.py
# --siblings) rather than its own `instances/` alone -- this file is what
# proves that from BOTH sides of a two-installation root, not just the one
# that happens to be current when a test writes its fixture. A regression that
# made `--host-slots` count only the caller's own installation would pass
# every case in test-host-ceiling.sh (which never builds a second
# installation) and still let two installations jointly blow past
# HOST_MAX_CONCURRENT, which is the exact failure this section of the spec
# exists to rule out.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
reconcile="$repo_root/skills/board/reconcile.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$reconcile" ]] || { echo "FAIL: $reconcile is missing or not executable" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect() {
  local want="$1" got="$2" what="$3"
  [[ "$got" == "$want" ]] || fail "$what: expected [$want], got [$got]"
}

verdict_field() {
  local json="$1" expr="$2"
  printf '%s' "$json" | /usr/bin/env python3 -c '
import json
import sys

verdict = json.load(sys.stdin)
checks = {c["name"]: c for c in verdict.get("checks", [])}
print(eval(sys.argv[1], {"v": verdict, "c": checks}))
' "$expr"
}

SPAWN="{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":{\"action\":\"spawn\",\"role\":\"build\",\"attempt\":\"1\"}}"

# write_history <foreman_home> <board> <ticket> <line...>
# Seeds one card's history.jsonl directly on disk, exactly as
# test-host-ceiling.sh does -- `--host-slots` is a local read of these files
# and never asks the agent registry or Linear, so a real spawn is not needed
# to prove it counts a card.
write_history() {
  local home="$1" board="$2" ticket="$3"; shift 3
  local dir="$home/instances/$board/cards/$ticket"
  mkdir -p "$dir"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/history.jsonl"; done
}

# ============================================================================
# Two installations, one board each, two held cards apiece -- total 4.
# ============================================================================

root="$work_dir/root"
mkdir -p "$root"

# One repo directory is enough for both boards: boards.py only checks that
# the declared repo is a directory. It still needs a board.toml bin/contract.py
# accepts, though -- config.sh sources contract.py against THIS board's own
# repo for the instance named in FOREMAN_INSTANCE, not just boards.toml's
# roster, so a target with no board.toml at all fails config.sh's own load
# before --host-slots is ever reached.
target="$work_dir/target"
mkdir -p "$target"
git -c init.defaultBranch=main init -q "$target"
fixture_board_toml "$target"
git -C "$target" -c user.name="Host Slots Test" -c user.email="host-slots-test@example.com" \
  -c commit.gpgsign=false add board.toml
git -C "$target" -c user.name="Host Slots Test" -c user.email="host-slots-test@example.com" \
  -c commit.gpgsign=false commit -q -m "Seed"

# Two installations under one root. One is the default because a root with
# several installations and none refuses on every read; default status plays
# no part in --host-slots or --may-dispatch, which weigh every sibling equally.
fixture_add_installation "$root" first claude --default
fixture_add_installation "$root" second claude

first_home="$root/.foreman/first"
second_home="$root/.foreman/second"

fixture_add_board_in "$first_home" boardA "$target"
fixture_add_board_in "$second_home" boardB "$target"

write_history "$first_home" boardA PRA-1 "$SPAWN"
write_history "$first_home" boardA PRA-2 "$SPAWN"
write_history "$second_home" boardB PRA-3 "$SPAWN"
write_history "$second_home" boardB PRA-4 "$SPAWN"

run_host_slots() { # <foreman_home> <board>
  HOME="$root" FOREMAN_HOME="$1" FOREMAN_INSTANCE="$2" "$reconcile" --host-slots
}

from_first="$(run_host_slots "$first_home" boardA)"
from_second="$(run_host_slots "$second_home" boardB)"

expect "4" "$(verdict_field "$from_first" 'v["total"]')" \
  "--host-slots run from the first installation counts both installations' cards"
expect "4" "$(verdict_field "$from_second" 'v["total"]')" \
  "--host-slots run from the second installation counts both installations' cards too"
echo "ok  --host-slots from either installation reports the same machine-wide total"

expect "2" "$(verdict_field "$from_first" 'v["instances"]["first/boardA"]')" \
  "the first installation's board is keyed <installation>/<board>"
expect "2" "$(verdict_field "$from_first" 'v["instances"]["second/boardB"]')" \
  "the second installation's board is keyed <installation>/<board> too, seen from the first"
expect "2" "$(verdict_field "$from_second" 'v["instances"]["first/boardA"]')" \
  "the first installation's board is still keyed <installation>/<board>, seen from the second"
expect "2" "$(verdict_field "$from_second" 'v["instances"]["second/boardB"]')" \
  "the second installation's board is keyed <installation>/<board> from its own side too"
echo "ok  --host-slots keys every board <installation>/<board>, from either side"

# ============================================================================
# --may-dispatch weighs the joint total against HOST_MAX_CONCURRENT.
# ============================================================================

run_may_dispatch() { # <foreman_home> <board> HOST_MAX_CONCURRENT
  HOME="$root" FOREMAN_HOME="$1" FOREMAN_INSTANCE="$2" HOST_MAX_CONCURRENT="$3" \
    "$reconcile" --may-dispatch "$2"
}

ceiling_first="$(run_may_dispatch "$first_home" boardA 4 || true)"
ceiling_second="$(run_may_dispatch "$second_home" boardB 4 || true)"

[[ -n "$ceiling_first" ]] ||
  fail "--may-dispatch from the first installation allowed a dispatch at the ceiling (4 held of 4): expected a refusal naming it"
case "$ceiling_first" in
  *"4"*"4"*) : ;;
  *) fail "--may-dispatch's refusal did not name the ceiling (4 of 4): $ceiling_first" ;;
esac
[[ -n "$ceiling_second" ]] ||
  fail "--may-dispatch from the second installation allowed a dispatch at the ceiling too: it must see the SAME joint total, not just its own board's two cards"
echo "ok  --may-dispatch refuses from either installation once their joint total reaches HOST_MAX_CONCURRENT"

room_first="$(run_may_dispatch "$first_home" boardA 5)"
room_second="$(run_may_dispatch "$second_home" boardB 5)"

expect "" "$room_first" \
  "--may-dispatch allows a dispatch from the first installation once the ceiling is raised above the joint total"
expect "" "$room_second" \
  "--may-dispatch allows a dispatch from the second installation too, under the same raised ceiling"
echo "ok  --may-dispatch allows a dispatch from either installation once HOST_MAX_CONCURRENT covers the joint total"

# ============================================================================
# A legacy single home (no installation.toml) still reports its own count,
# with the same <installation>/<board> key shape -- siblings() answers with
# itself alone, named `claude`.
# ============================================================================

legacy_home="$work_dir/legacy-home"
legacy_target="$work_dir/legacy-target"
mkdir -p "$legacy_target"
git -c init.defaultBranch=main init -q "$legacy_target"
fixture_board_toml "$legacy_target"
git -C "$legacy_target" -c user.name="Host Slots Test" -c user.email="host-slots-test@example.com" \
  -c commit.gpgsign=false add board.toml
git -C "$legacy_target" -c user.name="Host Slots Test" -c user.email="host-slots-test@example.com" \
  -c commit.gpgsign=false commit -q -m "Seed"
fixture_add_instance "$legacy_home" legacyBoard "$legacy_target"

write_history "$legacy_home/.foreman" legacyBoard PRA-9 "$SPAWN"

legacy_json="$(HOME="$legacy_home" FOREMAN_HOME="$legacy_home/.foreman" \
  FOREMAN_INSTANCE=legacyBoard "$reconcile" --host-slots)"

expect "1" "$(verdict_field "$legacy_json" 'v["total"]')" \
  "an un-migrated home still reports its own count"
expect "1" "$(verdict_field "$legacy_json" 'v["instances"]["claude/legacyBoard"]')" \
  "an un-migrated home's board is keyed claude/<board> -- siblings() names a lone home claude, so the key shape stays <installation>/<board> even with no installation.toml anywhere"
echo "ok  a legacy single home reports its own count with the same <installation>/<board> key shape"

echo "PASS: host slots span every installation under a root, from any of them"
