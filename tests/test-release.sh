#!/usr/bin/env bash
# Claim: bin/release.sh cuts a GitHub Release at origin/main -- naming the tag,
# targeting main's commit -- and refuses a tag that already exists.
#
# The failure it prevents: a merge to main is not a deploy. Installations poll
# the latest release, so a change reaches them only when a release is cut, and a
# release must never be rewritten. gh is stubbed at the external boundary; the
# real script, the real git fetch and the real tag check run.
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
main_sha="$(git -C "$seed" rev-parse HEAD)"

# The clone release.sh runs from, with the real script in its bin/, and a gh
# stand-in that records the argv it was handed.
dep="$work/deployer"
git_q clone -q "$origin" "$dep"
mkdir -p "$dep/bin"
cp "$repo_root/bin/release.sh" "$dep/bin/release.sh"
chmod +x "$dep/bin/release.sh"
release="$dep/bin/release.sh"

stub="$work/stub"
mkdir -p "$stub"
cat >"$stub/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
exit 0
GH
chmod +x "$stub/gh"
export PATH="$stub:$PATH"
export GH_LOG="$work/gh.log"
: >"$GH_LOG"

out="$("$release" --dry-run 2>&1)" || bad "dry run failed: $out"
[[ "$out" == *"would cut v"*"at $main_sha"* || "$out" == *"would cut v"* ]] \
  && ok "a dry run names the tag it would cut" \
  || bad "dry run said: $out"
[[ -s "$GH_LOG" ]] && bad "a dry run called gh" || ok "a dry run publishes nothing"

out="$("$release" --version v1.0.0 2>&1)" || bad "cut failed: $out"
want="release create v1.0.0 --target $main_sha --title v1.0.0 --generate-notes"
if grep -qF "$want" "$GH_LOG"; then
  ok "the release is created at main's commit, with generated notes"
else
  bad "gh was not called as expected; log: $(cat "$GH_LOG")"
fi

# A tag that already exists is refused before gh is asked to create it.
git_q -C "$seed" tag v9.9.9
git_q -C "$seed" push -q origin v9.9.9
: >"$GH_LOG"
if out="$("$release" --version v9.9.9 2>&1)"; then
  bad "an existing tag was released anyway: $out"
else
  grep -q "already exists" <<<"$out" \
    && [[ ! -s "$GH_LOG" ]] \
    && ok "an existing tag is refused, and gh is never called" \
    || bad "existing tag -> $out; gh log: $(cat "$GH_LOG")"
fi

# The default tag is the date, and a second release the same day gets a suffix.
out="$("$release" --dry-run 2>&1)"
[[ "$out" == *"would cut v$(date -u +%Y.%m.%d)"* ]] \
  && ok "the default tag is today's date" \
  || bad "default tag said: $out"

# A head commit marked do-not-release is not cut by the Action that runs this.
git_q -C "$seed" commit -q --allow-empty -m "wip [skip release]"
git_q -C "$seed" push -q origin main
: >"$GH_LOG"
if out="$("$release" 2>&1)"; then
  grep -q "do-not-release" <<<"$out" && [[ ! -s "$GH_LOG" ]] \
    && ok "a flagged head commit is skipped, and gh is never called" \
    || bad "flagged head -> $out; gh log: $(cat "$GH_LOG")"
else
  bad "a flagged commit failed instead of skipping: $out"
fi

out="$("$release" --force 2>&1)" || bad "--force failed: $out"
grep -q "release create v" "$GH_LOG" \
  && ok "--force cuts a flagged commit anyway" \
  || bad "--force did not call gh: $(cat "$GH_LOG")"

exit "$fail"
