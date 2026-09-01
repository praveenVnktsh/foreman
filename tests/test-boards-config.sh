#!/usr/bin/env bash
# boards.toml declares every board on this machine, and it is DATA. It is
# parsed, never sourced, for the reason bin/contract.py gives: boards share a
# user and a home, so a config that can run code runs beside every board's
# Linear credential.
#
# The other half of what this pins: a board is ONE declared fact, its local
# repository path. Anything the loader cannot make sense of refuses instead of
# defaulting, because a boards.toml that declares less than its author thought
# sends a tick agent to the wrong repository with exit code 0.
#
# FOREMAN_HOME points at a temp directory throughout. Nothing here may read or
# write the real ~/.foreman.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

export FOREMAN_HOME="$work/home"
mkdir -p "$FOREMAN_HOME" "$work/repo_alpha" "$work/repo_beta" "$work/fakehome/repo"

check() { # name expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

# The wire format is NUL-separated KEY, VALUE pairs. Decoding it here rather
# than eyeballing the bytes is what makes an added-or-reordered key visible.
decode() { # key -- reads a boards.py record on stdin
  python3 -c '
import sys
v = sys.stdin.buffer.read().split(b"\0")
d = dict(zip(v[::2], v[1::2]))
sys.stdout.write(d.get(sys.argv[1].encode(), b"<missing>").decode())
' "$1"
}

read_key() { # key, args...
  local key="$1"; shift
  "$root/bin/boards.py" "$@" | decode "$key"
}

field_count() { # args...
  "$root/bin/boards.py" "$@" | python3 -c '
import sys
print(len(sys.stdin.buffer.read().split(b"\0")) - 1)
'
}

refuses() { # claim, needle, args...
  local claim="$1" needle="$2" err; shift 2
  if err="$("$root/bin/boards.py" "$@" 2>&1 >/dev/null)"; then
    printf 'FAIL %s -- it loaded instead\n' "$claim"; fail=1; return 0
  fi
  case "$err" in
    *"$needle"*) printf 'ok   %s\n' "$claim" ;;
    *) printf 'FAIL %s: error did not name %s: %s\n' "$claim" "$needle" "$err"; fail=1 ;;
  esac
}

cat >"$FOREMAN_HOME/boards.toml" <<TOML
[boards.beta]
repo = "$work/repo_beta"
key = "$work/other.key"

[boards.alpha]
repo = "$work/repo_alpha"
TOML

check "--list names every declared board, one per NUL field" \
  "$(printf 'alpha\nbeta')" "$("$root/bin/boards.py" --list | tr '\0' '\n')"

check "a board's repo is absolute" "$work/repo_alpha" "$(read_key REPO alpha)"
check "a board with no key of its own falls back to the shared credential" \
  "$FOREMAN_HOME/linear.key" "$(read_key KEY_FILE alpha)"
check "a board in another workspace uses the key it declares" \
  "$work/other.key" "$(read_key KEY_FILE beta)"

# Consumers count fields to detect a failed load, so both keys are emitted for
# every board -- never omitted, whatever the board did or did not declare.
check "every key is emitted for a board that declares only a repo" "4" "$(field_count alpha)"
check "every key is emitted for a board that declares both" "4" "$(field_count beta)"

# ~ belongs to the operator writing the file by hand. Expanding it here is
# what lets one boards.toml stay portable between machines with different
# home directories.
cat >"$work/tilde.toml" <<'TOML'
[boards.alpha]
repo = "~/repo"
key = "~/other.key"
TOML
check "repo expands ~ against HOME" "$work/fakehome/repo" \
  "$(env HOME="$work/fakehome" "$root/bin/boards.py" --file "$work/tilde.toml" alpha | decode REPO)"
check "key expands ~ against HOME" "$work/fakehome/other.key" \
  "$(env HOME="$work/fakehome" "$root/bin/boards.py" --file "$work/tilde.toml" alpha | decode KEY_FILE)"

# --file has to win over $FOREMAN_HOME/boards.toml, or a test that thinks it
# is reading a fixture is reading the machine's real declarations.
cat >"$work/elsewhere.toml" <<TOML
[boards.gamma]
repo = "$work/repo_beta"
TOML
check "--file reads the named file instead of \$FOREMAN_HOME/boards.toml" \
  "gamma" "$("$root/bin/boards.py" --file "$work/elsewhere.toml" --list | tr '\0' '\n')"

# What a fresh installation holds before the first board is added. Refusing
# here would make an empty machine indistinguishable from a broken one.
: >"$work/empty.toml"
check "a boards.toml declaring nothing lists nothing" \
  "" "$("$root/bin/boards.py" --file "$work/empty.toml" --list | tr '\0' '\n')"
refuses "asking an empty boards.toml for a board still refuses by name" \
  "alpha" --file "$work/empty.toml" alpha

refuses "a missing boards.toml is refused, naming the path it looked for" \
  "$work/absent.toml" --file "$work/absent.toml" --list

