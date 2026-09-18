#!/usr/bin/env bash
# Claim: bin/release.sh promotes origin/main onto the release ref, and refuses
# to rewrite a release ref that has diverged from main.
#
# The failure it prevents: with installations pinned to origin/release, a merge
# to main must NOT deploy. release.sh is the one step that does, and its push
# must be a fast-forward so a release branch can never be rewritten under the
# installations fetching it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
git_q() { git -c user.email=t@t -c user.name=t "$@"; }

origin="$work/origin.git"
seed="$work/seed"
git_q init -q --bare -b main "$origin"
git_q init -q -b main "$seed"
git_q -C "$seed" remote add origin "$origin"
echo one >"$seed/file.txt"
git_q -C "$seed" add -A
git_q -C "$seed" commit -q -m one
git_q -C "$seed" push -q origin main

# The clone release.sh runs from, with the real script in its bin/.
dep="$work/deployer"
git_q clone -q "$origin" "$dep"
mkdir -p "$dep/bin"
cp "$repo_root/bin/release.sh" "$dep/bin/release.sh"
chmod +x "$dep/bin/release.sh"
release="$dep/bin/release.sh"

release_tip() { git -C "$origin" rev-parse refs/heads/release 2>/dev/null || echo ""; }
main_tip() { git -C "$origin" rev-parse refs/heads/main; }

out="$("$release" --dry-run 2>&1)" || bad "dry run failed: $out"
[[ "$out" == *"would create release"* ]] && ok "a missing release ref is reported as a create" || bad "dry run said: $out"

out="$("$release" 2>&1)" || bad "create failed: $out"
[[ "$(release_tip)" == "$(main_tip)" ]] && ok "release is created at main" || bad "release tip $(release_tip) != main $(main_tip)"

echo two >"$seed/file.txt"
git_q -C "$seed" commit -q -am two
git_q -C "$seed" push -q origin main
out="$("$release" 2>&1)" || bad "promote failed: $out"
[[ "$(release_tip)" == "$(main_tip)" ]] && ok "release fast-forwards to a new main" || bad "release did not advance"

out="$("$release" 2>&1)" || bad "second promote failed: $out"
[[ "$out" == *"nothing to promote"* ]] && ok "an up-to-date release is a no-op" || bad "promote again said: $out"

# A release ref that has moved off main must be refused, never rewritten.
git_q -C "$seed" checkout -q -b divergence
echo three >"$seed/other.txt"
git_q -C "$seed" add -A
git_q -C "$seed" commit -q -m divergence
git_q -C "$seed" push -q origin divergence:refs/heads/release
git_q -C "$seed" checkout -q main
echo four >"$seed/file.txt"
git_q -C "$seed" commit -q -am four
git_q -C "$seed" push -q origin main
diverged="$(release_tip)"
if out="$("$release" 2>&1)"; then
  bad "a diverged release was promoted: $out"
else
  [[ "$(release_tip)" == "$diverged" ]] \
    && ok "a diverged release ref is refused and left alone" \
    || bad "release was rewritten to $(release_tip)"
fi

exit "$fail"
