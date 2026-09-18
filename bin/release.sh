#!/usr/bin/env bash
# Cut a GitHub Release of origin/main -- the thing installations follow.
#
#   release.sh --dry-run          say what it would cut, change nothing
#   release.sh                    tag origin/main and publish a release
#   release.sh --version v1.2.3   name the tag (default vYYYY.MM.DD)
#
# A MERGE TO MAIN DOES NOT DEPLOY. An installation's bin/self-update.sh polls
# the LATEST RELEASE and fast-forwards to its tag, so a merge reaches it only
# when a release is cut. This is that step.
#
# THE TAG IS CREATED BY THE RELEASE. `gh release create <tag> --target <sha>`
# makes the tag and the release in one act, so there is never a tag with no
# release. A tag that already exists is refused rather than rewritten.
#
# Run it from any clone of this repository with push access.
set -euo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$HERE")"

VERSION=""
DRY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    *) die "unknown argument: $1 (expected --dry-run or --version <tag>)" ;;
  esac
done

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$ROOT is not a git repository"
command -v gh >/dev/null 2>&1 \
  || die "gh is required to cut a release; install it and run 'gh auth login'"

GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
GIT_TERMINAL_PROMPT=0 \
  git -C "$ROOT" fetch --quiet origin main \
  || die "git fetch origin main failed or timed out"
NEW="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
NEW_SHORT="$(git -C "$ROOT" rev-parse --short "$NEW")"
SUBJECT="$(git -C "$ROOT" log -1 --format=%s "$NEW")"

tag_exists() { git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1; }

# The tag. `--version` names it; otherwise the date, with a counter when that
# day already has a release. Both paths refuse a tag that exists: a release is
# never rewritten, and gh would refuse the create anyway with a vaguer message.
if [[ -n "$VERSION" ]]; then
  TAG="$VERSION"
  tag_exists "$TAG" && die "tag $TAG already exists on origin; a release is never rewritten"
else
  base="v$(date -u +%Y.%m.%d)"
  TAG="$base"
  n=1
  while tag_exists "$TAG"; do
    n=$((n + 1)); TAG="$base-$n"
  done
fi

case "$TAG" in
  ""|*" "*|*".."*) die "refusing an invalid tag name: '$TAG'" ;;
esac

if [[ -n "$DRY" ]]; then
  printf 'release: would cut %s at %s (%s)\n' "$TAG" "$NEW_SHORT" "$SUBJECT"
  exit 0
fi

# gh infers the repository from the clone's own remote, so this must run in it.
if ! ( cd "$ROOT" && gh release create "$TAG" --target "$NEW" --title "$TAG" --generate-notes ); then
  die "gh release create $TAG failed; no release was published"
fi

printf 'release: cut %s at %s; installations following releases update on their next fire.\n' \
  "$TAG" "$NEW_SHORT"
