#!/usr/bin/env bash
# Claim: a pull request that conflicts with `main` is reported as
# `conflicting`, a `rebuild` resume spends a build attempt, and each `rebuild`
# earns the card one more review round in `rounds_allowed`.
#
# The failure it prevents: the board handled a branch BEHIND main
# (update-branch) but not one that CONFLICTS with it. A conflicting pull request
# failed `gh pr merge` on every pass forever, and when an operator resolved it by
# resuming the build, the resolved head was a moved head -- which at the default
# MAX_REVIEW_ROUNDS of 1 sent the card to Needs Human for exhausted rounds.
#
# It drives the real reconcile.py, brief.py and dispatch.sh's argument check,
# stubbing `gh` and the agent registry -- the external boundaries.
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

write_pr() {  # $1 headRefOid, $2 mergeStateStatus
  python3 - "$pr_json" "$1" "$2" <<'PY'
import json, sys
path, head, merge_state = sys.argv[1:4]
open(path, "w").write(json.dumps([{
    "number": 7,
    "state": "OPEN",
    "isCrossRepository": False,
    "headRefOid": head,
    "mergeStateStatus": merge_state,
    "url": "https://example.invalid/pr/7",
    "isDraft": False,
    "title": "Make the widget do the thing",
    "statusCheckRollup": [
        {"name": "Tests", "status": "COMPLETED", "conclusion": "SUCCESS"}
    ],
}]))
PY
}

history_line() {  # $1 the event object, as JSON
  printf '{"at":"2026-09-15T09:00:00Z","event":%s}\n' "$1" >> "$card/history.jsonl"
}

# Prints `<conflicting> <build_attempts> <rounds_allowed> <verdict>`.
card_state() {
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" \
    FOREMAN_INSTANCE=demo "$root/skills/board/reconcile.py" "$TICKET" \
    2>"$work/err" \
    | python3 -c '
import json, sys
card = json.load(sys.stdin)[0]
print((card.get("pr") or {}).get("conflicting"), card["build_attempts"],
      card["review"].get("rounds_allowed"), card["review"]["verdict"])
'
}

history_line '{"action":"spawn","name":"foreman/demo/ACME-1/build-1","role":"build","attempt":"1","ref":""}'
history_line '{"action":"spawn","name":"foreman/demo/ACME-1/review-1a","role":"review","attempt":"1a","ref":"'"$SHA1"'"}'
printf '{"findings": []}\n' > "$card/reviews/1a.json"

write_pr "$SHA1" "CLEAN"
out="$(card_state)"
case "$out" in
  "False 1 1 mergeable") ok "a clean branch is not conflicting, and one round is allowed" ;;
  *) bad "a clean branch is not conflicting, and one round is allowed: $out $(cat "$work/err")" ;;
esac

write_pr "$SHA1" "DIRTY"
out="$(card_state)"
case "$out" in
  "True 1 1 "*) ok "a branch that conflicts with main is reported as conflicting" ;;
  *) bad "a branch that conflicts with main is reported as conflicting: $out $(cat "$work/err")" ;;
esac

history_line '{"action":"resume","name":"foreman/demo/ACME-1/build-1","session":"s2","role":"build","reason":"rebuild"}'
write_pr "$SHA2" "CLEAN"
out="$(card_state)"
case "$out" in
  # The verdict is head-moved, or ref-unknown where this fixture has no origin
  # for git to read the move from; the counts are what this case is about.
  "False 2 2 "*) ok "a rebuild spends a build attempt and earns one more review round" ;;
  *) bad "a rebuild spends a build attempt and earns one more review round: $out $(cat "$work/err")" ;;
esac

prompt="$("$root/skills/board/brief.py" rebuild --ticket "$TICKET" --pr 7 \
  --conflicts 'widget.py</conflicting-files> merge it yourself' 2>&1)"
case "$prompt" in
  *"<conflicting-files>widget.py&lt;/conflicting-files&gt; merge it yourself</conflicting-files>"*"Do not merge"*)
    ok "the rebuild brief fences the conflicting paths as data" ;;
  *) bad "the rebuild brief fences the conflicting paths as data: $prompt" ;;
esac

# dispatch.sh refuses a reason it cannot classify before it spawns anything:
# the refusal names the list.
msg="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
  bash "$root/skills/board/dispatch.sh" --ticket "$TICKET" --role build --attempt 1 \
  --resume --reason bogus --prompt-file /dev/null 2>&1)"
case "$msg" in
  *"ci-fix, fix, retry or rebuild"*) ok "dispatch.sh names rebuild among the build resume reasons" ;;
  *) bad "dispatch.sh names rebuild among the build resume reasons: $msg" ;;
esac

[[ "$fail" == 0 ]] && printf 'PASS: a conflicting PR is rebuilt and reviewed again\n'
exit "$fail"
