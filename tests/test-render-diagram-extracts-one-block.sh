#!/usr/bin/env bash
# Claim: render-diagram.sh hands the renderer the FIRST mermaid block and
# nothing else, and refuses a file with none.
#
# The extraction is the part that fails silently. A matcher that missed the
# closing fence would hand the renderer the rest of the document -- prose,
# tables, a second diagram -- and mermaid-cli would either draw nonsense or fail
# with an error about markdown that nobody would trace back to here.
#
# The renderer is stubbed at the external boundary, the way tests/lib/
# linear-stub.py stubs Linear, so this drives the real script rather than a copy
# of its awk. An earlier version of this test reimplemented the extraction
# inline and asserted against that: it would have stayed green while the script
# itself was broken, which is the same defect as asserting on a mock.
#
# What is deliberately NOT covered: rendering. That needs a network download and
# a headless browser, and a test that reaches the network fails for reasons that
# are not about this repository.
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

if out="$(bash "$ROOT/bin/render-diagram.sh" "$WORK/two.md" "$WORK/two.html" 2>&1)"; then
  got="$(cat "$MMDC_CAPTURE")"
  [[ "$got" == "flowchart TD"$'\n'"  a --> b" ]] \
    && ok "the renderer receives the first block and nothing after its fence" \
    || bad "renderer received: $got"
  [[ -s "$WORK/two.html" ]] && grep -q '<svg' "$WORK/two.html" \
    && ok "the page embeds the rendered svg" \
    || bad "no svg in the page"
  grep -q 'flowchart LR' "$MMDC_CAPTURE" \
    && bad "the second block leaked into the render" \
    || ok "the second block is not rendered"
else
  bad "failed on a valid file: $out"
fi

printf '# no diagram here\n\njust prose.\n' >"$WORK/none.md"
if out="$(bash "$ROOT/bin/render-diagram.sh" "$WORK/none.md" "$WORK/none.html" 2>&1)"; then
  bad "did not refuse a file with no mermaid block"
else
  case "$out" in
    *"no \`\`\`mermaid block"*) ok "refuses a file with no mermaid block" ;;
    *) bad "refused for the wrong reason: $out" ;;
  esac
fi

if out="$(bash "$ROOT/bin/render-diagram.sh" 2>&1)"; then
  bad "did not refuse a missing argument"
else
  case "$out" in *usage*) ok "refuses a missing argument" ;; *) bad "$out" ;; esac
fi

if out="$(bash "$ROOT/bin/render-diagram.sh" "$WORK/two.md" "$WORK/x.png" 2>&1)"; then
  bad "did not refuse a non-html output"
else
  case "$out" in *".html"*) ok "refuses an output that is not .html" ;; *) bad "$out" ;; esac
fi

exit "$fail"
