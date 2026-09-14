#!/usr/bin/env bash
# Claim: "Default uniqueness" in
# docs/specs/2026-09-14-installations-per-harness-design.md. Two siblings that
# both say `default = true` would dispatch one unlabelled card twice, against
# one machine's HOST_MAX_CONCURRENT, with neither tick able to see the other
# doing it -- so bin/installation.py refuses before either one starts, naming
# both, and skills/board/config.sh (which every tick sources first) exits
# before it ever reaches REPO.
#
# Exactly one, not at most one: a root with two installations and NO default
# refuses the same way, because an unlabelled card would belong to nobody and
# skills/board/queue.py would drop every one of them as FOREIGN with exit 0 --
# a board that reports healthy and dispatches nothing. A LONE installation is
# the default whatever its own file says, which is the other half of the same
# rule: the common machine runs one installation, and it owns every card.
#
# This file also pins the loader's other refusals named alongside default
# uniqueness in the same design section: a legacy home with no
# installation.toml, a non-Claude harness with a model left unset, and an
# installation directory named with a hyphen.
#
# FOREMAN_HOME points at a temp directory throughout. Nothing here may read or
# write the real ~/.foreman.
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

# The wire format is NUL-separated KEY, VALUE pairs, same as bin/boards.py's --
# decoding it here is what makes an added, dropped or reordered key visible,
# instead of a test that eyeballs raw bytes.
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

toml() { # path, harness, default, models-block(may be empty)
  cat >"$1" <<TOML
harness = "$2"
default = $3
$4
TOML
}

# --- two siblings both claiming default = true refuses, naming both --------
two="$work/two"; mkdir -p "$two/alpha" "$two/beta"
toml "$two/alpha/installation.toml" claude true ""
toml "$two/beta/installation.toml"  claude true ""
refuses "reading a sibling with a rival default names both" \
  "alpha, beta" --home "$two/alpha"
refuses "reading either sibling names the same pair" \
  "alpha, beta" --home "$two/beta"

# --- config.sh, sourced under FOREMAN_INSTANCE, exits before REPO ----------
# Every tick sources config.sh first, and config.sh's own first load is this
# installation's declaration -- before boards.toml, before ids.env, before
# REPO. Two rival defaults must stop it there: a board.toml this fixture never
# writes is proof nothing downstream of the refusal ran.
status=0
out="$(env FOREMAN_HOME="$two/alpha" FOREMAN_INSTANCE=demo bash -c \
  ". '$root/skills/board/config.sh' >/dev/null 2>/dev/null; printf '%s' \"\$REPO\"" \
  2>/dev/null)" || status=$?
if [[ $status -eq 0 ]]; then
  bad "config.sh must exit nonzero under a rival default"
else
  ok "config.sh exits nonzero under a rival default"
fi
check "config.sh never reaches REPO under a rival default" "" "$out"

# --- two siblings and NO default refuses on every read, naming both ---------
# An unlabelled card belongs to the default. With no default, skills/board/
# queue.py drops every one of them as FOREIGN and exits 0, so both ticks report
# a healthy empty board while the cards sit in Todo. A silent stop is worse
# than a refusal.
none="$work/none"; mkdir -p "$none/alpha" "$none/beta"
toml "$none/alpha/installation.toml" claude false ""
toml "$none/beta/installation.toml"  claude false ""
refuses "two siblings and no default refuses, naming both" \
  "alpha, beta" --home "$none/alpha"
refuses "the same refusal names the fix, an installation.toml to edit" \
  "installation.toml" --home "$none/beta"
refuses "--siblings refuses too, so no caller can route around the read" \
  "none claims default = true" --home "$none/alpha" --siblings

# --- a LONE installation is the default whatever its file says --------------
# The documented first install passes no --default, so install.sh writes
# `default = false`. Read literally, IS_DEFAULT was empty, queue.py dropped
# every unlabelled card as FOREIGN, and a board installed exactly as the README
# says never dispatched. One installation on the machine owns every card:
# there is no other installation for an unlabelled card to belong to.
lone="$work/lone"; mkdir -p "$lone/solo"
toml "$lone/solo/installation.toml" claude false ""
check "a lone installation reports IS_DEFAULT even though its file says false" \
  "1" "$(read_key IS_DEFAULT --home "$lone/solo")"
check "a lone installation still names itself" \
  "solo" "$(read_key INSTALLATION --home "$lone/solo")"

# A sibling appearing beside it takes that away again: two installations, and
# the file's own `default = false` is now the whole answer, so the pair refuses
# until the operator says which one owns the unlabelled cards.
mkdir -p "$lone/second"
toml "$lone/second/installation.toml" codex false \
  $'[models]\ntick = "m"\nplan = "m"\nbuild = "m"\nreview = "m"'
# Both are named, so the operator knows which files to open.
refuses "adding a sibling beside it refuses until one of them claims default" \
  "second, solo" --home "$lone/solo"

# --- one default plus one non-default loads, IS_DEFAULT set on the right one
one="$work/one"; mkdir -p "$one/gamma" "$one/delta"
toml "$one/gamma/installation.toml" claude true  ""
toml "$one/delta/installation.toml" claude false ""
check "the default sibling reports IS_DEFAULT" \
  "1" "$(read_key IS_DEFAULT --home "$one/gamma")"
check "the non-default sibling reports IS_DEFAULT empty" \
  "" "$(read_key IS_DEFAULT --home "$one/delta")"
check "the non-default sibling still names its own installation" \
  "delta" "$(read_key INSTALLATION --home "$one/delta")"

# --- a legacy home, with no installation.toml, is a lone Claude installation
legacy="$work/legacy"; mkdir -p "$legacy"
check "a legacy home reports the installation claude" \
  "claude" "$(read_key INSTALLATION --home "$legacy")"
check "a legacy home reports itself the default" \
  "1" "$(read_key IS_DEFAULT --home "$legacy")"
check "a legacy home's root is itself, having no siblings" \
  "$legacy" "$(read_key FOREMAN_ROOT --home "$legacy")"

# --- a codex installation with a model left unset refuses, naming the key --
broken="$work/broken/codexinst"; mkdir -p "$broken"
toml "$broken/installation.toml" codex false \
  $'[models]\ntick = "gpt-5-codex"\nplan = "gpt-5-codex"\nbuild = "gpt-5-codex"'
refuses "a codex installation missing the review model names it" \
  "review" --home "$broken"

# --- an installation directory named with a hyphen refuses -----------------
hyphen="$work/hyphenated/my-installation"; mkdir -p "$hyphen"
toml "$hyphen/installation.toml" claude false ""
refuses "a hyphenated installation name refuses" \
  "my-installation" --home "$hyphen"

exit "$fail"
