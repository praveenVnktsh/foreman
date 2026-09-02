#!/usr/bin/env bash
# Claim: `reconcile.py --board-order` names the boards for one pass least
# recently served first, so which boards a tick reaches stops depending on where
# their names sort.
#
# The failure it prevents: one tick agent works every board on this machine, a
# slice each. Its board list came from `bin/boards.py --list`, which prints them
# in NAME order -- the same order for every pass of every tick. But
# TICK_BUDGET_MINUTES and TICK_MAX_PASSES bound the WHOLE tick, not each board,
# so a tick that spends its budget mid-pass stops at whichever board it had
# reached. With a fixed order that is always the same tail of the list, tick
# after tick, and a board a tick never reached reports exactly what a board with
# no work reports. Nothing says so.
#
# The order is DERIVED, never stored. Every slice that moves a card forward
# appends to that card's history.jsonl through config.sh's card_log, so the
# newest `at` across a board's cards is when that board last did something. A
# cursor file would be the one thing SKILL.md forbids: a fact that exists only
# in the sidecar, which is documented as "a cache, never truth".
#
# It drives the real script against a temporary FOREMAN_HOME. No Linear, no gh,
# no `claude agents` -- the read is local by construction.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

fh="$work/.foreman"
mkdir -p "$fh/instances"

# One repository per board. config.sh loads the target's contract before
# answering anything, even a question about the whole machine, so each fixture
# board needs a board.toml that bin/contract.py accepts.
make_repo() {  # $1 board name
  local repo="$work/repo-$1"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  fixture_board_toml "$repo"
  printf 'x\n' > "$repo/f"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@e -c user.name=t commit -qm s
}

declare_boards() {  # $1..$n board names
  : > "$fh/boards.toml"
  local name
  for name in "$@"; do
    [[ -d "$work/repo-$name" ]] || make_repo "$name"
    printf '[boards.%s]\nrepo = "%s"\n\n' "$name" "$work/repo-$name" >> "$fh/boards.toml"
  done
}

served() {  # $1 board, $2 ticket, $3.. one `at` stamp per history line
  local board="$1" ticket="$2"; shift 2
  local dir="$fh/instances/$board/cards/$ticket" at
  mkdir -p "$dir"
  : > "$dir/history.jsonl"
  for at in "$@"; do
    printf '{"at":"%s","event":{"action":"spawn","name":"x","attempt":"1"}}\n' \
      "$at" >> "$dir/history.jsonl"
  done
}

reset_machine() { rm -rf "$fh/instances"; mkdir -p "$fh/instances"; }

# `--board-order` sources config.sh at startup, which refuses to guess which
# repository it serves -- so FOREMAN_INSTANCE must be set even for a question
# about the whole machine. Ask as any declared board; the answer is the same.
order() {  # $1 board to ask as -> the order, comma separated
  env FOREMAN_HOME="$fh" FOREMAN_INSTANCE="$1" \
    "$root/skills/board/reconcile.py" --board-order 2>/dev/null \
    | python3 -c 'import json, sys; print(",".join(json.load(sys.stdin)["order"]))'
}

# The evidence that produced the order, so a board can say why it went where it
# did. `none` for a board that has never been served -- printed as a word rather
# than as an empty line, so a missing key cannot pass for a null one.
stamp_of() {  # $1 board to ask as, $2 board to report -> its last_served
  env FOREMAN_HOME="$fh" FOREMAN_INSTANCE="$1" \
    "$root/skills/board/reconcile.py" --board-order 2>/dev/null \
    | python3 -c '
import json, sys
report = {b["board"]: b["last_served"] for b in json.load(sys.stdin)["boards"]}
print(report[sys.argv[1]] if report[sys.argv[1]] is not None else "none")
' "$2"
}

is() {  # $1 name, $2 wanted, $3 got
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1: wanted [$2], got [$3]"
}

OLD='2026-01-01T00:00:00Z'
MID='2026-06-01T00:00:00Z'
NEW='2026-08-01T00:00:00Z'

# --- a board that has never been served goes first --------------------------
#
# `alpha` sorts first by name AND was served moments ago; `zulu` sorts last by
# name and has never run at all. Under the old name order zulu was reached last
# on every pass of every tick, which is exactly how a never-dispatched board
# stays never-dispatched.
declare_boards alpha zulu
reset_machine
served alpha PRA-1 "$NEW"
is "a board that has never been served goes first, whatever its name" \
  "zulu,alpha" "$(order alpha)"