printf 'this is not toml =\n' >"$work/broken.toml"
refuses "a file that is not valid TOML is refused" \
  "not valid TOML" --file "$work/broken.toml" --list

# Boards declared under a mistyped top-level table vanish. Read as "no boards
# declared", the tick walks zero repositories and reports a quiet, successful
# nothing -- so the table itself is refused, named.
cat >"$work/unknowntable.toml" <<TOML
[instances.alpha]
repo = "$work/repo_alpha"
TOML
refuses "an unknown top-level table is refused, naming it" \
  "instances" --file "$work/unknowntable.toml" --list

cat >"$work/unknownkey.toml" <<TOML
[boards.alpha]
repo = "$work/repo_alpha"
team = "the-team"
TOML
refuses "an unknown key inside a board is refused, naming it" \
  "team" --file "$work/unknownkey.toml" --list

cat >"$work/norepo.toml" <<TOML
[boards.alpha]
key = "$work/other.key"
TOML
refuses "a board that declares no repo is refused, naming the board" \
  "alpha" --file "$work/norepo.toml" --list

cat >"$work/emptyrepo.toml" <<'TOML'
[boards.alpha]
repo = "   "
TOML
refuses "an empty repo is refused rather than read as no repository" \
  "alpha" --file "$work/emptyrepo.toml" --list

cat >"$work/repolist.toml" <<'TOML'
[boards.alpha]
repo = ["a", "b"]
TOML
refuses "a repo that is not a string is refused" \
  "must be a string" --file "$work/repolist.toml" --list

cat >"$work/gone.toml" <<TOML
[boards.alpha]
repo = "$work/no_such_repo"
TOML
refuses "a repo that is not a directory is refused, naming the path" \
  "$work/no_such_repo" --file "$work/gone.toml" --list

# A relative path resolves against the caller's working directory, which
# differs between a tick agent, a sweep and an operator's shell. One
# boards.toml would then name three different repositories.
cat >"$work/relative.toml" <<'TOML'
[boards.alpha]
repo = "repo_alpha"
TOML
refuses "a relative repo is refused rather than resolved against the cwd" \
  "absolute" --file "$work/relative.toml" --list

# skills/board/config.sh's constraint, restated here because this file is now
# where the name is first read: worktree paths join the board name and the
# ticket with a hyphen, so a board named alpha-x makes "foreman-alpha-x-PRA-1"
# match alpha's own "foreman-alpha-*" sweep glob.
cat >"$work/hyphen.toml" <<TOML
[boards.alpha-x]
repo = "$work/repo_alpha"
TOML
refuses "a board name outside [A-Za-z0-9_] is refused, naming it" \
  "alpha-x" --file "$work/hyphen.toml" --list

cat >"$work/notatable.toml" <<TOML
[boards]
alpha = "$work/repo_alpha"
TOML
refuses "a board that is not a table is refused" \
  "must be a table" --file "$work/notatable.toml" --list

# `key = ""` reads as "this board has its own credential" and would then
# silently fall back to the shared one -- the workspace mix-up the optional
# key exists to prevent.
cat >"$work/emptykey.toml" <<TOML
[boards.alpha]
repo = "$work/repo_alpha"
key = ""
TOML
refuses "an empty key is refused rather than falling back to the default" \
  "alpha" --file "$work/emptykey.toml" --list

# An embedded NUL desynchronizes the NUL-separated wire format, and valid TOML
# can produce one with a \u0000 escape. It cannot survive as a shell value
# either, so the file is refused rather than a stream emitted that a consumer
# would misparse.
cat >"$work/nul.toml" <<TOML
[boards.alpha]
repo = "$work/repo_alpha"
key = "\u0000$work/other.key"
TOML
refuses "a value containing an embedded NUL byte is refused" \
  "NUL" --file "$work/nul.toml" --list

cat >"$work/onlyalpha.toml" <<TOML
[boards.alpha]
repo = "$work/repo_alpha"
TOML
refuses "asking for a board that is not declared is refused, naming it" \
  "delta" --file "$work/onlyalpha.toml" delta

# The declarations are DATA. Shell in a value is a string, and reading the
# file runs none of it.
cat >"$work/evil.toml" <<'TOML'
[boards.alpha]
repo = "$(touch /tmp/foreman-boards-pwned)"
key = "`touch /tmp/foreman-boards-pwned2`"
TOML
rm -f /tmp/foreman-boards-pwned /tmp/foreman-boards-pwned2
"$root/bin/boards.py" --file "$work/evil.toml" --list >/dev/null 2>&1 || true
if [[ -e /tmp/foreman-boards-pwned || -e /tmp/foreman-boards-pwned2 ]]; then
  printf 'FAIL loading board declarations executed shell from them\n'; fail=1
  rm -f /tmp/foreman-boards-pwned /tmp/foreman-boards-pwned2
else
  printf 'ok   board declarations are inert\n'
fi

exit "$fail"
