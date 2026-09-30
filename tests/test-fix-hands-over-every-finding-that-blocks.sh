#!/usr/bin/env bash
# `brief.py fix` chose its findings with `severity == "blocking"`, while
# reconcile.py decides a round blocked through severity.is_blocking. A reviewer
# that wrote "Blocking" or "critical" blocked the round in reconcile.py and
# then reached the fix agent as "no blocking findings; nothing to fix", so the
# fix was never dispatched. Both now read one rule, and this pins it at the
# prompt: every finding that blocks reaches the fix agent, and a note does not.
#
# It also pins the two malformed inputs that used to end the tick with a
# Python traceback instead of a sentence: a findings file holding a JSON list,
# and a replan comments file whose entries are not objects.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
brief="$root/skills/board/brief.py"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

cat > "$work/findings.json" <<'JSON'
{"findings": [
  {"severity": "Blocking", "file": "a.py", "line": 3, "summary": "CAPSMARKER", "failure": "f"},
  {"severity": "critical", "file": "b.py", "summary": "CRITMARKER", "failure": "f"},
  {"file": "c.py", "summary": "NOSEVMARKER", "failure": "f"},
  "UNSTRUCTUREDMARKER",
  {"severity": "note", "file": "d.py", "summary": "NOTEMARKER", "failure": "f"}
]}
JSON

prompt="$("$brief" fix --ticket ACME-5 --findings-file "$work/findings.json")"
for marker in CAPSMARKER CRITMARKER NOSEVMARKER UNSTRUCTUREDMARKER; do
  case "$prompt" in
    *"$marker"*) ok "a blocking finding reaches the fix agent: $marker" ;;
    *) bad "a finding severity.is_blocking counts was left out: $marker
$prompt" ;;
  esac
done
case "$prompt" in
  *NOTEMARKER*) bad "a note reached the fix agent as though it blocked:
$prompt" ;;
  *) ok "a note does not reach the fix agent" ;;
esac

# Refused in a sentence, never with a traceback.
refuses() { # label needle -- brief args...
  local label="$1" needle="$2"; shift 3
  if "$brief" "$@" >/dev/null 2>"$work/err"; then
    bad "$label: rendered a prompt"
  elif grep -q Traceback "$work/err"; then
    bad "$label: died with a traceback:
$(cat "$work/err")"
  elif grep -q -- "$needle" "$work/err"; then
    ok "$label"
  else
    bad "$label: the refusal does not say '$needle':
$(cat "$work/err")"
  fi
}

printf '[{"severity": "blocking"}]\n' > "$work/list.json"
refuses "fix refuses a findings file that is a list" "expected an object" -- \
  fix --ticket ACME-5 --findings-file "$work/list.json"

printf '{"findings": "none"}\n' > "$work/notlist.json"
refuses "fix refuses findings that are not a list" "expected a list" -- \
  fix --ticket ACME-5 --findings-file "$work/notlist.json"

printf '["not an object"]\n' > "$work/comments-list.json"
refuses "replan refuses a comments file that is a list" "expected an object" -- \
  replan --ticket ACME-5 --comments-file "$work/comments-list.json"

printf '{"unconsumed": ["bare text"], "footer": "<!-- foreman:plan round=2 consumed=x -->"}\n' \
  > "$work/comments-bare.json"
refuses "replan refuses an unconsumed entry that is not an object" "must be an object" -- \
  replan --ticket ACME-5 --comments-file "$work/comments-bare.json"

exit "$fail"
