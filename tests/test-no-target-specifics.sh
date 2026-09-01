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
# `design/build_system`, `test_design_invariants` and `ops/` are banned for
# the same reason `mango` is -- structure that identifies whose codebase this
# grew up on. `ops/` specifically: this codebase's own scripts moved to
# `bin/`, and every `ops/...` example that survived generalisation (a target's
# deploy script, its git hooks) was a leftover real path from the origin
# project's tree, reused as the running illustration instead of an invented
# one -- exactly the class of leak `agent_tmp_for()` shipped as actual code,
# not just prose (see config.sh and bin/tmp-dir.sh). A passage that needs an
# example path should invent a plainly generic one (`db/migrations/`,
# `docs/ENGINEERING.md`), not cite a real tree.
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
banned='murmr|mango|Praveen|MURMR_|just test-all|deploy-mango|\.murmr-|backend/|design/build_system|test_design_invariants|ops/'
banned_ci='whatsapp|baileys'

# STYLEGUIDE.md and AGENTS.md are in scope even though they sit at the root.
# Both instruct an agent -- STYLEGUIDE.md through board.toml's docs.required,
# AGENTS.md through whatever harness reads it -- and both state this very rule.
# A rule that does not bind the file stating it is a suggestion. README.md
# stays out for the reason given above: naming the source project there is
# accurate provenance.
extra=""
for f in "$root/STYLEGUIDE.md" "$root/AGENTS.md"; do
  [[ -f "$f" ]] && extra="$extra $f"
done

hits=""
if part="$(grep -rInE "$banned" "$root/skills" "$root/bin" "$root/tests" $extra \
     --exclude-dir=__pycache__ --exclude="$self" \
     --exclude="legacy-strings.sh" 2>/dev/null)"; then
  hits="$hits$part"$'\n'
fi
if part="$(grep -rInEi "$banned_ci" "$root/skills" "$root/bin" "$root/tests" $extra \
     --exclude-dir=__pycache__ --exclude="$self" \
     --exclude="legacy-strings.sh" 2>/dev/null)"; then
  hits="$hits$part"$'\n'
fi
if [[ -n "$hits" ]]; then
  printf 'FAIL target-specific identifiers survive generalisation:\n%s' "$hits"
  exit 1
fi
printf 'ok   no target-specific identifiers outside docs/ and README.md\n'
