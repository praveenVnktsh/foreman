#!/usr/bin/env bash
# An installation declares the models a rate-limited stage may fall back to,
# and bin/installation.py emits that declaration on every read.
#
# On 2026-09-16 PLAN_MODEL=fable was rate-limited for 11 hours and every card
# needing a plan voided on every pass. skills/board/fallback.py walks a stage
# down FALLBACK_TIERS while its model is limited, never past the stage's
# *_FLOOR, for FALLBACK_COOLDOWN_MINUTES. It reads those from the environment
# config.sh builds out of this loader, so this file pins what the loader
# emits and what it refuses:
#
#   - Claude defaults to fable, opus, sonnet, haiku; codex and opencode to no
#     tiers at all (fallback off), because their model names are the operator's
#     to type and a guessed order is a guessed downgrade.
#   - Every fallback key is emitted even when empty. Consumers count fields.
#   - A floor outside the tiers, a cooldown that is not a positive integer, and
#     an unknown key each refuse: a floor fallback.py can never reach is a
#     protection the operator believes in and does not have.
#
# FOREMAN_HOME is never read: every call passes --home into a temp directory.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
inst="$root/bin/installation.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

# Decoded rather than grepped, so a key that is dropped reads "<missing>"
# instead of passing as an empty value.
decode() { # key -- reads an installation.py record on stdin
  python3 -c '
import sys
v = sys.stdin.buffer.read().split(b"\0")
d = dict(zip(v[::2], v[1::2]))
sys.stdout.write(d.get(sys.argv[1].encode(), b"<missing>").decode())
' "$1"
}

read_key() { # key, args...
  local key="$1"; shift
  "$inst" "$@" | decode "$key"
}

refuses() { # claim, needle, args...
  local claim="$1" needle="$2" err; shift 2
  if err="$("$inst" "$@" 2>&1 >/dev/null)"; then
    bad "$claim -- it loaded instead"; return 0
  fi
  case "$err" in
    *"$needle"*) ok "$claim" ;;
    *) bad "$claim: error did not name '$needle': $err" ;;
  esac
}

# Each home sits alone under its own root, so it is a lone installation and
# the one-default rule never gets in the way of the claim being tested.
home_with() { # name, toml body -- prints the home
  local home="$work/$1/$1"
  mkdir -p "$home"
  printf '%s\n' "$2" >"$home/foreman.toml"
  printf '%s' "$home"
}

codex_models=$'[models]\ntick = "m1"\nplan = "m1"\nbuild = "m2"\nreview = "m2"'

# --- defaults per harness -------------------------------------------------
claude="$(home_with claude 'harness = "claude"')"
check "a claude installation falls back fable, opus, sonnet, haiku by default" \
  "fable opus sonnet haiku" "$(read_key FALLBACK_TIERS --home "$claude")"
check "the cooldown defaults to 60 minutes" \
  "60" "$(read_key FALLBACK_COOLDOWN_MINUTES --home "$claude")"
for key in PLAN_FLOOR BUILD_FLOOR REVIEW_FLOOR; do
  check "$key is emitted empty when no floor is declared" \
    "" "$(read_key "$key" --home "$claude")"
done

# The un-migrated home, with no foreman.toml at all, is a Claude
# installation and gets Claude's list.
bare="$work/bare"; mkdir -p "$bare"
check "a home with no foreman.toml gets the claude tiers" \
  "fable opus sonnet haiku" "$(read_key FALLBACK_TIERS --home "$bare")"

for harness in codex opencode; do
  h="$(home_with "$harness" "harness = \"$harness\"
$codex_models")"
  check "$harness has fallback off by default (FALLBACK_TIERS emitted empty)" \
    "" "$(read_key FALLBACK_TIERS --home "$h")"
  check "$harness still emits the default cooldown" \
    "60" "$(read_key FALLBACK_COOLDOWN_MINUTES --home "$h")"
done

# --- a declared table -------------------------------------------------------
declared="$(home_with declared 'harness = "claude"

[fallback]
tiers = ["fable", "opus", "sonnet"]
cooldown_minutes = 15

[fallback.floor]
plan = "opus"
build = "sonnet"')"
check "declared tiers are emitted in their order" \
  "fable opus sonnet" "$(read_key FALLBACK_TIERS --home "$declared")"
check "a declared cooldown is emitted" \
  "15" "$(read_key FALLBACK_COOLDOWN_MINUTES --home "$declared")"
check "a declared plan floor is emitted as PLAN_FLOOR" \
  "opus" "$(read_key PLAN_FLOOR --home "$declared")"
check "a declared build floor is emitted as BUILD_FLOOR" \
  "sonnet" "$(read_key BUILD_FLOOR --home "$declared")"
check "a stage with no declared floor stays empty beside declared ones" \
  "" "$(read_key REVIEW_FLOOR --home "$declared")"

off="$(home_with off 'harness = "claude"
[fallback]
tiers = []')"
check "a claude installation turns fallback off with tiers = []" \
  "" "$(read_key FALLBACK_TIERS --home "$off")"

codex_on="$(home_with codex_on "harness = \"codex\"
$codex_models
[fallback]
tiers = [\"m1\", \"m2\"]")"
check "a codex installation may declare its own tiers" \
  "m1 m2" "$(read_key FALLBACK_TIERS --home "$codex_on")"

# --- refusals ---------------------------------------------------------------
refuses "a floor that is not one of the tiers refuses" \
  "not one of fallback.tiers" --home "$(home_with floor_out 'harness = "claude"
[fallback]
tiers = ["fable", "opus"]
[fallback.floor]
plan = "haiku"')"

refuses "a floor on a harness with fallback off refuses" \
  "fallback is off" --home "$(home_with floor_off "harness = \"codex\"
$codex_models
[fallback.floor]
plan = \"m1\"")"

refuses "a floor above the stage's own model refuses" \
  "only falls back down" --home "$(home_with floor_up 'harness = "claude"
[fallback.floor]
build = "fable"')"

n=0
for bad_cooldown in 0 -5 '"60"' 1.5 true; do
  n=$((n + 1))
  refuses "cooldown_minutes = $bad_cooldown refuses" \
    "positive integer" --home "$(home_with "cooldown$n" "harness = \"claude\"
[fallback]
cooldown_minutes = $bad_cooldown")"
done

refuses "an unknown key in [fallback] refuses" \
  "unknown key(s) in fallback: cooldown" --home "$(home_with unknown 'harness = "claude"
[fallback]
cooldown = 60')"

refuses "an unknown stage in [fallback.floor] refuses" \
  "unknown key(s) in fallback.floor: cleanup" --home "$(home_with unknown_stage 'harness = "claude"
[fallback.floor]
cleanup = "opus"')"

refuses "a tier holding a space refuses, since the list reaches bash space-separated" \
  "whitespace" --home "$(home_with spaced 'harness = "claude"
[fallback]
tiers = ["fable", "big opus"]')"

harnessed="$(home_with harnessed 'harness = "claude"
[fallback]
tiers = ["claude:opus", "opencode:foundry/gpt-5.6-sol"]')"
check "a tier may name its harness and a model holding a slash" \
  "claude:opus opencode:foundry/gpt-5.6-sol" "$(read_key FALLBACK_TIERS --home "$harnessed")"

refuses "a repeated tier refuses" \
  "more than once" --home "$(home_with repeated 'harness = "claude"
[fallback]
tiers = ["fable", "opus", "fable"]')"

refuses "fallback that is not a table refuses" \
  "fallback must be a table" --home "$(home_with scalar 'harness = "claude"
fallback = "on"')"

exit "$fail"
