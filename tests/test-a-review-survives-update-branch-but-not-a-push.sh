#!/usr/bin/env bash
# Claim: a clean review stays `mergeable` when the only thing that moved the
# head is `gh pr update-branch`, and every other move is `head-moved`. Every
# `mergeable` names the one sha the merge may pin, `merge_head`.
#
# The failure it prevents: the tick runs `gh pr update-branch` itself when a
# green card is BEHIND `main`. That moves the head past the sha the reviewer
# read, and `reconcile.py` read the move as `head-moved`. At the default
# MAX_REVIEW_ROUNDS of 1 that sent every card whose `main` moved before its
# merge to `Needs Human`. An update-branch merge adds nothing but `main`, so
# the reviewed diff is still what would merge.
#
# What must still be `head-moved`: a commit pushed on top of the reviewed sha,
# a merge that also carries an edit of its own, and a merge of anything that
# is not on `main`. Each of those is code no reviewer has read.
#
# It drives the real script against a real origin, so the merges are real
# commits and git answers the ancestry. Only `gh` (the pull request) and
# `claude` (the agent registry) are stubbed.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/without-board.sh
source "$root/tests/lib/without-board.sh"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

TICKET="ACME-1"
BRANCH="foreman/demo/$TICKET"

g() {  # git in $1, with an identity and no signing, whatever the machine says
  git -C "$1" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false -c init.defaultBranch=main "${@:2}"
}
commit_file() {  # $1 repo, $2 file, $3 content -> prints the new sha
  printf '%s\n' "$3" > "$1/$2"
  g "$1" add "$2" && g "$1" commit -q -m "edit $2" && g "$1" rev-parse HEAD
}

origin="$work/origin.git"
author="$work/author"
repo="$work/repo"
git init -q --bare "$origin"
git -C "$origin" symbolic-ref HEAD refs/heads/main
mkdir -p "$author"
g "$author" init -q -b main
printf 'a\n' > "$author/a.txt"; printf 'b\n' > "$author/b.txt"
g "$author" add a.txt b.txt && g "$author" commit -q -m base
g "$author" remote add origin "$origin"
g "$author" push -q origin main

# R: the head the reviewer read.
g "$author" checkout -q -b "$BRANCH"
R="$(commit_file "$author" a.txt 'a, reviewed')"
# main moves on underneath it.
g "$author" checkout -q main
M1="$(commit_file "$author" b.txt 'b, from main')"
g "$author" push -q origin main
g "$author" checkout -q "$BRANCH"

# H1: what `gh pr update-branch` makes -- main merged into the reviewed head.
g "$author" merge -q --no-ff -m "Merge branch 'main' into $BRANCH" main
H1="$(g "$author" rev-parse HEAD)"
# H2: main moved again, and the tick updated the branch a second time.
g "$author" checkout -q main
commit_file "$author" c.txt 'c, from main' >/dev/null
g "$author" push -q origin main
g "$author" checkout -q "$BRANCH"
g "$author" merge -q --no-ff -m "Merge branch 'main' into $BRANCH" main
H2="$(g "$author" rev-parse HEAD)"

# PUSHED: an ordinary commit on the reviewed head.
g "$author" checkout -q -b pushed "$R"
PUSHED="$(commit_file "$author" a.txt 'a, changed after review')"
# EVIL: the same merge as H1, carrying an edit nobody reviewed.
g "$author" checkout -q -b evil "$R"
g "$author" merge -q --no-ff --no-commit "$M1" >/dev/null 2>&1
printf 'a, slipped into the merge\n' > "$author/a.txt"
g "$author" add a.txt && g "$author" commit -q -m "Merge branch 'main'"
EVIL="$(g "$author" rev-parse HEAD)"
# SIDE: a merge of a commit that is on no branch of origin's main.
g "$author" checkout -q -b side "$R~1"
SIDE_TIP="$(commit_file "$author" d.txt 'd, never on main')"
g "$author" checkout -q -b sidemerge "$R"
g "$author" merge -q --no-ff -m "Merge side" "$SIDE_TIP"
SIDE="$(g "$author" rev-parse HEAD)"

