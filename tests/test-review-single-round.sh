#!/usr/bin/env bash
# Claim: `reconcile.py` reports a card in review as ONE named verdict, and a
# round that blocked and was then fixed reaches `mergeable` on its checks --
# never "review it again".
#
# The failure it prevents: review runs once. A blocking finding buys exactly
# one fix, and that fix merges with no second reviewer. The only thing the tick
# could see before was "round 1 filed a blocking finding", which reads
# identically before and after the fix is pushed -- so it dispatched round 2,
# spent another reviewer and another round of the budget, and delayed every
# merge that ever blocked. `MAX_REVIEW_ROUNDS` stays in the contract as a
# ceiling; one round is the design.
#
# "The fix was pushed" is observable because `dispatch.sh` records the sha each
# reviewer was dispatched against. A head past that sha is a commit that landed
# after the review. A head that has NOT moved is a fix that was never pushed,
# and whether the build agent is still running is what separates "wait" from
# "ask a human".
#
# It drives the real script, stubbing `gh` and the agent registry -- the two
# external boundaries. Everything reconcile.py reasons over is real: the
# history file, the review files, and the verdict itself.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

TICKET="ACME-1"
SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"

home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"
card="$fh/instances/demo/cards/$TICKET"
mkdir -p "$card/reviews"

stub_bin="$work/bin"
registry="$work/agents.json"
pr_json="$work/pr.json"
mkdir -p "$stub_bin"
printf '[]\n' > "$registry"

# `gh pr list` answers from a file each case writes, and `gh pr diff` names one
# ordinary file so the diff reads as low risk. Nothing else is asked of gh on
# an OPEN pull request.
#
# `$work/gh-list-fails` makes the list exit non-zero, which is how a transient
# GitHub failure reaches `pr_for` as `lookup_failed` with no headRefOid. One
# such blip must not retire a card, so a case below asserts what the verdict is
# when the head cannot be read at all.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  if [[ -f "$work/gh-list-fails" ]]; then
    echo "gh: could not connect to github.com" >&2
    exit 1
  fi
  cat "$pr_json"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo "README.md"
  exit 0
fi
exit 1
STUB
chmod +x "$stub_bin/gh"

cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then
  cat "$registry"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/claude"

write_pr() {  # $1 headRefOid, $2 the Tests check's status:conclusion
  python3 - "$pr_json" "$1" "$2" <<'PY'
import json, sys
path, head, check = sys.argv[1:4]
status, _, conclusion = check.partition(":")
open(path, "w").write(json.dumps([{
    "number": 7,
    "state": "OPEN",
    "isCrossRepository": False,
    "headRefOid": head,
    "mergeStateStatus": "CLEAN",
    "url": "https://example.invalid/pr/7",
    "isDraft": False,
    "title": "Make the widget do the thing",
    "statusCheckRollup": [
        {"name": "Tests", "status": status, "conclusion": conclusion}
    ],
}]))
PY
}

history_line() {  # $1 the event object, as JSON
  printf '{"at":"2026-09-15T09:00:00Z","event":%s}\n' "$1" >> "$card/history.jsonl"
}

findings() {  # $1 file, $2.. severities
  python3 - "$card/reviews/$1" "${@:2}" <<'PY'
import json, sys
path, severities = sys.argv[1], sys.argv[2:]
open(path, "w").write(json.dumps({"findings": [
    {"severity": s, "file": "widget.py", "summary": "s", "failure": "f"}
    for s in severities
]}))
PY
}

# Prints the card's `review` verdict as
# `<verdict> <blocking> <merged_after_fix> <next_round> <reason>`.
# The status is the script's own, so a refusal is visible rather than parsed as
# an empty verdict.
verdict() {
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" \
    FOREMAN_INSTANCE=demo "$root/skills/board/reconcile.py" "$TICKET" \
    2>"$work/err" \
    | python3 -c '
import json, sys
review = json.load(sys.stdin)[0]["review"]
print(review["verdict"], review["blocking"],
      review.get("merged_after_fix", False), review.get("next_round", 0),
      review.get("reason", ""))
'
}

# Every case below the first block starts from an empty history and no review
# files. One case leaving its spawn lines behind is how a later case reads a
# round it never dispatched.
reset_card() {
  rm -f "$card/history.jsonl" "$card/reviews/"*.json
}

