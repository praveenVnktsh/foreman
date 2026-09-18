#!/usr/bin/env bash
# Claim: with FOREMAN_UPDATE_REF=origin/release, self-update follows the release
# branch, not main -- a merge to main does not deploy a pinned installation, and
# moving the release does.
#
# The failure it prevents: without a ref to pin, every merge to main reaches
# every installation on its next timer fire, so "merge" and "deploy" are the
# same act and there is no release step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }

upstream="$work/upstream"
mkdir -p "$upstream/bin" "$upstream/skills/board"
cp "$repo_root/bin/self-update.sh" "$repo_root/bin/load-pairs.sh" \
   "$repo_root/bin/installation.py" "$upstream/bin/"
cat >"$upstream/bin/install-skills.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$upstream/skills/board/supervise.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$upstream/bin/install-skills.sh" "$upstream/bin/self-update.sh" "$upstream/skills/board/supervise.sh"

git_q "$upstream" init -q -b main
git_q "$upstream" add -A
git_q "$upstream" commit -q -m first

py_home="$work/home"
mkdir -p "$py_home"
fixture_add_installation "$py_home" demo claude
install_home="$py_home/.foreman/demo"
install="$install_home/install"
git_q "$work" clone -q "$upstream" "$install"

update() { # <ref-or-empty>
  if [[ -n "${1:-}" ]]; then
    HOME="$py_home" FOREMAN_HOME="$install_home" FOREMAN_UPDATE_REF="$1" \
      "$install/bin/self-update.sh" 2>&1
  else
    HOME="$py_home" FOREMAN_HOME="$install_home" \
      "$install/bin/self-update.sh" 2>&1
  fi
}
head_of() { git -C "$install" rev-parse HEAD; }

# release starts at main; then main moves ahead of it.
git_q "$upstream" branch -q release
printf 'm\n' >"$upstream/m.txt"
git_q "$upstream" add -A
git_q "$upstream" commit -q -m "on main"
main_tip="$(git -C "$upstream" rev-parse main)"

before="$(head_of)"
out="$(update origin/release)" || bad "pinned update exited non-zero: $out"
[[ "$(head_of)" == "$before" ]] && grep -q "already at" <<<"$out" \
  && ok "a release-pinned clone ignores a new main commit" \
  || bad "release pin moved the clone or did not report up to date: $out"

# Move the release onto main: now it deploys.
git_q "$upstream" branch -qf release main
out="$(update origin/release)" || bad "promoted update exited non-zero: $out"
[[ "$(head_of)" == "$main_tip" ]] \
  && ok "a release-pinned clone advances when the release moves" \
  || bad "promote -> head=$(head_of) want=$main_tip: $out"

# WITH NO OVERRIDE the default is GitHub Releases, not main. This clone's
# origin is a local path, so gh cannot answer and the run refuses -- which is
# how we know it is not silently tracking main.
printf 'n\n' >"$upstream/n.txt"
git_q "$upstream" add -A
git_q "$upstream" commit -q -m "on main again"
before="$(head_of)"
if out="$(update 2>&1)"; then
  bad "an unpinned update succeeded with no release to follow: $out"
else
  grep -q "gh release list failed" <<<"$out" \
    && [[ "$(head_of)" == "$before" ]] \
    && ok "with no override it follows releases, not main" \
    || bad "unpinned -> $out"
fi

exit "$fail"
