#!/usr/bin/env bash
# Parse every tracked shell and Python source in the repository. Syntax only.
#
#     bin/check-syntax.sh
#
# It takes no arguments, and that is the whole design. Every previous version of
# this check named what to cover and was under-covering by the time anyone
# looked:
#
#   1. A hand-listed file set, which omitted the regression test written for a
#      real production outage, install-user-units.sh, and all of scripts/.
#   2. A glob, which would have passed had it matched nothing at all.
#   3. `find src scripts -exec bash -n {} +`, which hands a batch to one `bash`
#      -- and `bash -n a.sh b.sh` parses `a.sh` and takes `b.sh` as a positional
#      argument. One script of thirteen was parsed, and which one depended on
#      directory traversal order.
#   4. `find src scripts .claude`, which is the same list one directory wider:
#      it silently omitted `setup.sh` and the target's own start script at the
#      repository root -- and every production deploy runs `setup.sh` *after*
#      rsync has already replaced the deploy host's tree -- and, matching on
#      extension, it omitted `deploy/git-hooks/pre-commit` and `pre-push`,
#      which have no suffix.
#
# So the file set is `git ls-files`. Coverage is a property of the repository
# rather than a list someone has to remember to widen, because remembering is
# the step that has failed four times. A new script is covered by being
# committed.
#
# `.claude/` matters most and is why this exists: the board dispatches every
# build, gates every merge and decides what reaches production, and it was the
# only tracked code with no check on it at all. Syntax only, deliberately --
# `.claude/skills/board/reconcile.py` and `preflight.py` shell out to config.sh
# at import time, so importing them here would run board shell against a machine
# that has no board state.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH; cannot parse the Python sources" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# py_compile writes a .pyc beside its source, which would drop build output into
# the very tree being checked.
pycache_dir="$(mktemp -d)"
trap 'rm -rf "$pycache_dir"' EXIT
export PYTHONPYCACHEPREFIX="$pycache_dir"

# Extension first, then the shebang of anything git records as executable.
# Sniffing is limited to executables so the repository's binary assets are not
# read looking for a `#!`; the cost is that a non-executable extensionless
# script is not parsed, which is fine because nothing can run one either.
kind_of() {
  local path="$1" executable="$2" first_line=""

  case "$path" in
    *.py) echo python; return ;;
    *.sh | *.bash) echo shell; return ;;
  esac

  [[ "$executable" == yes ]] || return 0
  IFS= read -r first_line < "$path" 2>/dev/null || return 0

  if [[ "$first_line" =~ ^#!.*[/[:space:]]python[0-9.]*([[:space:]]|$) ]]; then
    echo python
  elif [[ "$first_line" =~ ^#!.*[/[:space:]](bash|sh)([[:space:]]|$) ]]; then
    echo shell
  fi
}

# BASH 4 CONSTRUCTS, which `bash -n` cannot catch. CI's bash is 5, where they
# parse; macOS ships 3.2, where they fail at run time. AGENTS.md sets the floor
# at 3.2, so a board on a Mac dies on a line CI called fine. Matched on the
# source with comments stripped, one pattern per construct:
#
#   mapfile / readarray          no builtin in 3.2
#   declare|local|typeset -A     no associative arrays in 3.2
#   ${var,,} ${var^^} ...        no case modification in 3.2
#   |&                           no stderr pipe shorthand in 3.2
#
# The patterns are spelled so this file does not match its own source.
bash4_pattern='(^|[^A-Za-z0-9_-])(map''file|read''array)([^A-Za-z0-9_-]|$)'
bash4_pattern+='|(declare|local|typeset)[[:space:]]+-[A-Za-z]*A'
bash4_pattern+='|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)'
bash4_pattern+='|(^|[^|])[|]&([[:space:]]|$)'

# bash4_lines <path> -- each line of <path> that uses a bash 4 construct, as
# `<line>:<text>`, comments stripped first so prose about them is allowed.
bash4_lines() {
  sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -nE "$bash4_pattern" || true
}

status=0
checked=0
unclassified_executables=()

while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="${entry#*$'\t'}"

  if [[ ! -f "$path" ]]; then
    # Tracked in the index but gone from disk. In CI this cannot happen; locally
    # it means a file was removed without `git rm`, and parsing what is on disk
    # would quietly report on a tree nobody has.
    echo "FAIL: $path is tracked but missing from the working tree" >&2
    status=1
    continue
  fi

  executable=no
  [[ "$mode" == "100755" ]] && executable=yes

  kind="$(kind_of "$path" "$executable")"
  if [[ -z "$kind" ]]; then
    # An executable this script cannot classify is not covered, and silent
    # non-coverage is the failure being engineered out. Fail loudly instead:
    # teaching kind_of() a new shebang is one line.
    [[ "$executable" == yes ]] && unclassified_executables+=("$path")
    continue
  fi

  echo "    $path"
  case "$kind" in
    shell) checker=(bash -n) ;;
    python) checker=(python3 -m py_compile) ;;
  esac

  # One file per invocation. Both checkers are wrong about batches: `bash -n`
  # parses only the first, and `py_compile` stops at the first failure, so a
  # batch reports one broken file and hides every one after it.
  if ! "${checker[@]}" "$path"; then
    echo "FAIL: $path does not parse" >&2
    status=1
  fi

  if [[ "$kind" == shell ]]; then
    bash4="$(bash4_lines "$path")"
    if [[ -n "$bash4" ]]; then
      echo "FAIL: $path uses bash 4 constructs; this repository runs on bash 3.2 (see AGENTS.md):" >&2
      printf '%s\n' "$bash4" | sed "s#^#  $path:#" >&2
      status=1
    fi
  fi

  checked=$(( checked + 1 ))
done < <(git ls-files -s -z)

if [[ ${#unclassified_executables[@]} -gt 0 ]]; then
  echo "FAIL: tracked executables this check cannot classify:" >&2
  printf '  %s\n' "${unclassified_executables[@]}" >&2
  echo "Give kind_of() its shebang, or drop the executable bit." >&2
  status=1
fi

# A matcher that matches nothing passes loudest of all -- which is how versions
# 1 through 4 above kept reading green. There is no root list left to go stale,
# so the only way to get here with nothing is an empty index or a checkout that
# is not the repository.
if [[ $checked -eq 0 ]]; then
  echo "FAIL: no tracked shell or Python sources found -- is this the repo?" >&2
  exit 1
fi

if [[ $status -ne 0 ]]; then
  echo "FAIL: see above" >&2
  exit 1
fi

echo "PASS: $checked tracked shell and Python sources parse"
