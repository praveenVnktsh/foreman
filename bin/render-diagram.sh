#!/usr/bin/env bash
# Render a mermaid diagram to SVG, for viewing.
#
#   bin/render-diagram.sh docs/board-flow.md            # -> docs/board-flow.svg
#   bin/render-diagram.sh --html docs/board-flow.md     # -> .svg and .html
#   bin/render-diagram.sh docs/board-flow.md /tmp/x.svg
#   bin/render-diagram.sh docs/board-flow.md docs/board-flow.png
#   bin/render-diagram.sh diagram.mmd
#
# The output EXTENSION picks the format. PNG previews in more places than SVG
# does, so it is often the one you actually want to look at; SVG is the one to
# zoom, because a PNG blurs past the scale it was rendered at. PNG is rendered
# at 3x for that reason.
#
# `--html` writes a self-contained page beside the SVG with scroll-to-zoom and
# drag-to-pan. An SVG on its own cannot be zoomed in a file preview, and a
# diagram this size is unreadable at fit-to-window: 1239 x 1536 shrunk into a
# side pane puts 13px type below the size anyone can read.
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

HTML=""
if [[ "${1:-}" == "--html" ]]; then HTML=1; shift; fi

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

# mermaid-cli picks its format from the output extension, so the caller does
# too. A PNG is rendered at 3x: at 1x, 13px labels in a 1239-wide drawing are
# unreadable the moment anything scales them down.
FMT=(); case "$OUT" in
  *.png) FMT=(--scale 3) ;;
  *.svg) ;;
  *) die "output must end in .svg or .png, got $OUT" ;;
esac
[[ -z "$HTML" || "$OUT" == *.svg ]] || die "--html needs an .svg output; a page wrapping a PNG cannot be zoomed without blurring"

"${RENDER[@]}" --input "$BLOCK" --output "$OUT" --backgroundColor white \
  ${FMT[@]+"${FMT[@]}"} >/dev/null || die "mermaid-cli failed on $SRC"

[[ -s "$OUT" ]] || die "renderer reported success but wrote nothing to $OUT"

# mermaid-cli caps the root element at `max-width: <diagram width>px`, so the
# drawing refuses to grow past its natural size however wide the container is.
# The viewBox already carries the aspect ratio, so dropping the cap lets it
# scale. Only the root element's cap: the stylesheet further down sets
# `max-width:200px` on node labels, which is what keeps long labels wrapping.
if [[ "$OUT" == *.svg ]]; then
python3 - "$OUT" <<'PYEOF'
import re, sys
path = sys.argv[1]
svg = open(path).read()
head = svg[:600]
fixed = re.sub(r'style="max-width:\s*[0-9.]+px;\s*', 'style="', head, count=1)
open(path, "w").write(fixed + svg[600:])
PYEOF
fi

printf '%s\n' "$OUT"

if [[ -n "$HTML" ]]; then
  PAGE="${OUT%.svg}.html"
  {
    printf '%s' '<!doctype html><meta charset="utf-8"><title>'
    printf '%s' "$(basename "${SRC%.*}")"
    cat <<'PAGEEOF'
</title>
<style>
  html,body{margin:0;height:100%;background:#f8fafc;font:13px ui-sans-serif,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#334155}
  #stage{position:fixed;inset:0;overflow:hidden;cursor:grab}
  #stage.drag{cursor:grabbing}
  #art{transform-origin:0 0;will-change:transform}
  #art svg{display:block;max-width:none!important}
  #bar{position:fixed;left:12px;bottom:12px;display:flex;gap:6px;align-items:center;
       background:#fff;border:1px solid #cbd5e1;border-radius:8px;padding:6px 8px;
       box-shadow:0 1px 3px rgba(15,23,42,.12)}
  button{font:inherit;border:1px solid #cbd5e1;background:#fff;border-radius:6px;
         padding:3px 9px;cursor:pointer;color:#334155}
  button:hover{background:#f1f5f9}
  #pct{min-width:44px;text-align:right;font-variant-numeric:tabular-nums;color:#64748b}
  kbd{font:inherit;color:#94a3b8}
</style>
<div id="stage"><div id="art">
PAGEEOF
    cat "$OUT"
    cat <<'PAGEEOF'
</div></div>
<div id="bar">
  <button id="out">&minus;</button><button id="in">+</button>
  <button id="fit">Fit</button><button id="one">100%</button>
  <span id="pct"></span><kbd>scroll to zoom, drag to pan</kbd>
</div>
<script>
  var stage=document.getElementById('stage'),art=document.getElementById('art'),
      pct=document.getElementById('pct'),svg=art.querySelector('svg'),
      vb=svg.viewBox.baseVal,s=1,x=0,y=0;
  function draw(){art.style.transform='translate('+x+'px,'+y+'px) scale('+s+')';
    pct.textContent=Math.round(s*100)+'%';}
  function fit(){var p=40,k=Math.min((innerWidth-p)/vb.width,(innerHeight-p)/vb.height);
    s=k;x=(innerWidth-vb.width*k)/2;y=(innerHeight-vb.height*k)/2;draw();}
  function zoom(k,cx,cy){var n=Math.min(8,Math.max(0.1,s*k));
    x=cx-(cx-x)*(n/s);y=cy-(cy-y)*(n/s);s=n;draw();}
  svg.removeAttribute('width');svg.removeAttribute('height');
  svg.setAttribute('width',vb.width);svg.setAttribute('height',vb.height);
  stage.addEventListener('wheel',function(e){e.preventDefault();
    zoom(Math.exp(-e.deltaY*0.0015),e.clientX,e.clientY);},{passive:false});
  var dx=0,dy=0,down=false;
  stage.addEventListener('pointerdown',function(e){down=true;dx=e.clientX-x;dy=e.clientY-y;
    stage.classList.add('drag');stage.setPointerCapture(e.pointerId);});
  stage.addEventListener('pointermove',function(e){if(!down)return;
    x=e.clientX-dx;y=e.clientY-dy;draw();});
  stage.addEventListener('pointerup',function(){down=false;stage.classList.remove('drag');});
  document.getElementById('in').onclick=function(){zoom(1.25,innerWidth/2,innerHeight/2);};
  document.getElementById('out').onclick=function(){zoom(0.8,innerWidth/2,innerHeight/2);};
  document.getElementById('fit').onclick=fit;
  document.getElementById('one').onclick=function(){var c=s;zoom(1/c,innerWidth/2,innerHeight/2);};
  addEventListener('resize',fit);fit();
</script>
PAGEEOF
  } >"$PAGE"
  printf '%s\n' "$PAGE"
fi
