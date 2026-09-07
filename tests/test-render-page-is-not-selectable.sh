#!/usr/bin/env bash
# Claim: the page render-diagram.sh writes offers no selectable text.
#
# The page pans by pointer drag. Without this the browser answers the same drag
# by selecting the labels under it, so the diagram fills with highlight and the
# next drag extends the selection instead of moving the drawing. The stage, the
# svg and the toolbar are all covered, because a selection started anywhere runs
# across the rest.
#
# The assertion is on the css the page carries, not on a browser: the rule is
# the whole mechanism, and nothing in this repository runs a browser. It reads
# both spellings -- Safari serves `-webkit-user-select` and nothing else.
#
# The stub renderer writes an svg with text in it, so the page under test holds
# the thing that used to be selectable.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# shellcheck source=lib/mmdc-stub.sh
. "$ROOT/tests/lib/mmdc-stub.sh"
install_mmdc_stub "$WORK/bin" "$WORK/captured.mmd"

cat >"$WORK/one.md" <<'MD'
```mermaid
flowchart TD
  a --> b
```
MD

if out="$(bash "$ROOT/bin/render-diagram.sh" "$WORK/one.md" "$WORK/one.html" 2>&1)"; then
  # The declarations sit on `html,body`, so every element inherits them: the
  # svg text, the buttons and the hint in the toolbar.
  rule="$(tr -d ' \n' <"$WORK/one.html" | grep -o 'html,body{[^}]*}' || true)"
  case "$rule" in
    *"user-select:none"*) ok "the page blocks text selection" ;;
    *) bad "no user-select:none on html,body; got: ${rule:-nothing}" ;;
  esac
  case "$rule" in
    *"-webkit-user-select:none"*) ok "it blocks selection in safari too" ;;
    *) bad "no -webkit-user-select:none on html,body; got: ${rule:-nothing}" ;;
  esac
  grep -q '<text>node label</text>' "$WORK/one.html" \
    && ok "the drawing's text is on the page the rule covers" \
    || bad "the rendered svg text is missing, so the rule covers nothing"
else
  bad "render-diagram.sh failed on a valid file: $out"
fi

exit "$fail"