git clone -q "$origin" "$repo"
fixture_board_toml "$repo"
home="$work/home"
fh="$home/.foreman"
fixture_add_board "$home" demo "$repo"
card="$fh/instances/demo/cards/$TICKET"
mkdir -p "$card/reviews"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
printf '[]\n' > "$work/agents.json"
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then cat "$work/pr.json"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then echo a.txt; exit 0; fi
exit 1
STUB
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "agents" ]] && cat "$work/agents.json"
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

# Point the card's branch on origin at $1, and the pull request's head at it.
head_is() {
  g "$author" push -q --force origin "$1:refs/heads/$BRANCH"
  python3 - "$work/pr.json" "$1" <<'PY'
import json, sys
path, head = sys.argv[1:3]
open(path, "w").write(json.dumps([{
    "number": 7, "state": "OPEN", "isCrossRepository": False,
    "headRefOid": head, "mergeStateStatus": "CLEAN", "isDraft": False,
    "url": "https://example.invalid/pr/7", "title": "t",
    "statusCheckRollup": [{"name": "Tests", "status": "COMPLETED",
                           "conclusion": "SUCCESS"}],
}]))
PY
}

# One clean round, dispatched against $1. `findings` is what the reviewer wrote.
reviewed_at() {
  rm -f "$card/history.jsonl" "$card/reviews/"*.json
  printf '{"at":"2026-09-30T09:00:00Z","event":{"action":"spawn","name":"foreman/demo/%s/review-1a","role":"review","attempt":"1a","ref":"%s"}}\n' \
    "$TICKET" "$1" >> "$card/history.jsonl"
  printf '{"findings": [{"severity": "note", "file": "a.txt", "summary": "s", "failure": "f"}]}\n' \
    > "$card/reviews/1a.json"
}

# `<verdict> <merge_head or -> <next_round or 0>`
verdict() {
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$TICKET" 2>"$work/err" \
    | python3 -c '
import json, sys
review = json.load(sys.stdin)[0]["review"]
print(review["verdict"], review.get("merge_head") or "-", review.get("next_round", 0))
'
}

expect() {  # $1 claim, $2 wanted
  local got
  got="$(verdict)"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

reviewed_at "$R"
head_is "$R"
expect "a clean round at the head it read merges that head" "mergeable $R 0"

head_is "$H1"
expect "an update-branch merge onto the reviewed head stays mergeable, pinned to the merge" \
  "mergeable $H1 0"

head_is "$H2"
expect "two update-branch merges in a row stay mergeable" "mergeable $H2 0"

head_is "$PUSHED"
expect "a commit pushed on the reviewed head is head-moved" "head-moved - 2"

head_is "$EVIL"
expect "a merge that carries an edit of its own is head-moved" "head-moved - 2"

head_is "$SIDE"
expect "a merge of a commit not on main is head-moved" "head-moved - 2"

# A blocking round whose fix is pushed and green merges the fix head.
rm -f "$card/history.jsonl" "$card/reviews/"*.json
printf '{"at":"2026-09-30T09:00:00Z","event":{"action":"spawn","name":"foreman/demo/%s/review-1a","role":"review","attempt":"1a","ref":"%s"}}\n' \
  "$TICKET" "$R" >> "$card/history.jsonl"
printf '{"findings": [{"severity": "blocking", "file": "a.txt", "summary": "s", "failure": "f"}]}\n' \
  > "$card/reviews/1a.json"
printf '{"at":"2026-09-30T09:05:00Z","event":{"action":"resume","name":"foreman/demo/%s/build-1","session":"s","role":"build","reason":"fix"}}\n' \
  "$TICKET" >> "$card/history.jsonl"
head_is "$PUSHED"
expect "a pushed, green fix merges the fix head" "mergeable $PUSHED 0"

[[ "$fail" -eq 0 ]] && printf 'PASS: update-branch keeps a review; any other move does not\n'
exit "$fail"
