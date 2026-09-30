#!/usr/bin/env bash
# Cut a GitHub Release of a commit on origin/main -- the thing installations
# follow.
#
#   release.sh --dry-run          say what it would cut, change nothing
#   release.sh                    tag origin/main and publish a release
#   release.sh --version v1.2.3   name the tag (default vYYYY.MM.DD)
#   release.sh --sha <sha>        release <sha>, not main's head (or RELEASE_SHA)
#
# WHICH COMMIT. .github/workflows/release.yml runs this after CI passes and
# passes the commit CI ran on as RELEASE_SHA. Main may have moved on by then,
# and releasing main's head would ship a commit no CI run passed. The commit
# must be on origin/main; anything else is refused.
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
FORCE=""
SHA="${RELEASE_SHA:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --sha) [[ $# -ge 2 ]] || die "--sha needs a value"; SHA="$2"; shift 2 ;;
    *) die "unknown argument: $1 (expected --dry-run, --force, --version <tag> or --sha <sha>)" ;;
  esac
done
if [[ -n "$SHA" && ! "$SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  die "--sha (or RELEASE_SHA) must be a hex commit id, got '$SHA'"
fi

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$ROOT is not a git repository"
command -v gh >/dev/null 2>&1 \
  || die "gh is required to cut a release; install it and run 'gh auth login'"

fetch_origin() { # <refspec>
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
  GIT_TERMINAL_PROMPT=0 \
    git -C "$ROOT" fetch --quiet origin "$1"
}

fetch_origin main || die "git fetch origin main failed or timed out"
MAIN="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
if [[ -z "$SHA" ]]; then
  NEW="$MAIN"
else
  NEW="$(git -C "$ROOT" rev-parse --verify --quiet "$SHA^{commit}")" \
    || die "commit $SHA is not in this clone; expected a commit on origin/main"
  git -C "$ROOT" merge-base --is-ancestor "$NEW" "$MAIN" \
    || die "commit $SHA is not on origin/main; only main's commits are released"
fi
NEW_SHORT="$(git -C "$ROOT" rev-parse --short "$NEW")"
SUBJECT="$(git -C "$ROOT" log -1 --format=%s "$NEW")"

# NEVER RELEASE BACKWARDS. The Action runs this once per CI run that passes on
# main, at that run's commit, one job at a time but in the order the runs
# FINISH. Two merges close together can finish CI out of order. The older
# commit then released second, and "latest release" -- what every
# installation follows -- pointed back at it, undoing the newer one.
#
# So the latest published release is the floor. A commit at or behind it has
# already shipped, and this exits 0 without cutting, which the Action reads as
# a no-op. With no release yet there is no floor. A lookup that fails refuses:
# guessing "no release yet" is the one answer that can ship backwards.
LATEST_TAG="$(cd "$ROOT" && gh release list --exclude-drafts --exclude-pre-releases \
  --limit 1 --json tagName --jq '.[0].tagName // ""')" \
  || die "could not list the published releases (gh release list); nothing cut"
if [[ -n "$LATEST_TAG" ]]; then
  fetch_origin "refs/tags/$LATEST_TAG" \
    || die "the latest release $LATEST_TAG has no tag on origin that this clone can fetch; nothing cut"
  LATEST="$(git -C "$ROOT" rev-parse --verify --quiet "FETCH_HEAD^{commit}")" \
    || die "the latest release $LATEST_TAG does not tag a commit; nothing cut"
  if git -C "$ROOT" merge-base --is-ancestor "$NEW" "$LATEST"; then
    printf 'release: already released at or past %s (%s is at %s); nothing to do.\n' \
      "$NEW_SHORT" "$LATEST_TAG" "$(git -C "$ROOT" rev-parse --short "$LATEST")"
    exit 0
  fi
fi

# A COMMIT CAN OPT OUT OF RELEASING ITSELF. `.github/workflows/release.yml`
# runs this script after CI passes on main, so a merge releases unless it says
# otherwise. A commit with a line of its own reading `[skip release]` or
# `Release: skip` is not released: this exits 0 without cutting, which the
# Action reads as a successful no-op. --force cuts it anyway, and a manual
# `release.sh --version` on a DIFFERENT commit is unaffected -- the marker is on
# the commit being released, not a blanket switch.
#
# THE MARKER MUST BE A WHOLE LINE, and that is not a detail. A looser match
# fires on any prose that mentions the marker -- which is exactly what
# happened to this feature's own first release, when its PR description
# explained `Release: skip`. A trailer on its own line is deliberate; a
# sentence about it is not.
skip_marked() {
  grep -qiE '^[[:space:]]*(\[skip release\]|release:[[:space:]]*skip)[[:space:]]*$'
}

# THE PULL REQUEST'S BODY COUNTS TOO. This repository's squash message is the
# branch's commit messages, not the PR body, so a marker written in the PR --
# where AGENTS.md says to put it -- never reached the commit and the merge
# released anyway. gh fills {owner}/{repo} from this clone's remote. A lookup
# that fails refuses: releasing a commit that asked not to be is the one
# outcome this check exists to prevent.
pr_bodies() {
  ( cd "$ROOT" && gh api "repos/{owner}/{repo}/commits/$NEW/pulls" --jq '.[].body // ""' )
}

MARKED=""
if [[ -z "$FORCE" ]]; then
  if git -C "$ROOT" log -1 --format=%B "$NEW" | skip_marked; then
    MARKED="its commit message"
  else
    BODIES="$(pr_bodies)" \
      || die "could not read the pull request for $NEW_SHORT (gh api .../commits/$NEW/pulls); nothing cut"
    if printf '%s\n' "$BODIES" | skip_marked; then
      MARKED="its pull request"
    fi
  fi
fi
if [[ -n "$MARKED" ]]; then
  if [[ -n "$DRY" ]]; then
    printf 'release: %s is marked do-not-release in %s; would cut nothing (--force overrides).\n' "$NEW_SHORT" "$MARKED"
    exit 0
  fi
  printf 'release: %s is marked do-not-release in %s; nothing cut (--force overrides).\n' "$NEW_SHORT" "$MARKED"
  exit 0
fi

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
