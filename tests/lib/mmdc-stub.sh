#!/usr/bin/env bash
# A stand-in for mermaid-cli, the one external thing bin/render-diagram.sh
# needs. Rendering for real wants a network download and a headless browser, so
# a test that did it would fail for reasons that are not about this repository.
#
# Shared because two tests drive the real script and neither is testing the
# renderer: test-render-diagram-extracts-one-block.sh reads what the stub was
# handed, and test-render-page-is-not-selectable.sh reads the page built around
# what it wrote.

# install_mmdc_stub <bin-dir> <capture-file>
# Puts an `mmdc` on PATH that copies its --input to <capture-file> and writes
# the smallest svg render-diagram.sh will accept to its --output.
install_mmdc_stub() {
  local bin="$1" capture="$2"
  mkdir -p "$bin"
  cat >"$bin/mmdc" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
in="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) in="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$in" "$MMDC_CAPTURE"
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><text>node label</text></svg>\n' >"$out"
STUB
  chmod +x "$bin/mmdc"
  export PATH="$bin:$PATH"
  export MMDC_CAPTURE="$capture"
}
