#!/usr/bin/env bash
# Claim: the graphplan skill states `fable` as the default model tier, shows it
# in its example node label, and offers no tier it does not define.
#
# Nothing else in this repository can catch a regression here. No code executes
# a graphplan plan: the tier is written into a node label by one agent, read out
# of that label by another, and passed to `agent(prompt, {model})` in a session
# this repository never sees. The file is the whole mechanism, so the file is
# what gets asserted on.
#
# The example label is checked separately from the prose because a plan-writer
# copies the example. Prose that says `fable` above an example that says `opus`
# produces opus plans, costs every node that waits on one, and fails nothing.
#
# `sonnet` and `haiku` are banned rather than merely unused. They were the two
# middle rungs of the ladder that fable replaced, and a ladder is what makes a
# default stop holding: given four names, a plan-writer picks one per node and
# prices the graph again instead of planning it.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$root/skills/graphplan/SKILL.md"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

if [[ ! -f "$skill" ]]; then
  bad "skills/graphplan/SKILL.md does not exist"
  exit "$fail"
fi

if grep -q '`fable`' "$skill" && grep -qi 'every node is `fable`' "$skill"; then
  ok "the skill states that every node is fable unless its label says why not"
else
  bad "the skill never states fable as the default tier"
fi

# The model half of every `<i>model · effort</i>` annotation the skill shows.
tiers="$(grep -oE '<i>[a-z]+ ·' "$skill" | sed 's/<i>//; s/ ·//' | sort -u)"
if [[ -z "$tiers" ]]; then
  bad "the skill shows no node label with a model tier, so nothing teaches the format"
else
  for tier in $tiers; do
    case "$tier" in
      fable|opus) ok "example node label names a defined tier: $tier" ;;
      *) bad "example node label names '$tier', which the Model tiers section does not define" ;;
    esac
  done
  printf '%s\n' "$tiers" | grep -qx fable \
    && ok "an example node label carries the default, so copying it gets fable" \
    || bad "no example node label carries fable -- a plan-writer copies the example, not the prose"
fi

for gone in sonnet haiku; do
  if grep -qn "$gone" "$skill"; then
    bad "the skill still offers '$gone' as a tier; the ladder is what stopped the default holding"
  else
    ok "the skill offers no '$gone' rung beside the default"
  fi
done

exit "$fail"
