#!/usr/bin/env bash
# Declare foreman, and say what to run next.
#
#     install.sh --harness codex \
#                --model-tick M --model-plan M --model-build M --model-review M
#
# This is the first command after the clone at ~/.foreman/install, and it writes
# <home>/foreman.toml and nothing else. The boards, the skill links and the
# service stay separate steps: an operator adding a board to a working machine
# must be able to stop after any of them.
#
# THE HOME IS NOT ASKED FOR EITHER: identity comes from the path, so
# bin/installation.py derives the home from where this clone sits, and a second
# derivation here would be a copy that drifts from it.
set -euo pipefail

die() { printf 'install: %s\n' "$*" >&2; exit 1; }

root="$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")"
installation_py="$root/bin/installation.py"

# Passed through, never interpreted. installation.py refuses a missing
# --harness, an unknown one, and a codex or opencode home with a model unset;
# repeating that here would be a second copy of the rule. This loop is for the
# UNKNOWN flag, refused here rather than in the name of a command the operator
# did not run.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness|--model-tick|--model-plan|--model-build|--model-review)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      args+=("$1" "$2"); shift 2 ;;
    *) die "unknown argument: $1 (expected --harness or --model-<stage>)" ;;
  esac
done

"$installation_py" --write ${args[@]+"${args[@]}"}

# Read the home back rather than printing the flag: it is installation.py's to
# derive, and the command below is worse than useless if it names another home.
#
# bin/load-pairs.sh is the shared reader; its comment carries the bash 3.2
# temp-file rule that shapes it.
. "$root/bin/load-pairs.sh" || die "cannot read $root/bin/load-pairs.sh"

# What this clone just declared, never what the operator's shell says: the
# reader lets the environment win, so a stray INSTALLATION would make the line
# below describe a home nobody wrote. FOREMAN_HOME is left alone --
# installation.py reads it itself to pick the home it answers for, and clearing
# it here would read a different one than --write wrote.
unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT
_foreman_load_pairs "foreman's declaration" "$installation_py" \
  || die "installation.py cannot read what it just wrote"

printf 'foreman declared in %s/foreman.toml\n' "$FOREMAN_HOME"

printf '\nnext:\n'
printf '  %s/bin/install-skills.sh\n  %s/bin/boardctl add <board> --repo <path>\n' "$root" "$root"
