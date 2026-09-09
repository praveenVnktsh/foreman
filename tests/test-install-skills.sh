#!/usr/bin/env bash
# Claim: install-skills.sh makes this install's skills resolvable, records what
# it installed outside the source tree, and refuses to replace a skill it did
# not put there.
#
# The refusal is the important half. A skill of the same name at that path is
# very likely another project's live loop. On 2026-09-01 a tick started by this
# repository resolved `/board` to a different project's board skill sitting at
# that path and ran its loop against a live board, as a second dispatcher. The
# opposite mistake -- silently overwriting that skill -- stops the other project
# dead with no message at all.
#
# The manifest is the other half. Every link at $DEST points INTO the source
# tree, so anything written "next to the installed skill" is written through a
# symlink and lands in the install clone. On 2026-09-08 that put a stray
# .installed.json inside the clone whose only job is to be a clean pin, and the
# manifest it left there listed a file from a different project's board skill.
#
# CLAUDE_SKILLS_DIR and FOREMAN_HOME point every case at a temporary directory.
# The real ~/.claude/skills and ~/.foreman are never read or written here.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

dest="$work/skills"
home="$work/foreman-home"
run() {
  env CLAUDE_SKILLS_DIR="$dest" FOREMAN_HOME="$home" \
    bash "$root/bin/install-skills.sh" "$@" 2>&1
}

# The script derives its source from its own location, so every case here links
# the real skills/ of this repository. Nothing may appear in it.
srclist() { (cd "$root/skills" && find . | sort); }

# --- a dry run changes nothing
out="$(run --dry-run)"
if [[ -e "$dest/board" ]]; then bad "--dry-run created something"; else ok "--dry-run changes nothing"; fi
case "$out" in *"would link"*) ok "--dry-run says what it would do" ;; *) bad "$out" ;; esac

# --- install links every skill
before="$(srclist)"
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

# --- the manifest exists, and it is with this installation's state
if [[ -f "$home/installed-skills" ]]; then
  ok "the install records what it installed, in its own state directory"
else
  bad "no manifest at $home/installed-skills after an install"
fi
grep -qx board "$home/installed-skills" 2>/dev/null \
  && ok "the manifest names the skill that was linked" \
  || bad "the manifest does not name 'board'"

# --- and NOT inside the source tree the links point at.
#
# This is the 2026-09-08 bug. $dest/board is a symlink into $root/skills/board,
# so a manifest written to the installed skill's path is written THROUGH that
# link and appears inside the install clone -- untracked, in the repository
# whose only job is to be a clean pin, and impossible to explain from its own
# history. The link being real is asserted first: with a plain directory at
# $dest/board the rest of this case would pass for the wrong reason.
if [[ -L "$dest/board" && -d "$root/skills/board" ]]; then
  ok "the installed skill really is a symlink into the source tree"
else
  bad "$dest/board is not a link into $root/skills; this case proves nothing"
fi
after="$(srclist)"
if [[ "$before" == "$after" ]]; then
  ok "installing adds no file to the source tree the links point at"
else
  bad "the install wrote into $root/skills: $(diff <(echo "$before") <(echo "$after") | tr '\n' ' ')"
fi

# --- running again is not an error
out="$(run)"
if [[ $? -eq 0 ]] && ! grep -q COLLISION <<<"$out"; then
  ok "re-running is idempotent, not a collision with itself"
else
  bad "re-run reported a collision with its own links: $out"
fi

# --- a skill this install used to ship is removed, not left dangling
#
# The link outlives the skill: every loop in the script walks the source tree,
# so a name dropped from a later pin is never visited again and keeps resolving
# -- to a path the pin deleted, or to one a future pin refills with something
# else. The manifest is the only record that this install put it there.
ln -s "$root/skills/retired-skill" "$dest/retired-skill"
printf 'board\nretired-skill\n' > "$home/installed-skills"
run >/dev/null
if [[ -L "$dest/retired-skill" ]]; then
  bad "left behind a link to a skill this install no longer ships"
else
  ok "a skill dropped since the last install has its link removed"
fi
grep -qx retired-skill "$home/installed-skills" \
  && bad "the manifest still claims a skill that is no longer installed" \
  || ok "the manifest stops naming what is no longer installed"

# --- but a manifest entry that is NOT ours is never acted on
#
# A manifest that names a file it did not install is exactly how the 2026-09-08
# clone acquired a foreign question.py nobody could explain. The manifest is a
# record, never an authority: ownership is decided by reading the link.
mkdir -p "$dest/someone-else"
printf 'name: someone-else\n' > "$dest/someone-else/SKILL.md"
printf 'board\nsomeone-else\n' > "$home/installed-skills"
run >/dev/null
[[ -f "$dest/someone-else/SKILL.md" ]] \
  && ok "a manifest entry this install does not own is left alone" \
  || bad "the manifest was trusted over the link and deleted a foreign skill"
rm -rf "$dest/someone-else"

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
[[ -e "$home/installed-skills" ]] \
  && bad "uninstall left a manifest claiming links it has removed" \
  || ok "uninstall drops the manifest with the links it describes"

# --- and none of it ever touched the source tree
stray="$(cd "$root/skills" && find . -name '*installed*' -o -name '.installed*')"
[[ -z "$stray" ]] \
  && ok "no installer state was written into the source tree at any point" \
  || bad "installer state in the source tree: $stray"

exit "$fail"
