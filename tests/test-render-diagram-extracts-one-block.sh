#!/usr/bin/env bash
# Claim: render-diagram.sh takes the FIRST mermaid block and refuses a file with
# none.
#
# The extraction is the part that fails silently. A sloppy matcher that missed
# the closing fence would hand the renderer the rest of the document -- prose,
# tables, a second diagram -- and mermaid-cli would either draw nonsense or fail
# with an error about markdown that nobody would trace back to here.
#
# The renderer itself is not exercised: it needs a network download and a
# headless browser, and a test that reaches the network is a test that fails for
# reasons that are not about this repository.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

ok()  { printf 'ok  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

extract() {
  awk '/^```mermaid[[:space:]]*$/{f=1;next} /^```[[:space:]]*$/{if(f)exit} f' "$1"
}

cat >"$WORK/two.md" <<'MD'
# Title

Prose that must not be rendered.

```mermaid
flowchart TD
  a --> b
```

More prose, and a table.

```mermaid
flowchart LR
  x --> y
```
MD

got="$(extract "$WORK/two.md")"
[[ "$got" == "flowchart TD"$'\n'"  a --> b" ]] \
  && ok "takes the first block and stops at its closing fence" \
  || bad "extracted: $got"

printf '# no diagram here\n\njust prose.\n' >"$WORK/none.md"
[[ -z "$(extract "$WORK/none.md")" ]] \
  && ok "a file with no mermaid block extracts nothing" \
  || bad "extracted something from a file with no block"

if out="$(bash "$ROOT/bin/render-diagram.sh" "$WORK/none.md" 2>&1)"; then
  bad "did not refuse a file with no mermaid block"
else
  case "$out" in
    *"no \`\`\`mermaid block"*) ok "refuses a file with no mermaid block" ;;
    *) bad "refused, but for the wrong reason: $out" ;;
  esac
fi

if out="$(bash "$ROOT/bin/render-diagram.sh" 2>&1)"; then
  bad "did not refuse a missing argument"
else
  case "$out" in *usage*) ok "refuses a missing argument" ;; *) bad "$out" ;; esac
fi

exit "$fail"
