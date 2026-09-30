#!/usr/bin/env bash
# Claim: a review finding blocks unless its severity is one `severity.py` knows
# does not block. Case and spacing do not matter, and a finding that is not an
# object blocks.
#
# The failure it prevents: `reconcile.py` counted a finding as blocking only
# when its severity was exactly "blocking". The reviewer's own skill grades
# CRITICAL, WARNING and NOTE, so a reviewer that wrote "Blocking", "critical"
# or "high", or left severity out, filed a real defect that counted as nothing,
# and the round read as clean. A note read as blocking costs one fix; a
# blocking finding read as a note merges the defect.
#
# It drives the real script. Only `gh` and `claude` are stubbed; the review
# file and the history are real files where the board writes them.
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
printf '{"at":"2026-09-30T09:00:00Z","event":{"action":"spawn","name":"foreman/demo/%s/review-1a","role":"review","attempt":"1a","ref":"%s"}}\n' \
  "$TICKET" "$SHA" > "$card/history.jsonl"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
# The head is the sha the round read, so nothing about the verdict turns on a
# head move: only the findings decide it.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  printf '[{"number":7,"state":"OPEN","isCrossRepository":false,"headRefOid":"$SHA","statusCheckRollup":[]}]\n'
  exit 0
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

# $1 claim, $2 wanted `<verdict> <blocking count>`, $3 the findings list as JSON
review_of() {
  printf '{"findings": %s}\n' "$3" > "$card/reviews/1a.json"
  local got
  got="$(env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" "$TICKET" 2>"$work/err" \
    | python3 -c '
import json, sys
review = json.load(sys.stdin)[0]["review"]
print(review["verdict"], review["blocking"])
')"
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1: wanted [$2], got [$got] $(cat "$work/err")"
}

review_of "a capitalised Blocking blocks" "needs-fix 1" '[{"severity": "Blocking"}]'
review_of "critical blocks" "needs-fix 1" '[{"severity": "critical"}]'
review_of "high blocks" "needs-fix 1" '[{"severity": "high"}]'
review_of "a severity nobody has seen blocks" "needs-fix 1" '[{"severity": "urgent-ish"}]'
review_of "a finding with no severity blocks" "needs-fix 1" '[{"summary": "s"}]'
review_of "a finding that is not an object blocks" "needs-fix 1" '["the build is broken"]'
review_of "note, warning, nit and a spaced Minor do not block" "mergeable 0" \
  '[{"severity": "note"}, {"severity": "warning"}, {"severity": "nit"}, {"severity": " Minor "}]'
review_of "one blocking finding among notes is counted once" "needs-fix 1" \
  '[{"severity": "note"}, {"severity": "BLOCKING"}]'

[[ "$fail" -eq 0 ]] && printf 'PASS: only a known non-blocking severity lets a round through\n'
exit "$fail"
