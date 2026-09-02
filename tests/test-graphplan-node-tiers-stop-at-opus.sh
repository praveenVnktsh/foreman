#!/usr/bin/env bash
# `skills/graphplan/SKILL.md` caps a node's model tier at opus, and never
# offers fable as one.
#
# The skill text IS the mechanism here. Nothing parses a node label, so the tier
# a build agent runs at is whatever the plan wrote down, and the only thing that
# constrains what a plan writes down is this file. An earlier attempt rewrote it
# to make fable the default node tier and deleted sonnet and haiku (closed,
# unmerged): every node would then have executed on the tier that is supposed to
# draw the plan, while the plan itself was still drawn at opus.
#
# Asserted at the level the rule lives at, which is prose, for the same reason
# tests/test-brief-uses-the-contract.sh asserts on a rendered prompt.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo_root/skills/graphplan/SKILL.md"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

[[ -r "$skill" ]] || { printf 'FAIL %s is not readable\n' "$skill"; exit 1; }

tiers="$(sed -n '/^### Model tiers$/,/^### /p' "$skill")"
[[ -n "$tiers" ]] || { printf 'FAIL %s has no "### Model tiers" section\n' "$skill"; exit 1; }

if grep -q 'opus. is the ceiling' <<<"$tiers"; then
  ok "the tier section names opus as the ceiling"
else
  bad "the tier section never says opus is the ceiling"
fi

for tier in opus sonnet haiku; do
  if grep -qE "^- \`$tier\`" <<<"$tiers"; then
    ok "\`$tier\` is offered as a node tier"
  else
    bad "\`$tier\` is no longer offered as a node tier"
  fi
done

# A bullet in the tier list is how this file offers a tier. fable must never be
# one, however the surrounding prose reads.
if grep -qE '^- `fable`' <<<"$tiers"; then
  bad "\`fable\` is offered as a node tier"
else
  ok "\`fable\` is not offered as a node tier"
fi

if grep -q '`fable` is never a node tier' <<<"$tiers"; then
  ok "the tier section says plainly that fable is never a node tier"
else
  bad "the tier section never says fable is not a node tier"
fi

# The worked example is what a plan copies, so a tier it demonstrates is a tier
# in practice regardless of what the list above says.
example="$(grep -n '<i>' "$skill" || true)"
if grep -q 'fable' <<<"$example"; then
  bad "the example node label demonstrates a fable tier: $example"
else
  ok "the example node label demonstrates no fable tier"
fi

# The other half of the same rule: fable is what draws the plan.
if grep -q 'The plan is drawn by a `fable` agent' "$skill"; then
  ok "the skill states the plan is drawn by a fable agent"
else
  bad "the skill never says which model draws the plan"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: graphplan node tiers stop at opus and exclude fable\n'
exit "$fail"
