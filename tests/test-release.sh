#!/usr/bin/env bash
# Claim: bin/release.sh cuts a GitHub Release at origin/main -- naming the tag,
# targeting main's commit, or the commit it is given when that commit is on
# main -- refuses a tag that already exists, and skips a commit whose message
# or pull request body carries the do-not-release marker on a line of its own,
# and never releases a commit at or behind the latest published release.
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
# stand-in that records the argv of every WRITE it was handed. `gh api` is
# the read of the commit's pull requests: it prints GH_PR_BODY, and fails when
# GH_API_FAIL is set. `gh release list` is the read of the latest published
# release: it prints GH_LATEST_TAG (empty is "no release yet"), and fails when
# GH_LIST_FAIL is set.
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
if [[ "$1" == "api" ]]; then
  [[ -z "${GH_API_FAIL-}" ]] || { echo "HTTP 502" >&2; exit 1; }
  printf '%s\n' "${GH_PR_BODY-}"
  exit 0
fi
if [[ "$1 $2" == "release list" ]]; then
  [[ -z "${GH_LIST_FAIL-}" ]] || { echo "HTTP 502" >&2; exit 1; }
  printf '%s\n' "${GH_LATEST_TAG-}"
  exit 0
fi
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
# The marker is a line of its own -- a trailer -- not a phrase in a sentence.
git_q -C "$seed" commit -q --allow-empty -m "wip" -m "[skip release]"
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

# PROSE ABOUT THE MARKER IS NOT THE MARKER. A commit body that mentions
# `Release: skip` in a sentence must still release -- this is the bug that
# skipped this feature's own first release, whose PR body explained the marker.
git_q -C "$seed" commit -q --allow-empty -m "docs" -m "Explains the Release: skip trailer."
git_q -C "$seed" push -q origin main
: >"$GH_LOG"
out="$("$release" 2>&1)" || bad "a prose mention failed to release: $out"
grep -q "release create v" "$GH_LOG" \
  && ok "prose about the marker does not skip the release" \
  || bad "prose mention skipped the release: $out"

# THE PULL REQUEST BODY COUNTS. This repository squashes with the commit
# messages, so a marker in the PR body never reaches main's commit.
git_q -C "$seed" commit -q --allow-empty -m "a change whose PR opted out"
git_q -C "$seed" push -q origin main
: >"$GH_LOG"
out="$(GH_PR_BODY=$'Summary.\r\n\r\nRelease: skip\r\n' "$release" 2>&1)" || bad "a PR-body skip failed: $out"
grep -q "do-not-release in its pull request" <<<"$out" && [[ ! -s "$GH_LOG" ]] \
  && ok "a marker line in the pull request body skips the release" \
  || bad "PR-body marker -> $out; gh log: $(cat "$GH_LOG")"

: >"$GH_LOG"
out="$(GH_PR_BODY="This explains the Release: skip trailer." "$release" 2>&1)" || bad "PR prose failed: $out"
grep -q "release create v" "$GH_LOG" \
  && ok "prose about the marker in a PR body does not skip the release" \
  || bad "PR prose skipped the release: $out"

: >"$GH_LOG"
if out="$(GH_API_FAIL=1 "$release" 2>&1)"; then
  bad "a failed PR lookup released anyway: $out"
else
  [[ ! -s "$GH_LOG" ]] && grep -q "could not read the pull request" <<<"$out" \
    && ok "a PR lookup that fails refuses rather than releasing" \
    || bad "failed PR lookup -> $out"
fi

# THE COMMIT CI PASSED, not main's head. The workflow passes RELEASE_SHA; main
# may have moved on while CI ran.
passed_sha="$(git -C "$seed" rev-parse HEAD)"
git_q -C "$seed" commit -q --allow-empty -m "landed while CI ran"
git_q -C "$seed" push -q origin main
: >"$GH_LOG"
out="$(RELEASE_SHA="$passed_sha" "$release" --version v2.0.0 2>&1)" || bad "RELEASE_SHA failed: $out"
grep -qF "release create v2.0.0 --target $passed_sha " "$GH_LOG" \
  && ok "RELEASE_SHA releases that commit, not main's newer head" \
  || bad "RELEASE_SHA -> $out; gh log: $(cat "$GH_LOG")"

