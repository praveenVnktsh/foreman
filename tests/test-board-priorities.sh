#!/usr/bin/env bash
# Claim: boards share the machine ceiling by priority, a board reserves its floor
# only while it is asking for work, and no declared board that is asking is
# starved.
#
# HOST_MAX_CONCURRENT bounds cards in flight across every board sharing a
# machine, because RAM and disk are shared -- on 2026-09-01 four agents plus a CI
# runner took a 14GB box to a load average of 14. First-come-first-served is how
# one busy board holds every slot and a second board never dispatches at all,
# which looks exactly like a board with no work.
#
# The rule: each board earns a floor, never below 1, and may use capacity nobody
# else is owed. A floor is reserved only for a board with FRESH DEMAND -- one
# that asked for a slot within DEMAND_STALE_MINUTES.
#     floor(b)     = max(1, host_max * priority(b) / sum of priorities)
#     available(b) = host_max - total_held
#                    - sum of other DEMANDING boards' unmet floors
#
# Measured 2026-09-20 on a machine serving four boards at priority 2 with
# host_max 10: every board had a floor of 2, so the one board with a full Todo
# column could never exceed 4 of 10 while the other three sat idle with nothing
# to build. An idle board now reserves nothing.
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

# The real verb dispatch.sh calls when a board has a card it wants to start.
want() {  # $1 board
  env FOREMAN_HOME="$fh" FOREMAN_INSTANCE="$1" \
    "$root/skills/board/reconcile.py" --wants-slot "$1"
}

# Demand as it reads once it has aged out. Written through the same stamp file
# the real verb writes, because the claim is about the stamp going stale and not
# about any second way of recording one.
want_stale() {  # $1 board, $2 minutes ago
  mkdir -p "$fh/instances/$1"
  python3 - "$fh/instances/$1/wants-slot" "$2" <<'EOF'
import sys
from datetime import datetime, timedelta, timezone
path, minutes = sys.argv[1], float(sys.argv[2])
when = datetime.now(timezone.utc) - timedelta(minutes=minutes)
open(path, "w").write(when.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n")
EOF
}

reset() { rm -rf "$fh/instances"; mkdir -p "$fh/instances"; }

# --- the worked example: host_max 4, alpha 3, beta 1 -> floors 3 and 1 -------
#     beta asks for work throughout, so its floor is reserved.
declare_boards alpha:3 beta:1
want beta

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

# --- THE POINT OF DEMAND-GATING: an idle board reserves nothing --------------
#     Same boards, same floors, same holdings as the worked example above. The
#     only difference is that beta never asked, so alpha may have the machine.
reset
declare_boards alpha:3 beta:1
hold alpha A-1; hold alpha A-2; hold alpha A-3
[[ -z "$(may alpha 4)" ]] \
  && ok "a board that is not asking for work reserves nothing" \
  || bad "an idle beta still reserved a slot: $(may alpha 4)"

# --- demand arrives, and the floor comes back with it ------------------------
want beta
r="$(may alpha 4)"
case "$r" in *beta*) ok "once beta asks, its floor is reserved again" ;;
  *) bad "beta asked and was owed nothing: ${r:-allowed}" ;; esac

# --- demand goes stale, and the floor goes with it ---------------------------
#     A board whose last ask predates DEMAND_STALE_MINUTES reads as idle. This
#     is what stops a board that stopped asking from holding capacity forever.
reset
declare_boards alpha:3 beta:1
hold alpha A-1; hold alpha A-2; hold alpha A-3
want_stale beta 10000
[[ -z "$(may alpha 4)" ]] \
  && ok "a stale ask reads as idle, so its floor is released" \
  || bad "a stale ask still reserved a slot: $(may alpha 4)"

# --- a board's own floor never depends on its own demand ---------------------
#     alpha holds everything and beta has never asked through the verb. beta's
#     first ask must still be answered, or the demand marker becomes a
#     chicken-and-egg gate no board can ever pass.
reset
declare_boards alpha:3 beta:1
hold alpha A-1; hold alpha A-2
[[ -z "$(may beta 4)" ]] \
  && ok "a board that has never asked may still take a free slot" \
  || bad "beta refused its first ask: $(may beta 4)"

# --- an undeclared board is refused rather than stamped ----------------------
reset
declare_boards alpha:3 beta:1
if env FOREMAN_HOME="$fh" FOREMAN_INSTANCE=alpha \
  "$root/skills/board/reconcile.py" --wants-slot gamma >/dev/null 2>&1; then
  bad "--wants-slot stamped a board boards.toml does not declare"
else
  [[ -e "$fh/instances/gamma/wants-slot" ]] \
    && bad "--wants-slot created instances/gamma/ for an undeclared board" \
    || ok "--wants-slot refuses a board that is not declared"
fi

# --- an undeclared priority defaults to 1, so nothing changes underneath an
#     operator who never asked for priorities ------------------------------
reset
declare_boards alpha beta
want beta
hold alpha A-1; hold alpha A-2; hold alpha A-3
r="$(may alpha 4)"
case "$r" in *beta*) ok "boards with no declared priority divide evenly" ;;
  *) bad "even split -> ${r:-allowed}" ;; esac

# --- priority 0 has no floor: it takes surplus and reserves nothing ----------
reset
declare_boards alpha:3 beta:0
want beta
hold alpha A-1; hold alpha A-2; hold alpha A-3
[[ -z "$(may alpha 4)" ]] \
  && ok "a priority-0 board reserves nothing even while asking" \
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
