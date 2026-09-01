#!/usr/bin/env bash
# Claim: install-skills.sh makes this install's skills resolvable, and refuses to
# replace a skill it did not put there.
#
# The refusal is the important half. A skill of the same name at that path is
# very likely another project's live loop. On 2026-09-01 a tick started by this
# repository resolved `/board` to a different project's board skill sitting at
# that path and ran its loop against a live board, as a second dispatcher. The
# opposite mistake -- silently overwriting that skill -- stops the other project
# dead with no message at all.
#
# CLAUDE_SKILLS_DIR points every case at a temporary directory. The real
# ~/.claude/skills is never read or written by this test.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

dest="$work/skills"
run() { env CLAUDE_SKILLS_DIR="$dest" bash "$root/bin/install-skills.sh" "$@" 2>&1; }

# --- a dry run changes nothing
out="$(run --dry-run)"
if [[ -e "$dest/board" ]]; then bad "--dry-run created something"; else ok "--dry-run changes nothing"; fi
case "$out" in *"would link"*) ok "--dry-run says what it would do" ;; *) bad "$out" ;; esac

# --- install links every skill
run >/dev/null
missing=""
for name in $(ls -1 "$root/skills"); do
  [[ -L "$dest/$name" ]] || missing="$missing $name"
done
[[ -z "$missing" ]] && ok "every skill is linked" || bad "not linked:$missing"

# --- and the link resolves to a real SKILL.md, which is the whole point
if [[ -f "$dest/board/SKILL.md" ]]; then
  ok "the linked skill resolves to its SKILL.md"
else
  bad "board/SKILL.md does not resolve through the link"
fi

# --- running again is not an error
out="$(run)"
if [[ $? -eq 0 ]] && ! grep -q COLLISION <<<"$out"; then
  ok "re-running is idempotent, not a collision with itself"
else
  bad "re-run reported a collision with its own links: $out"
fi

# --- a foreign skill of the same name is REFUSED, not replaced
rm -f "$dest/board"
mkdir -p "$dest/board"
printf 'name: board\nsomebody else\n' > "$dest/board/SKILL.md"
if out="$(run)"; then
  bad "replaced a foreign skill without being asked"
else
  case "$out" in
    *"refusing to replace"*) ok "refuses to replace a skill it did not install" ;;
    *) bad "refused for the wrong reason: $out" ;;
  esac
fi
grep -q "somebody else" "$dest/board/SKILL.md" \
  && ok "the foreign skill is left exactly as it was" \
  || bad "the foreign skill was modified despite the refusal"

# --- --force replaces it, keeping a backup
run --force >/dev/null
if [[ -L "$dest/board" ]]; then ok "--force replaces the foreign skill"; else bad "--force did not link"; fi
if ls "$dest"/board.replaced-* >/dev/null 2>&1; then
  ok "--force keeps the replaced skill, so the decision is recoverable"
else
  bad "--force destroyed the foreign skill with no backup"
fi

# --- uninstall removes only our own links
foreign="$dest/not-ours"; mkdir -p "$foreign"
run --uninstall >/dev/null
[[ -e "$dest/board" ]] && bad "uninstall left our link behind" || ok "uninstall removes our links"
[[ -d "$foreign" ]] && ok "uninstall leaves a skill it did not install" || bad "uninstall removed a foreign skill"

exit "$fail"
