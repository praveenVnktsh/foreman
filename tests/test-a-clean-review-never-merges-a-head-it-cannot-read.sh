#!/usr/bin/env bash
# Claim: a clean review round is `mergeable` only when the pull request head
# can be read AND equals a sha the round recorded. A round with no recorded
# ref, a failed `gh pr list`, or no pull request at all is `ref-unknown`: wait,
# never merge.
#
# The failure it prevents: the clean path compared the head with the ref only
# to ask "did it move?", and an unknown on either side answered "no". So a
# legacy round with no ref, a transient `gh` failure, or a card whose pull
# request could not be found each read as `mergeable`, and the tick went to
# merge a head no reviewer was shown. The blocking path already refused that
# reading (see test-review-single-round.sh); this is the same rule for the
# clean one.
#
# It drives the real script. Only `gh` and `claude` are stubbed.
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
SHA="1111111111111111111111111111111111111111"
home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"
card="$fh/instances/demo/cards/$TICKET"
mkdir -p "$card/reviews"
printf '{"findings": [{"severity": "note", "summary": "s"}]}\n' > "$card/reviews/1a.json"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
# `gh pr list` prints whatever $work/prs holds, and exits 1 when it holds
# nothing at all -- the shape of a GitHub that did not answer.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  [[ -s "$work/prs" ]] || exit 1
  cat "$work/prs"; exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then echo README.md; exit 0; fi
exit 1
STUB
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

open_pr='[{"number":7,"state":"OPEN","isCrossRepository":false,"headRefOid":"'"$SHA"'","statusCheckRollup":[]}]'

round() {  # $1 the ref the round recorded, "" for none
  if [[ -n "$1" ]]; then
    printf '{"at":"2026-09-30T09:00:00Z","event":{"action":"spawn","name":"foreman/demo/%s/review-1a","role":"review","attempt":"1a","ref":"%s"}}\n' \
      "$TICKET" "$1" > "$card/history.jsonl"
  else
    printf '{"at":"2026-09-30T09:00:00Z","event":{"action":"spawn","name":"foreman/demo/%s/review-1a","role":"review","attempt":"1a"}}\n' \
      "$TICKET" > "$card/history.jsonl"
  fi
}

expect() {  # $1 claim, $2 wanted `<verdict> <merge_head or ->`
  local got
  got="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$TICKET" 2>"$work/err" \
    | python3 -c '
import json, sys
review = json.load(sys.stdin)[0]["review"]
print(review["verdict"], review.get("merge_head") or "-")
')"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

round "$SHA"; printf '%s\n' "$open_pr" > "$work/prs"
expect "a clean round at a head it can read merges that head" "mergeable $SHA"

round ""; printf '%s\n' "$open_pr" > "$work/prs"
expect "a clean round that recorded no ref waits" "ref-unknown -"

round "$SHA"; : > "$work/prs"
expect "a clean round whose pull request lookup failed waits" "ref-unknown -"

round "$SHA"; printf '[]\n' > "$work/prs"
expect "a clean round on a card with no pull request waits" "ref-unknown -"

[[ "$fail" -eq 0 ]] && printf 'PASS: a clean review merges only a head it can read\n'
exit "$fail"
