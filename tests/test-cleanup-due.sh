#!/usr/bin/env bash
# Claim: `reconcile.py --cleanup-due <board>` answers "is this board due a
# scheduled cleanup" from the stamp, the agent registry and the slot counts --
# and names the first reason it is not, so the tick never guesses.
#
# The failure it prevents: the tick keeps no state, so "due" has to come from
# somewhere on disk. A cleanup pass reads the whole codebase on the strongest
# model and files a card, so getting this wrong in the permissive direction
# runs one every tick -- and getting it wrong in the other direction runs none,
# which looks exactly like a board with nothing to clean up. Neither says so.
#
# The stamp is written BEFORE the dispatch (`--cleanup-started`), so an agent
# that dies in its first minute, or that honestly files nothing, does not come
# back on the very next tick.
#
# It drives the real script against a temporary FOREMAN_HOME, with `claude`
# stubbed at the external boundary -- the agent registry is the one thing here
# that is not a local file.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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

# A `claude` that answers `agents --json --all` from a file this test writes.
# Liveness is the only question here that a local file cannot answer, so it is
# the only thing stubbed.
stub_bin="$work/bin"
registry="$work/agents.json"
mkdir -p "$stub_bin"
printf '[]\n' > "$registry"
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then
  cat "$registry"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/claude"

# Prints the script's stdout and exits with its status, so every case below
# reads `out="$(reconcile ...)"; status=$?`. Capturing the status INSIDE the
# function does not work: command substitution runs it in a subshell, and the
# assignment never reaches this one.
reconcile() {  # $1.. -> reconcile.py's argv
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" \
    FOREMAN_INSTANCE=demo "${extra_env[@]}" \
    "$root/skills/board/reconcile.py" "$@" 2>"$work/err"
}

# bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
# error, so this array always holds at least one harmless assignment.
extra_env=(FOREMAN_CLEANUP_TEST=1)

stamp_now() {  # $1 days ago -> a CARD_LOG_STAMP timestamp
  python3 -c '
import sys
from datetime import datetime, timedelta, timezone
days = float(sys.argv[1])
print((datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$1"
}

card_history() {  # $1 ticket, $2 ISO stamp -> one spawn line for that card
  local dir="$fh/instances/demo/cards/$1"
  mkdir -p "$dir"
  printf '{"at":"%s","event":{"action":"spawn","name":"x","role":"build","attempt":"1"}}\n' \
    "$2" > "$dir/history.jsonl"
}

# --- no stamp ---------------------------------------------------------------
#
# The first pass after this feature lands has no stamp anywhere, and every
# board is due at once. That is deliberate: a board with no stamp has never
# had a cleanup, not "had one just now".
out="$(reconcile --cleanup-due demo)"; status=$?
if [[ "$status" -eq 0 && "$out" == "due" ]]; then
  ok "a board with no stamp is due"
else
  bad "a board with no stamp is due: status=$status out=$out $(cat "$work/err")"
fi

# --- the stamp the tick writes before it dispatches --------------------------
out="$(reconcile --cleanup-started demo)"; status=$?
if [[ "$status" -eq 0 && -z "$out" && -f "$fh/instances/demo/last-cleanup" ]]; then
  ok "--cleanup-started writes the stamp and prints nothing"
else
  bad "--cleanup-started writes the stamp and prints nothing: status=$status out=$out"
fi

out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"next due"*) ok "a board stamped just now is not due, and says when it next is" ;;
  *) bad "a board stamped just now is not due: status=$status out=$out" ;;
esac

# --- a stamp older than every_days ------------------------------------------
#
# The fixture board declares no [cleanup] table, so contract.py's default of 3
# days applies. Four days back is past it.
printf '%s\n' "$(stamp_now 4)" > "$fh/instances/demo/last-cleanup"
out="$(reconcile --cleanup-due demo)"; status=$?
if [[ "$status" -eq 0 && "$out" == "due" ]]; then
  ok "a stamp older than every_days is due again"
else
  bad "a stamp older than every_days is due again: status=$status out=$out"
fi

# --- a cleanup agent that is still running -----------------------------------
#
# dispatch.sh names a cleanup agent `foreman/[<installation>/]<board>/cleanup/
# cleanup-<attempt>` -- it is not a card, so it takes the ticket `cleanup`.
# Dispatching a second one would have two agents reading the same codebase and
# filing the same card twice.
cat > "$registry" <<'JSON'
[{"name": "foreman/demo/cleanup/cleanup-1", "sessionId": "s1", "startedAt": 1,
  "cwd": "/tmp", "state": "working", "pid": 4242}]
JSON
out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"foreman/demo/cleanup/cleanup-1"*)
    ok "a live cleanup agent stops a second one, and is named" ;;
  *) bad "a live cleanup agent stops a second one: status=$status out=$out" ;;
esac
printf '[]\n' > "$registry"

# --- the board's own MAX_CONCURRENT -----------------------------------------
#
# A cleanup agent holds a slot like any other agent. The fixture board declares
# no [limits], so contract.py's MAX_CONCURRENT default of 1 applies, and one
# card in flight is the whole board.
card_history ACME-1 "$(stamp_now 0)"
out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"1 of its 1 card slot"*) ok "a board already at MAX_CONCURRENT is not due" ;;
  *) bad "a board already at MAX_CONCURRENT is not due: status=$status out=$out" ;;
