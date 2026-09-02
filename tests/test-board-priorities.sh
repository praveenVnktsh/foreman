#!/usr/bin/env bash
# Claim: boards share the machine ceiling by priority, and no declared board is
# starved.
#
# HOST_MAX_CONCURRENT bounds cards in flight across every board sharing a
# machine, because RAM and disk are shared -- on 2026-09-01 four agents plus a CI
# runner took a 14GB box to a load average of 14. First-come-first-served is how
# one busy board holds every slot and a second board never dispatches at all,
# which looks exactly like a board with no work.
#
# The rule: each board earns a floor, never below 1, and may use capacity nobody
# else is owed.
#     floor(b)     = max(1, host_max * priority(b) / sum of priorities)
#     available(b) = host_max - total_held - sum of other boards' unmet floors
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
for b in alpha beta; do
  mkdir -p "$work/repo-$b" "$fh/instances/$b"
  git init -q -b main "$work/repo-$b"
  # config.sh loads the target's contract before answering anything, even a
  # question about the whole machine, so each fixture repo needs one.
  fixture_board_toml "$work/repo-$b"
  printf 'x\n' > "$work/repo-$b/f"
  git -C "$work/repo-$b" add -A
  git -C "$work/repo-$b" -c user.email=t@e -c user.name=t commit -qm s
done

declare_boards() {  # $1..$n = "name:priority" or "name" for the default
  : > "$fh/boards.toml"
  for spec in "$@"; do
    local name="${spec%%:*}" prio="${spec#*:}"
    printf '[boards.%s]\nrepo = "%s"\n' "$name" "$work/repo-$name" >> "$fh/boards.toml"
    [[ "$spec" == *:* ]] && printf 'priority = %s\n' "$prio" >> "$fh/boards.toml"
    printf '\n' >> "$fh/boards.toml"
  done
}

hold() {  # $1 board, $2 ticket
  local d="$fh/instances/$1/cards/$2"
  mkdir -p "$d"
  printf '{"at":"%s","event":{"action":"spawn","name":"x","attempt":"1"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/history.jsonl"
}

# reconcile.py sources config.sh at startup, which refuses to guess which
# repository it serves -- so FOREMAN_INSTANCE must be set even for a question
# about the whole machine. Ask as the board being asked about.
may() {  # $1 board, $2 host_max -> prints the refusal, empty if allowed
  env FOREMAN_HOME="$fh" FOREMAN_INSTANCE="$1" HOST_MAX_CONCURRENT="$2" \
    "$root/skills/board/reconcile.py" --may-dispatch "$1" 2>/dev/null
}

# --- the worked example: host_max 4, alpha 3, beta 1 -> floors 3 and 1 -------
declare_boards alpha:3 beta:1

[[ -z "$(may alpha 4)" ]] && ok "with nothing held, the high-priority board may dispatch" \
  || bad "alpha refused on an empty machine: $(may alpha 4)"

hold alpha A-1; hold alpha A-2
[[ -z "$(may alpha 4)" ]] && ok "it may take its third slot" || bad "refused at 2 held: $(may alpha 4)"

hold alpha A-3
r="$(may alpha 4)"
case "$r" in
  *beta*) ok "it may NOT take the fourth: that slot is reserved for beta" ;;
  "") bad "alpha took a slot beta is owed" ;;
  *) bad "refused, but not for beta: $r" ;;
esac

[[ -z "$(may beta 4)" ]] && ok "and beta may still take its floor of one" \
  || bad "beta starved at its own floor: $(may beta 4)"

hold beta B-1
r="$(may beta 4)"
case "$r" in *"4 of 4"*) ok "with the machine full, the next ask names the ceiling" ;;
  *) bad "machine full -> $r" ;; esac

# --- an undeclared priority defaults to 1, so nothing changes underneath an
#     operator who never asked for priorities ------------------------------
rm -rf "$fh/instances"; mkdir -p "$fh/instances"
declare_boards alpha beta
hold alpha A-1; hold alpha A-2; hold alpha A-3
r="$(may alpha 4)"
case "$r" in *beta*) ok "boards with no declared priority divide evenly" ;;
  *) bad "even split -> ${r:-allowed}" ;; esac

# --- priority 0 has no floor: it takes surplus and reserves nothing ----------
rm -rf "$fh/instances"; mkdir -p "$fh/instances"
declare_boards alpha:3 beta:0
hold alpha A-1; hold alpha A-2; hold alpha A-3
[[ -z "$(may alpha 4)" ]] \
  && ok "a priority-0 board reserves nothing, so the fourth slot is free" \
  || bad "a priority-0 board reserved a slot: $(may alpha 4)"

# --- a malformed priority is refused, not guessed at ------------------------
printf '[boards.alpha]\nrepo = "%s"\npriority = "high"\n' "$work/repo-alpha" > "$fh/boards.toml"
if out="$(env FOREMAN_HOME="$fh" "$root/bin/boards.py" --file "$fh/boards.toml" alpha 2>&1)"; then
  bad "a non-integer priority loaded: $out"
else
  case "$out" in *priority*) ok "a non-integer priority is refused by name" ;; *) bad "$out" ;; esac
fi
printf '[boards.alpha]\nrepo = "%s"\npriority = true\n' "$work/repo-alpha" > "$fh/boards.toml"
if env FOREMAN_HOME="$fh" "$root/bin/boards.py" --file "$fh/boards.toml" alpha >/dev/null 2>&1; then
  bad "priority = true loaded as 1 instead of being refused"
else
  ok "a boolean priority is refused rather than read as 1"
fi

exit "$fail"