# --- round 1 blocked, nothing fixed yet --------------------------------------
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/build-1","role":"build","attempt":"1","ref":""}'
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA1"'"}'
findings 1a.json blocking
write_pr "$SHA1" "COMPLETED:SUCCESS"
out="$(verdict)"
case "$out" in
  "needs-fix 1 False"*) ok "a blocking finding with no fix yet is needs-fix" ;;
  *) bad "a blocking finding with no fix yet is needs-fix: $out $(cat "$work/err")" ;;
esac

# --- the fix is pushed and green ---------------------------------------------
#
# The head has moved past the sha the reviewer read, and every required check
# concluded well. That merges, on THIS round, and `merged_after_fix` is what
# SKILL.md logs before it does.
history_line '{"action":"resume","name":"foreman/demo/ACME-1/build-1","session":"s2"}'
write_pr "$SHA2" "COMPLETED:SUCCESS"
out="$(verdict)"
case "$out" in
  "mergeable 1 True"*) ok "a fix that is pushed and green is mergeable after one round" ;;
  *) bad "a fix that is pushed and green is mergeable after one round: $out" ;;
esac
case "$out" in
  *needs-review*|*"round 2"*) bad "a fixed card never asks for another review: $out" ;;
  *) ok "a fixed card never asks for another review" ;;
esac

# --- the fix is pushed and its checks have not concluded ---------------------
write_pr "$SHA2" "IN_PROGRESS:"
out="$(verdict)"
case "$out" in
  "awaiting-checks 1 False"*) ok "a fix whose checks are still running is awaiting-checks" ;;
  *) bad "a fix whose checks are still running is awaiting-checks: $out" ;;
esac

# --- the fix is pushed and a required check failed ---------------------------
write_pr "$SHA2" "COMPLETED:FAILURE"
out="$(verdict)"
case "$out" in
  "checks-failing 1 False"*) ok "a fix whose checks failed is checks-failing" ;;
  *) bad "a fix whose checks failed is checks-failing: $out" ;;
esac

# --- resumed, and the head never moved ---------------------------------------
#
# The build agent was resumed with the findings and pushed nothing. While it is
# still running that is ordinary; once it has stopped, nobody is going to push
# the fix, and the card is a human's.
write_pr "$SHA1" "COMPLETED:SUCCESS"
cat > "$registry" <<'JSON'
[{"name": "foreman/demo/ACME-1/build-1", "sessionId": "s2", "startedAt": 1,
  "cwd": "/tmp", "state": "working", "pid": 4242}]
JSON
out="$(verdict)"
case "$out" in
  "fixing 1 False"*) ok "a running build agent that has pushed nothing yet is fixing" ;;
  *) bad "a running build agent that has pushed nothing yet is fixing: $out" ;;
esac

cat > "$registry" <<'JSON'
[{"name": "foreman/demo/ACME-1/build-1", "sessionId": "s2", "startedAt": 1,
  "cwd": "/tmp", "state": "done", "pid": 4242}]
JSON
out="$(verdict)"
case "$out" in
  "fix-unresolved 1 False"*) ok "a finished build agent that pushed nothing is fix-unresolved" ;;
  *) bad "a finished build agent that pushed nothing is fix-unresolved: $out" ;;
esac
printf '[]\n' > "$registry"

# --- a round that found nothing blocking -------------------------------------
#
# Warnings and notes stay in the file for the scheduled cleanup to read. Only
# blocking gates.
findings 1a.json warning note
write_pr "$SHA1" "COMPLETED:SUCCESS"
out="$(verdict)"
case "$out" in
  "mergeable 0 False"*) ok "a round with no blocking finding is mergeable" ;;
  *) bad "a round with no blocking finding is mergeable: $out" ;;
esac

# --- a review file that cannot be read ---------------------------------------
#
# Half a file is not a review that found nothing. Reading one as an empty
# findings list merges a diff nobody finished reading.
printf '{"findings": [' > "$card/reviews/1a.json"
out="$(verdict)"
case "$out" in
  "awaiting-review 0 False"*) ok "an unreadable review file is awaiting-review, not mergeable" ;;
  *) bad "an unreadable review file is awaiting-review, not mergeable: $out" ;;
esac

# --- a card nobody has reviewed ----------------------------------------------
rm -f "$card/history.jsonl"
out="$(verdict)"
case "$out" in
  "unreviewed 0 False"*) ok "a card with no review spawn is unreviewed" ;;
  *) bad "a card with no review spawn is unreviewed: $out" ;;
