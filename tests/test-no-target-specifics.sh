#!/usr/bin/env bash
# The prose is the product. It is also where a copied codebase keeps its old
# owner's name, and a stranger cannot evaluate an argument about a machine they
# have never seen. This fails the build on the identifiers that mean "this was
# somebody else's repository".
#
# Scoped to skills/, bin/ and tests/: LICENSE names its copyright holder and
# must; README.md and docs/ legitimately say where this came from — naming
# the source project in a README is accurate provenance, not leftover. Those
# are exempt by not being in scope.
#
# This file itself must name the banned terms to define them, so it excludes
# itself from the scan rather than being scoped out of the banned list.
#
# tests/test-brief-uses-the-contract.sh is exempted the same way, for the same
# reason: its `banned` array is a standing regression guard checking that
# brief.py's generated prompt never contains the specific strings that used to
# leak from the project this tool was extracted from. Those words are the
# check, not leftover prose describing whose infrastructure this was -- and
# unlike this file, that one cannot exclude only itself, because the words
# have to be readable at the point they are compared.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
self="$(basename -- "${BASH_SOURCE[0]}")"
banned='murmr|mango|Praveen|MURMR_|just test-all|deploy-mango|\.murmr-'
if hits="$(grep -rInE "$banned" "$root/skills" "$root/bin" "$root/tests" \
     --exclude-dir=__pycache__ --exclude="$self" \
     --exclude="test-brief-uses-the-contract.sh" 2>/dev/null)"; then
  printf 'FAIL target-specific identifiers survive generalisation:\n%s\n' "$hits"
  exit 1
fi
printf 'ok   no target-specific identifiers outside docs/\n'
