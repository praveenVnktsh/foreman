#!/usr/bin/env bash
# The prose is the product. It is also where a copied codebase keeps its old
# owner's name, and a stranger cannot evaluate an argument about a machine they
# have never seen. This fails the build on the identifiers that mean "this was
# somebody else's repository".
#
# A path is an identifier too, and a token scan misses it: `backend/app/events/
# migrations/` names no person and no project, but it is a real path in the
# origin project's tree, and a search engine will resolve it to that
# repository regardless of what this one is called. `backend/`,
# `design/build_system` and `test_design_invariants` are banned for the same
# reason `mango` is -- structure that identifies whose codebase this grew up
# on. A passage that needs an example path should invent a plainly generic
# one (`db/migrations/`, `docs/ENGINEERING.md`), not cite a real tree.
#
# Scoped to skills/, bin/ and tests/: LICENSE names its copyright holder and
# must; README.md and docs/ legitimately say where this came from — naming
# the source project in a README is accurate provenance, not leftover. Those
# are exempt by not being in scope.
#
# This file itself must name the banned terms to define them, so it excludes
# itself from the scan rather than being scoped out of the banned list.
#
# tests/lib/legacy-strings.sh is exempted the same way, for the same reason:
# it holds nothing but the standing regression check tests/test-brief-uses-
# the-contract.sh runs, asserting that brief.py's generated prompt never
# contains the specific strings that used to leak from the project this tool
# was extracted from. Those words are the check, not leftover prose describing
# whose infrastructure this was -- kept in a one-line file of their own so the
# exclusion covers only them, and the 370-odd other lines of that test stay
# covered by this scan.
#
# `whatsapp` and `baileys` are banned case-insensitively, separately from the
# case-sensitive list above: they identify the origin project's messaging
# integration the way `mango` identifies its host, but unlike `mango` they
# show up capitalized in ordinary prose ("WhatsApp", "a Baileys runtime") as
# often as not. tests/lib/curl-stub.sh carried both (`WHATSAPP_STATUS`, "a
# Baileys runtime") and this scan never caught it -- it was dead code, deleted
# rather than generalised, but the class it represents can come back in a
# comment this scan does catch.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
self="$(basename -- "${BASH_SOURCE[0]}")"
banned='murmr|mango|Praveen|MURMR_|just test-all|deploy-mango|\.murmr-|backend/|design/build_system|test_design_invariants'
banned_ci='whatsapp|baileys'
hits=""
if part="$(grep -rInE "$banned" "$root/skills" "$root/bin" "$root/tests" \
     --exclude-dir=__pycache__ --exclude="$self" \
     --exclude="legacy-strings.sh" 2>/dev/null)"; then
  hits="$hits$part"$'\n'
fi
if part="$(grep -rInEi "$banned_ci" "$root/skills" "$root/bin" "$root/tests" \
     --exclude-dir=__pycache__ --exclude="$self" \
     --exclude="legacy-strings.sh" 2>/dev/null)"; then
  hits="$hits$part"$'\n'
fi
if [[ -n "$hits" ]]; then
  printf 'FAIL target-specific identifiers survive generalisation:\n%s' "$hits"
  exit 1
fi
printf 'ok   no target-specific identifiers outside docs/\n'