esac

# --- a round re-dispatched at a newer sha -------------------------------------
#
# A reviewer that dies is re-dispatched, and by then the head may have moved --
# so ONE round carries two spawn lines at two different shas. The round's LAST
# ref is the sha the review that actually ran was asked about. Reading the
# FIRST one made "the fix was pushed" true at a sha that landed BEFORE the
# findings were even written, so a fix agent that pushed nothing reached
# `mergeable` and the blocking finding merged unfixed.
#
# The same two lines name one reviewer slot, `1a`. Reading its file once per
# spawn line counted its single blocking finding twice.
reset_card
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA1"'"}'
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA2"'"}'
findings 1a.json blocking
history_line '{"action":"resume","name":"foreman/demo/ACME-1/build-1","session":"s3"}'
write_pr "$SHA2" "COMPLETED:SUCCESS"
printf '[]\n' > "$registry"
out="$(verdict)"
case "$out" in
  mergeable*) bad "a round re-dispatched at the head's own sha is not a pushed fix: $out" ;;
  "fix-unresolved 1"*) ok "a round re-dispatched at the head's own sha is not a pushed fix" ;;
  *) bad "a round re-dispatched at the head's own sha is not a pushed fix: $out $(cat "$work/err")" ;;
esac
# The count is read as a field, not matched inside the line: every verdict's
# reason names a round number, so a substring match on `1` passes whatever the
# count says.
blocking_count="$(printf '%s\n' "$out" | awk '{print $2}')"
if [[ "$blocking_count" == "1" ]]; then
  ok "one reviewer slot spawned twice files one blocking finding, not two"
else
  bad "one reviewer slot spawned twice files one blocking finding, not two: $out"
fi

# --- a round that recorded no ref at all --------------------------------------
#
# No history written before this change carries a `ref`, so the head cannot be
# compared with anything. That is "I cannot judge the fix", not "the fix was
# never pushed" -- and the tick turns the latter into `Needs Human` with
# `board-failed`, retiring a green, pushed fix on a reason nobody gathered.
reset_card
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a"}'
findings 1a.json blocking
history_line '{"action":"resume","name":"foreman/demo/ACME-1/build-1","session":"s4"}'
write_pr "$SHA2" "COMPLETED:SUCCESS"
out="$(verdict)"
case "$out" in
  "ref-unknown 1 False"*) ok "a round with no recorded ref waits as ref-unknown" ;;
  *) bad "a round with no recorded ref waits as ref-unknown: $out $(cat "$work/err")" ;;
esac

# --- a head nobody could read -------------------------------------------------
#
# `pr_for` reports a failed `gh pr list` as `lookup_failed`, which carries no
# headRefOid. Exactly the same rule as the build path's: "I could not read it"
# and "it never moved" are not the same answer, and one transient gh failure
# must not hand the card to a person.
reset_card
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA1"'"}'
findings 1a.json blocking
history_line '{"action":"resume","name":"foreman/demo/ACME-1/build-1","session":"s5"}'
: > "$work/gh-list-fails"
out="$(verdict)"
rm -f "$work/gh-list-fails"
case "$out" in
  "ref-unknown 1 False"*) ok "an unreadable pull request head waits as ref-unknown" ;;
  *) bad "an unreadable pull request head waits as ref-unknown: $out $(cat "$work/err")" ;;
esac

# --- a clean round whose head has moved ---------------------------------------
#
# Round 1 read SHA1 and found nothing blocking. The head is SHA2, which no
# reviewer has ever read -- a resumed build pushing a fix for a failing check
# is enough to produce this. Merging on the round number alone ships code
# nobody reviewed, so the answer is a fresh round, and `MAX_REVIEW_ROUNDS` is
# what bounds how many times a moving head may ask for one.
reset_card
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA1"'"}'
findings 1a.json warning
write_pr "$SHA2" "COMPLETED:SUCCESS"
out="$(verdict)"
case "$out" in
  "head-moved 0 False 2"*) ok "a clean round whose head has moved asks for round 2" ;;
  *) bad "a clean round whose head has moved asks for round 2: $out $(cat "$work/err")" ;;
esac

[[ "$fail" -eq 0 ]] && printf 'PASS: review runs once and a fix merges on its checks\n'
exit "$fail"
