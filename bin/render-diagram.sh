#!/usr/bin/env bash
# Render a mermaid diagram to a page you can look at.
#
#   bin/render-diagram.sh docs/board-flow.md          # -> docs/board-flow.html
#   bin/render-diagram.sh docs/board-flow.md /tmp/x.html
#   bin/render-diagram.sh diagram.mmd
#
# The mermaid in the markdown is the source. The page is a view, and .gitignore
# keeps it out of the repository -- a committed render is a second copy of one
# fact, and it goes stale the first time nobody re-runs this.
#
# HTML only, deliberately. A bare SVG cannot be zoomed in any file preview, and
# a PNG blurs past the scale it was rendered at; a drawing this size is
# unreadable at fit-to-window either way. Both existed here and both were worse
# than the page, so both are gone rather than kept as options nobody should pick.
#
# Why extract the block instead of handing the .md to mermaid-cli: given
# `-i foo.md -o out.svg` it writes `out-1.svg` and never the path it was asked
# for. A script whose output path is a suggestion is one every caller has to
# guess at.
set -euo pipefail

die() { printf 'render-diagram: %s\n' "$*" >&2; exit 1; }

SRC="${1:-}"
[[ -n "$SRC" ]] || die "usage: render-diagram.sh <file.md|file.mmd> [out.html]"
[[ -r "$SRC" ]] || die "cannot read $SRC"
OUT="${2:-${SRC%.*}.html}"
[[ "$OUT" == *.html ]] || die "output must end in .html, got $OUT"

if command -v mmdc >/dev/null 2>&1; then
  RENDER=(mmdc)
elif command -v npx >/dev/null 2>&1; then
  # Worded to stay true on a cached run, which takes about five seconds. This
  # line prints every time and must not read as "downloading now".
  printf 'render-diagram: using npx. If mermaid-cli is not cached this downloads ~150MB and takes minutes.\n' >&2
  RENDER=(npx -y @mermaid-js/mermaid-cli)
else
  die "no mermaid renderer found. Install one:
  npm install -g @mermaid-js/mermaid-cli
or make npx available on PATH."
fi

# Render-time styling. Refuse rather than silently produce the clipped cluster
# labels that file exists to prevent.
CSS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/diagram.css"
[[ -r "$CSS" ]] || die "missing $CSS; renders would clip their cluster labels"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BLOCK="$WORK/diagram.mmd"
SVG="$WORK/diagram.svg"

if [[ "$SRC" == *.mmd ]]; then
  cp "$SRC" "$BLOCK"
else
  # First ```mermaid fence only. awk rather than sed so a file with no fence
  # produces an empty file and the check below fires, instead of silently
  # rendering the whole document as if it were mermaid.
  awk '/^```mermaid[[:space:]]*$/{f=1;next} /^```[[:space:]]*$/{if(f)exit} f' \
    "$SRC" >"$BLOCK"
  [[ -s "$BLOCK" ]] || die "no \`\`\`mermaid block in $SRC"
fi

"${RENDER[@]}" --input "$BLOCK" --output "$SVG" --backgroundColor white \
  --cssFile "$CSS" >/dev/null || die "mermaid-cli failed on $SRC"
[[ -s "$SVG" ]] || die "renderer reported success but wrote nothing"

# mermaid caps the root element at `max-width: <diagram width>px`, so the
# drawing would refuse to grow past its natural size. The page overrides it in
# CSS below rather than editing the SVG, so there is one place that decides how
# the drawing is sized.
#
# Nothing on the page is selectable. A drag on the stage means pan, and the
# browser answers that same drag by selecting the labels under the pointer: the
# drawing ends up striped with highlight and every later drag starts from the
# selection instead of the diagram. The copyable form of the drawing is the
# mermaid block this page was rendered from.
{
  printf '<!doctype html><meta charset="utf-8"><title>%s</title>\n' \
    "$(basename "${SRC%.*}")"
  cat <<'PAGE'
<style>
  html,body{margin:0;height:100%;background:#f8fafc;font:13px ui-sans-serif,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#334155;
            -webkit-user-select:none;user-select:none}
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
  button:focus-visible{outline:2px solid #2563eb;outline-offset:1px}
  #pct{min-width:44px;text-align:right;font-variant-numeric:tabular-nums;color:#64748b}
  kbd{font:inherit;color:#94a3b8}
</style>
<div id="stage"><div id="art">
PAGE
  cat "$SVG"
  cat <<'PAGE'
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
  document.getElementById('one').onclick=function(){zoom(1/s,innerWidth/2,innerHeight/2);};
  addEventListener('resize',fit);fit();
</script>
PAGE
} >"$OUT"

printf '%s\n' "$OUT"
