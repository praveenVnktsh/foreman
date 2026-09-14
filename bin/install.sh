#!/usr/bin/env bash
# Declare this clone as one installation, and say what to run next.
#
#     install.sh --harness codex [--default] \
#                --model-tick M --model-plan M --model-build M --model-review M
#
# One machine runs several installations, each a clone of its own under
# ~/.foreman/<name>/install. This is the first command after that clone, and it
# writes <home>/installation.toml and nothing else. The boards, the skill links
# and the service stay separate steps: an operator adding a second harness to a
# working machine must be able to stop after any of them.
#
# WHICH INSTALLATION THIS IS is neither asked nor passed: identity comes from
# the path, so bin/installation.py derives the home from where this clone sits,
# and a second derivation here would be a copy that drifts from it.
set -euo pipefail

die() { printf 'install: %s\n' "$*" >&2; exit 1; }

root="$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")"
installation_py="$root/bin/installation.py"

# Passed through, never interpreted. installation.py refuses a missing
# --harness, an unknown one, and a codex or opencode installation with a model
# unset; repeating that here would be a second copy of the rule. This loop is
# for the UNKNOWN flag, refused here rather than in the name of a command the
# operator did not run.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness|--model-tick|--model-plan|--model-build|--model-review)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      args+=("$1" "$2"); shift 2 ;;
    --default) args+=("$1"); shift ;;
    *) die "unknown argument: $1 (expected --harness, --default or --model-<stage>)" ;;
  esac
done

"$installation_py" --write ${args[@]+"${args[@]}"}

# Read the home and the name back rather than printing the flags: both are
# installation.py's to derive, and the two commands below are worse than
# useless if they name an installation other than the one just declared.
#
# bin/load-pairs.sh is the shared reader; its comment carries the bash 3.2
# temp-file rule that shapes it.
. "$root/bin/load-pairs.sh" || die "cannot read $root/bin/load-pairs.sh"

# What this clone just declared, never what the operator's shell says: the
# reader lets the environment win, so a stray INSTALLATION or IS_DEFAULT would
# make the lines below describe an installation nobody wrote. FOREMAN_HOME is
# left alone -- installation.py reads it itself to pick the home it answers
# for, and clearing it here would read a different one than --write wrote.
unset INSTALLATION IS_DEFAULT HARNESS FOREMAN_ROOT
_foreman_load_pairs "this installation's declaration" "$installation_py" \
  || die "installation.py cannot read what it just wrote"

printf 'installation %s declared in %s/installation.toml\n' "$INSTALLATION" "$FOREMAN_HOME"

# WHICH CARDS THIS INSTALLATION OWNS, said out loud, because the file does not
# always say it: a lone installation is the default whatever `default` reads,
# and bin/installation.py's record() explains why. An operator who installs
# once and never passes --default would otherwise have no way to tell whether
# an unlabelled card is anyone's.
if [[ -n "$IS_DEFAULT" ]]; then
  printf 'it is this machine'"'"'s default: a card with no foreman:<name> label is its own.\n'
else
  printf 'it is NOT this machine'"'"'s default: only cards labelled foreman:%s are its own.\n' "$INSTALLATION"
fi

printf '\nnext:\n'
printf '  %s/bin/install-skills.sh\n  %s/bin/boardctl add <board> --repo <path>\n' "$root" "$root"
