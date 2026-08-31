#!/usr/bin/env bash
# Render a mermaid diagram to SVG, for viewing.
#
#   bin/render-diagram.sh docs/board-flow.md            # -> docs/board-flow.svg
#   bin/render-diagram.sh docs/board-flow.md /tmp/x.svg
#   bin/render-diagram.sh diagram.mmd
#
# The mermaid in the markdown is the source. The SVG is a view, and .gitignore
# keeps it out of the repository -- a committed render is a second copy of one
# fact, and it goes stale the first time nobody re-runs this.
#
# Why extract the block instead of handing the .md to mermaid-cli directly:
# mermaid-cli given `-i foo.md -o out.svg` writes `out-1.svg`, `out-2.svg`, one
# per block, and never writes the path it was asked for. A script whose output
# path is a suggestion is a script every caller has to guess at, so this one
# takes the first block and writes exactly where it was told.
set -euo pipefail

die() { printf 'render-diagram: %s\n' "$*" >&2; exit 1; }

SRC="${1:-}"
[[ -n "$SRC" ]] || die "usage: render-diagram.sh <file.md|file.mmd> [out.svg]"
[[ -r "$SRC" ]] || die "cannot read $SRC"
OUT="${2:-${SRC%.*}.svg}"

# A renderer, or a clear refusal. Never a half-render.
if command -v mmdc >/dev/null 2>&1; then
  RENDER=(mmdc)
elif command -v npx >/dev/null 2>&1; then
  # An uncached mermaid-cli pulls a headless browser, roughly 150MB, and takes
  # minutes. Say so rather than appearing to hang with no output. Worded to stay
  # true on a cached run, which takes about five seconds: this line prints every
  # time and must not read as "downloading now".
  printf 'render-diagram: using npx. If mermaid-cli is not cached this downloads ~150MB and takes minutes.\n' >&2
  RENDER=(npx -y @mermaid-js/mermaid-cli)
else
  die "no mermaid renderer found. Install one:
  npm install -g @mermaid-js/mermaid-cli
or make npx available on PATH."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BLOCK="$WORK/diagram.mmd"

if [[ "$SRC" == *.mmd ]]; then
  cp "$SRC" "$BLOCK"
else
  # First ```mermaid fence only. awk rather than sed -n '/,/p' so a file with no
  # fence produces an empty file and the check below fires, instead of silently
  # rendering the whole document as if it were mermaid.
  awk '/^```mermaid[[:space:]]*$/{f=1;next} /^```[[:space:]]*$/{if(f)exit} f' \
    "$SRC" >"$BLOCK"
  [[ -s "$BLOCK" ]] || die "no \`\`\`mermaid block in $SRC"
fi

"${RENDER[@]}" --input "$BLOCK" --output "$OUT" --backgroundColor white \
  >/dev/null || die "mermaid-cli failed on $SRC"

[[ -s "$OUT" ]] || die "renderer reported success but wrote nothing to $OUT"
printf '%s\n' "$OUT"
