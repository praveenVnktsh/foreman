#!/usr/bin/env bash
# Claim: by default bin/self-update.sh follows the LATEST GitHub Release -- not
# main -- and treats "no release yet" as nothing to do, while gh being absent is
# a refusal.
#
# The failure it prevents: without a release signal, every merge to main reaches
# every installation on its next fire, so merge and deploy are the same act.
# gh is stubbed at the external boundary; the real self-update, the real fetch
# and the real fast-forward run.
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
git_q "$upstream" commit -q -m A
git_q "$upstream" tag v1
a_sha="$(git -C "$upstream" rev-parse HEAD)"

py_home="$work/home"
mkdir -p "$py_home"
fixture_add_installation "$py_home" demo claude
install_home="$py_home/.foreman/demo"
install="$install_home/install"
git_q "$work" clone -q "$upstream" "$install"

# main moves ahead of the released commit.
git_q "$upstream" commit -q --allow-empty -m B
b_sha="$(git -C "$upstream" rev-parse HEAD)"

# A gh stand-in that reports GH_TAG as the latest release tag (empty = none).
stub="$work/stub"
mkdir -p "$stub"
cat >"$stub/gh" <<'GH'
#!/usr/bin/env bash
printf '%s' "${GH_TAG-}"
# GH_FAIL makes it exit non-zero, standing in for an unauthenticated or
# unreachable gh rather than an empty release list.
[ -z "${GH_FAIL-}" ]
GH
chmod +x "$stub/gh"

update() { # with the stub gh on PATH
  HOME="$py_home" FOREMAN_HOME="$install_home" PATH="$stub:$PATH" \
    "$install/bin/self-update.sh" 2>&1
}
head_of() { git -C "$install" rev-parse HEAD; }

out="$(GH_TAG=v1 update)" || bad "a release update exited non-zero: $out"
[[ "$(head_of)" == "$a_sha" ]] \
  && ok "the install follows the release, not the newer main" \
  || bad "release v1 -> head=$(head_of) want=$a_sha: $out"

git_q "$upstream" tag v2
out="$(GH_TAG=v2 update)" || bad "the promoted release exited non-zero: $out"
[[ "$(head_of)" == "$b_sha" ]] \
  && ok "a newer release fast-forwards the install" \
  || bad "release v2 -> head=$(head_of) want=$b_sha: $out"

out="$(GH_TAG= update)" || bad "no-release exited non-zero: $out"
grep -q "none exists yet" <<<"$out" \
  && [[ "$(head_of)" == "$b_sha" ]] \
  && ok "no release yet is nothing to do, not an error" \
  || bad "no release -> head=$(head_of): $out"

# gh failing to answer is a refusal, not a silent no-op.
before="$(head_of)"
if out="$(GH_FAIL=1 update)"; then
  bad "a failing gh was treated as success: $out"
else
  grep -q "gh release list failed" <<<"$out" \
    && [[ "$(head_of)" == "$before" ]] \
    && ok "a failing gh is refused, and nothing moves" \
    || bad "failing gh -> $out"
fi

exit "$fail"
