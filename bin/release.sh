#!/usr/bin/env bash
# Promote main to the release ref installations track.
#
#   release.sh --dry-run          say what it would promote, change nothing
#   release.sh                    fast-forward release to origin/main and push
#   release.sh --ref <branch>     promote a differently named release ref
#
# A MERGE TO MAIN DOES NOT DEPLOY. An installation pinned with
# FOREMAN_UPDATE_REF=origin/release (bin/install-self-update.sh --ref) fetches
# the release branch, not main. This is the promote step, and it is what
# deploys: within one self-update interval the pinned installations fast-forward
# to the release tip and restart their ticks.
#
# THE PUSH IS A FAST-FORWARD. `git push` refuses a non-fast-forward without an
# explicit force, and this script never forces. A release branch that has
# diverged from main is refused rather than rewritten -- the same "never rewrite
# a clone under the operator" rule bin/self-update.sh follows.
#
# Run it from any clone with push access: an operator's working copy, or an
# installation's. It only fetches and pushes; it never touches a working tree.
set -euo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$HERE")"

REF="release"
DRY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --ref) [[ $# -ge 2 ]] || die "--ref needs a value"; REF="$2"; shift 2 ;;
    *) die "unknown argument: $1 (expected --dry-run or --ref <branch>)" ;;
  esac
done

# A branch name git will accept and a release cannot mean. `main` is refused
# outright: promoting main onto a ref installations fetch would make every merge
# a deploy again, which is the thing this exists to stop.
case "$REF" in
  ""|*" "*|*".."*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@"*)
    die "refusing an invalid release branch name: '$REF'" ;;
  main) die "the release ref may not be 'main'; that deploys on every merge" ;;
esac

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$ROOT is not a git repository"

fetch() { # <ref>...
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
  GIT_TERMINAL_PROMPT=0 \
    git -C "$ROOT" fetch --quiet origin "$@"
}
push() { # <refspec>
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
  GIT_TERMINAL_PROMPT=0 \
    git -C "$ROOT" push "$@"
}

fetch main || die "git fetch origin main failed or timed out"
NEW="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
NEW_SHORT="$(git -C "$ROOT" rev-parse --short "$NEW")"
SUBJECT="$(git -C "$ROOT" log -1 --format=%s "$NEW")"

# The release tip as origin has it, if it exists at all. A best-effort fetch:
# a branch that has never been pushed fails here, and that is the create case.
fetch "$REF" >/dev/null 2>&1 || true
if OLD="$(git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$REF")"; then
  OLD_SHORT="$(git -C "$ROOT" rev-parse --short "$OLD")"
  if [[ "$OLD" == "$NEW" ]]; then
    printf 'release: %s is already at %s; nothing to promote.\n' "$REF" "$NEW_SHORT"
    exit 0
  fi
  git -C "$ROOT" merge-base --is-ancestor "$OLD" "$NEW" \
    || die "origin/$REF ($OLD_SHORT) is not an ancestor of origin/main ($NEW_SHORT); refusing to rewrite the release branch. Move it by hand if you mean to."
else
  OLD_SHORT=""
fi

if [[ -n "$DRY" ]]; then
  if [[ -n "$OLD_SHORT" ]]; then
    printf 'release: would fast-forward %s from %s to %s (%s)\n' "$REF" "$OLD_SHORT" "$NEW_SHORT" "$SUBJECT"
  else
    printf 'release: would create %s at %s (%s)\n' "$REF" "$NEW_SHORT" "$SUBJECT"
  fi
  exit 0
fi

push origin "$NEW:refs/heads/$REF" \
  || die "pushing $NEW_SHORT to $REF failed; the release branch is unchanged"

if [[ -n "$OLD_SHORT" ]]; then
  printf 'release: %s %s -> %s; installations pinned to origin/%s update on their next fire.\n' \
    "$REF" "$OLD_SHORT" "$NEW_SHORT" "$REF"
else
  printf 'release: created %s at %s; installations pinned to origin/%s update on their next fire.\n' \
    "$REF" "$NEW_SHORT" "$REF"
fi
