#!/usr/bin/env bash
# Claim: every skill declares a name equal to its directory, a non-empty
# description, and every skill named in prompt-generating code exists.
#
# The name is not decoration. `skills/board/brief.py` writes "Use the
# `adversarial-reviewer` skill" into a prompt handed to a live agent, as a bare
# string. Rename the directory without the frontmatter, or the frontmatter
# without the directory, and that instruction points at nothing -- the reviewer
# starts, finds no such skill, reviews the diff with whatever it happened to
# believe, and reports findings in a shape the board may not parse. Nothing
# fails; the review just quietly stops being the thing it was designed to be.
#
# The description is the trigger. A skill with an empty one is never loaded.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

for skill in "$root"/skills/*/SKILL.md; do
  [[ -f "$skill" ]] || continue
  dir="$(basename "$(dirname "$skill")")"

  if ! head -1 "$skill" | grep -q '^---$'; then
    bad "$dir: does not open with frontmatter"
    continue
  fi
  declared="$(sed -n '1,20p' "$skill" | sed -n 's/^name: *//p' | head -1)"
  [[ "$declared" == "$dir" ]] \
    && ok "$dir declares its own directory name" \
    || bad "$dir declares name '${declared:-<none>}'"

  desc="$(sed -n '1,20p' "$skill" | sed -n 's/^description: *//p' | head -1)"
  [[ -n "${desc//[[:space:]\"]/}" ]] \
    && ok "$dir has a description" \
    || bad "$dir has no description, so it can never be triggered"
done

# Every skill named in code that builds a prompt must exist. This is the half
# that actually broke something: a string in brief.py and a directory on disk
# are only related by someone remembering.
for named in $(grep -rhoE '`[a-z][a-z0-9-]+` skill' "$root/skills/board/"*.py \
                 | sed 's/`//g; s/ skill//' | sort -u); do
  [[ -d "$root/skills/$named" ]] \
    && ok "prompt-generating code names '$named', and it exists" \
    || bad "prompt-generating code names skill '$named', which does not exist"
done

exit "$fail"