git_q -C "$seed" checkout -q -b side
git_q -C "$seed" commit -q --allow-empty -m "never on main"
git_q -C "$seed" push -q origin side
side_sha="$(git -C "$seed" rev-parse HEAD)"
git -C "$dep" fetch -q origin side
: >"$GH_LOG"
if out="$("$release" --sha "$side_sha" 2>&1)"; then
  bad "a commit off main was released: $out"
else
  [[ ! -s "$GH_LOG" ]] && grep -q "not on origin/main" <<<"$out" \
    && ok "a commit that is not on main is refused" \
    || bad "off-main sha -> $out"
fi

# NEVER RELEASE BACKWARDS. The Action releases each CI run's commit in the
# order the runs finish, so an older commit can arrive after a newer one has
# been released. Tags on origin stand in for the published releases here; the
# stub names which one is latest.
git_q -C "$seed" checkout -q main
older_sha="$(git -C "$seed" rev-parse HEAD)"
git_q -C "$seed" commit -q --allow-empty -m "newer, released first"
git_q -C "$seed" push -q origin main
newer_sha="$(git -C "$seed" rev-parse HEAD)"
git_q -C "$seed" tag v3.0.0 "$newer_sha"
git_q -C "$seed" push -q origin v3.0.0

: >"$GH_LOG"
out="$(GH_LATEST_TAG=v3.0.0 RELEASE_SHA="$older_sha" "$release" 2>&1)" \
  || bad "an older commit failed instead of skipping: $out"
[[ ! -s "$GH_LOG" ]] && grep -q "already released at or past" <<<"$out" \
  && ok "a commit behind the latest release is not released after it" \
  || bad "older than latest -> $out; gh log: $(cat "$GH_LOG")"

: >"$GH_LOG"
out="$(GH_LATEST_TAG=v3.0.0 RELEASE_SHA="$newer_sha" "$release" 2>&1)" \
  || bad "the latest release's own commit failed instead of skipping: $out"
[[ ! -s "$GH_LOG" ]] && grep -q "already released at or past" <<<"$out" \
  && ok "the latest release's own commit is not released twice" \
  || bad "equal to latest -> $out; gh log: $(cat "$GH_LOG")"

git_q -C "$seed" commit -q --allow-empty -m "past the latest release"
git_q -C "$seed" push -q origin main
past_sha="$(git -C "$seed" rev-parse HEAD)"
: >"$GH_LOG"
out="$(GH_LATEST_TAG=v3.0.0 RELEASE_SHA="$past_sha" "$release" --version v3.1.0 2>&1)" \
  || bad "a commit past the latest release failed: $out"
grep -qF "release create v3.1.0 --target $past_sha " "$GH_LOG" \
  && ok "a commit past the latest release is released" \
  || bad "newer than latest -> $out; gh log: $(cat "$GH_LOG")"

: >"$GH_LOG"
if out="$(GH_LIST_FAIL=1 RELEASE_SHA="$past_sha" "$release" 2>&1)"; then
  bad "a failed release lookup released anyway: $out"
else
  [[ ! -s "$GH_LOG" ]] && grep -q "could not list the published releases" <<<"$out" \
    && ok "a release lookup that fails refuses rather than releasing" \
    || bad "failed release lookup -> $out"
fi

: >"$GH_LOG"
if out="$(GH_LATEST_TAG=v404 RELEASE_SHA="$past_sha" "$release" 2>&1)"; then
  bad "a latest release with no tag released anyway: $out"
else
  [[ ! -s "$GH_LOG" ]] && grep -q "has no tag on origin" <<<"$out" \
    && ok "a latest release whose tag is missing refuses rather than releasing" \
    || bad "missing latest tag -> $out"
fi

exit "$fail"