esac

# --- the machine ceiling -----------------------------------------------------
#
# Same question one level up, and asked through the same dispatch_verdict()
# every build is weighed by: a cleanup agent eats the same RAM and disk.
rm -rf "$fh/instances/demo/cards"
extra_env=(HOST_MAX_CONCURRENT=0)
out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"of 0 slots"*) ok "a machine with no free slot is not due" ;;
  *) bad "a machine with no free slot is not due: status=$status out=$out" ;;
esac
extra_env=(FOREMAN_CLEANUP_TEST=1)

# --- every_days = 0 ----------------------------------------------------------
#
# The operator's explicit off switch. It has to answer "off" and not "not yet",
# or an operator who turned cleanup off reads the tick's log as a cadence.
cat >> "$repo/board.toml" <<'TOML'

[cleanup]
every_days = 0
TOML
out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"off"*) ok "every_days = 0 is off, and says so" ;;
  *) bad "every_days = 0 is off: status=$status out=$out" ;;
esac
python3 - "$repo/board.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, "w").write(text.split("\n[cleanup]")[0] + "\n")
PY

# --- --cleanup-since ---------------------------------------------------------
#
# What brief.py hands the cleanup agent as the start of the window it reads.
rm -f "$fh/instances/demo/last-cleanup"
out="$(reconcile --cleanup-since demo)"; status=$?
if [[ "$status" -eq 0 && "$out" == "never" ]]; then
  ok "--cleanup-since prints never before the first cleanup"
else
  bad "--cleanup-since prints never before the first cleanup: status=$status out=$out"
fi

reconcile --cleanup-started demo >/dev/null
out="$(reconcile --cleanup-since demo)"; status=$?
if [[ "$status" -eq 0 && "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  ok "--cleanup-since prints the stamp in the card log's own format"
else
  bad "--cleanup-since prints the stamp: status=$status out=$out"
fi

# --- an undeclared board -----------------------------------------------------
#
# Refuse rather than answer about `instances/<typo>/`: a cleanup that never
# runs on the board the operator meant looks exactly like a board with nothing
# to clean up.
out="$(reconcile --cleanup-due nosuchboard)"; status=$?
case "$status:$(cat "$work/err")" in
  2:*"no board named nosuchboard"*) ok "an undeclared board is refused by name" ;;
  *) bad "an undeclared board is refused by name: status=$status err=$(cat "$work/err")" ;;
esac

# --- the slot a finished cleanup pass is still holding ------------------------
#
# A cleanup agent is dispatched under the ticket `cleanup`, so it holds a slot
# through `cards/cleanup/history.jsonl` exactly like a card. When its pass ends
# and nothing sweeps it, that pseudo-card holds the board's only slot for
# HOST_SLOT_STALE_MINUTES -- and the reason line read identically to a slot held
# by real card work, so the one thing that releases it was invisible. The live
# check above has already answered `no cleanup agent is running`, so a held
# `cleanup` slot here is always a finished pass.
rm -rf "$fh/instances/demo/cards"
rm -f "$fh/instances/demo/last-cleanup"
card_history cleanup "$(stamp_now 0)"
out="$(reconcile --cleanup-due demo)"; status=$?
case "$status:$out" in
  1:*"sweep.sh cleanup"*) ok "a slot held by a finished cleanup names the sweep that frees it" ;;
  *) bad "a slot held by a finished cleanup names the sweep that frees it: status=$status out=$out $(cat "$work/err")" ;;
esac
rm -rf "$fh/instances/demo/cards"

# --- a board that is not the one this process resolved ------------------------
#
# `cleanup_verdict` takes a board argument, but CLEANUP_EVERY_DAYS,
# MAX_CONCURRENT and the agent-name prefix all come from the contract config.sh
# resolved for $FOREMAN_INSTANCE. Answering about another board weighs one
# board's stamp against another board's cadence, agents and ceiling -- and
# `--cleanup-started` would stamp a board nobody asked about, skipping its next
# three days of cleanup with nothing saying so. A stale FOREMAN_INSTANCE is this
# skill's oldest bug shape, so the mismatch refuses and names both boards.
fixture_add_board "$home" other "$repo"
out="$(reconcile --cleanup-due other)"; status=$?
case "$status:$(cat "$work/err")" in
  2:*demo*other*|2:*other*demo*) ok "--cleanup-due refuses a board this process did not resolve" ;;
  *) bad "--cleanup-due refuses a board this process did not resolve: status=$status out=$out err=$(cat "$work/err")" ;;
esac

out="$(reconcile --cleanup-started other)"; status=$?
if [[ "$status" -eq 2 && ! -f "$fh/instances/other/last-cleanup" ]]; then
  ok "--cleanup-started stamps no board but the one this process resolved"
else
  bad "--cleanup-started stamps no board but the one this process resolved: status=$status out=$out"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: cleanup is due on the stamp, the agents and the slots\n'
exit "$fail"
