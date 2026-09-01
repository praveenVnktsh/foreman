#!/usr/bin/env bash
# Claim: dispatch.sh refuses a card that would exceed a concurrency ceiling, and
# lets through a card already holding a slot.
#
# SKILL.md states the arithmetic exactly, but it is prose an agent is asked to
# follow, and prose is not a gate. On 2026-09-01 a tick adopted five cards left
# In Progress by a previous layout and dispatched a build for each, against a
# MAX_CONCURRENT of 1. The machine reached a load average of 14 with four
# builds, a tick and a self-hosted CI runner competing for 14GB, on a night an
# OOM had already killed that runner once.
#
# The second half matters as much as the first. A resume, a fix, or a reviewer
# for a card the board is ALREADY working must pass. Refusing those would block
# every fix-dispatch behind the card's own slot, which is worse than no gate:
# the board would stall with its limit satisfied and nothing able to proceed.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"; target="$work/target"; origin="$work/origin"
mkdir -p "$target"
git init -q --bare "$origin"
git init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$target" remote add origin "$origin"
git -C "$target" push -q origin main
fixture_add_board "$home" demo "$target"

stub="$work/bin"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"; chmod +x "$stub/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/gh"; chmod +x "$stub/gh"
echo "a prompt" > "$work/prompt.md"

# A card holds a slot when its history has a spawn and no release.
#
# The timestamp must be NOW, not a fixed date. `--host-slots` stops counting a
# card whose last entry is older than HOST_SLOT_STALE_MINUTES (720 by default),
# which is the backstop that keeps a missed `released` marker from wedging every
# board on the machine forever. A hardcoded date makes this fixture pass today
# and silently stop exercising the gate tomorrow.
hold() {
  local d="$home/.foreman/instances/demo/cards/$1"
  mkdir -p "$d"
  printf '{"at":"%s","event":{"action":"spawn","name":"x","attempt":"1"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/history.jsonl"
}

dispatch() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$stub:$PATH" MAX_CONCURRENT="$1" HOST_MAX_CONCURRENT="$2" BOARD_DRY_RUN=1 \
    bash "$root/skills/board/dispatch.sh" --ticket "$3" --role build --attempt 1 \
      --prompt-file "$work/prompt.md" 2>&1
}

# --- an empty board dispatches
out="$(dispatch 1 4 ABC-1)"
case "$out" in *"DRY RUN"*) ok "an empty board dispatches" ;; *) bad "empty board: $out" ;; esac

# --- a board at MAX_CONCURRENT refuses a NEW card, and says what is holding
hold ABC-1
out="$(dispatch 1 4 ABC-2)"
case "$out" in
  *"concurrency ceiling"*ABC-1*) ok "a full board refuses a new card and names what holds the slot" ;;
  *) bad "expected a ceiling refusal naming ABC-1, got: $out" ;;
esac

# --- and it must not charge the ticket an attempt for it
case "$out" in
  *"must not consume its attempt budget"*) ok "the refusal says it is not the card's fault" ;;
  *) bad "refusal did not protect the attempt budget: $out" ;;
esac

# --- the card ALREADY holding the slot still dispatches: resumes and reviewers
out="$(dispatch 1 4 ABC-1)"
case "$out" in
  *"DRY RUN"*) ok "a card already holding a slot is not blocked by its own slot" ;;
  *) bad "blocked a resume of a card already on the board: $out" ;;
esac

# --- the machine ceiling binds even when the board has room
hold ABC-2; hold ABC-3; hold ABC-4
out="$(dispatch 9 4 ABC-9)"
case "$out" in
  *"this machine holds 4 of 4"*) ok "the machine ceiling binds even with board slots free" ;;
  *) bad "expected a host-ceiling refusal, got: $out" ;;
esac

# --- an unreadable count is advisory, never a blocker
mv "$root/skills/board/reconcile.py" "$work/reconcile.hidden" 2>/dev/null || true
out="$(dispatch 1 4 ABC-77)"
mv "$work/reconcile.hidden" "$root/skills/board/reconcile.py" 2>/dev/null || true
case "$out" in
  *"DRY RUN"*) ok "a count it cannot read does not block a dispatch" ;;
  *) bad "an unreadable slot count blocked a dispatch: $out" ;;
esac

exit "$fail"