# --- and it says so, rather than inventing a time ---------------------------
is "a board with no history reports no last_served, not a guessed one" \
  "none" "$(stamp_of alpha zulu)"

# --- between two served boards, the one served longer ago goes first --------
reset_machine
served alpha PRA-1 "$NEW"
served zulu  PRA-9 "$OLD"
is "the board served longer ago goes first" "zulu,alpha" "$(order alpha)"

served zulu PRA-9 "$OLD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
is "serving a board sends it to the back of the next pass" \
  "alpha,zulu" "$(order alpha)"

# --- a board's newest card is what dates it ---------------------------------
#
# Not its oldest, and not whichever card `os.listdir` happened to return first.
# A board with one long-finished card and one live card was served recently.
reset_machine
served alpha PRA-1 "$OLD"
served alpha PRA-2 "$NEW"
served zulu  PRA-9 "$MID"
is "a board is dated by its newest card, not its oldest" \
  "zulu,alpha" "$(order alpha)"
is "and the report names that newest stamp" "$NEW" "$(stamp_of alpha alpha)"

# --- a released card still counts as service --------------------------------
#
# This is what separates the order from "how many slots each board holds".
# Ordering by held slots would put the board with three cards in flight LAST --
# and that is the board with the most merges waiting, so it would starve the
# boards that most need a slice. A card that released a slot was still a slice
# doing work at the moment it released it.
reset_machine
released_dir="$fh/instances/alpha/cards/PRA-1"
mkdir -p "$released_dir"
printf '{"at":"%s","event":{"action":"released","reason":"done"}}\n' "$NEW" \
  > "$released_dir/history.jsonl"
served zulu PRA-9 "$OLD"
is "a card that released its slot still dates the board that released it" \
  "zulu,alpha" "$(order alpha)"

# --- a corrupt line does not lose the board's timestamp ---------------------
#
# `history.jsonl` is appended to by hand-followed prose as well as by
# dispatch.sh, and a half-written line is the shape that produces. Losing the
# stamp would read as "never served" and pin that board at the front of every
# pass forever.
reset_machine
served alpha PRA-1 "$NEW"
served zulu  PRA-9 "$OLD"
printf '{not json at all\n' >> "$fh/instances/zulu/cards/PRA-9/history.jsonl"
is "a corrupt trailing line falls back to the last line that parsed" \
  "$OLD" "$(stamp_of alpha zulu)"
is "so the board keeps its place in the order" "zulu,alpha" "$(order alpha)"

# --- equal service breaks on the name, so the order is total ----------------
#
# The same machine must print the same order twice. A partial order would make
# which board a spent budget cut off depend on dictionary iteration.
reset_machine
served alpha PRA-1 "$MID"
served zulu  PRA-9 "$MID"
is "boards served at the same moment break the tie on their name" \
  "alpha,zulu" "$(order alpha)"

# --- every declared board appears exactly once ------------------------------
#
# A pass is one slice for EVERY board. A board missing from the order is a board
# the tick never looks at, which is the failure this file exists to prevent.
reset_machine
declare_boards alpha beta gamma zulu
served beta PRA-2 "$NEW"
got="$(order alpha)"
is "every declared board is named, and each of them once" \
  "alpha,gamma,zulu,beta" "$got"

# --- an undeclared board's leftover runtime directory is not a board --------
#
# `boards.toml` declares what this machine runs. A directory a removed board
# left behind must not take a slice of every pass. This is the roster
# `--host-slots` already reads, and the two must not disagree about what a board
# is.
served theta PRA-77 "$OLD"
is "a leftover runtime directory for an undeclared board takes no turn" \
  "alpha,gamma,zulu,beta" "$(order alpha)"

# --- a machine that declares no boards refuses, rather than printing quiet ----
#
# An empty order would read to the tick as "every board is done", which is the
# one answer this whole mode exists to make impossible: a board nobody reached
# must never look like a board with nothing to do. `boards.toml` is what
# declares a board, so a machine with none cannot resolve the board being asked
# as, and the refusal names the file and the name it could not find.
: > "$fh/boards.toml"
out="$(env FOREMAN_HOME="$fh" FOREMAN_INSTANCE=alpha \
  "$root/skills/board/reconcile.py" --board-order 2>&1)"; status=$?
case "$status:$out" in
  0:*) bad "a machine declaring no boards printed an order: $out" ;;
  *"no board named alpha"*) ok "a machine that declares no boards refuses by name" ;;
  *) bad "refused, but the message never names the board it could not find: $out" ;;
esac

exit "$fail"
