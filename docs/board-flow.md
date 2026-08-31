# What the board actually does

One tick, end to end. Line counts are current as of 2026-08-31.

GitHub renders the mermaid below. Nothing else does, so to see it anywhere else:

```bash
bin/render-diagram.sh docs/board-flow.md                    # SVG
bin/render-diagram.sh docs/board-flow.md docs/board-flow.png   # PNG, 3x
bin/render-diagram.sh --html docs/board-flow.md             # zoom and pan
```

The output extension picks the format. Every render is gitignored: the mermaid
above is the source, and a render is a view of it.

- **PNG** previews in the most places, and your image viewer's zoom works on it.
  It blurs past 3x.
- **SVG** stays sharp at any size, but many viewers will not preview it and none
  offer a zoom control.
- **`--html`** wraps the SVG in a page with scroll-to-zoom and drag-to-pan. Open
  it with `open docs/board-flow.html`.

```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "fontFamily": "ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif",
    "fontSize": "13px",
    "lineColor": "#94a3b8",
    "primaryTextColor": "#0f172a",
    "clusterBkg": "#f8fafc",
    "clusterBorder": "#cbd5e1",
    "edgeLabelBackground": "#ffffff"
  },
  "flowchart": { "curve": "basis", "nodeSpacing": 40, "rankSpacing": 55, "padding": 14 }
}}%%
flowchart TD
    cron(["cron"]) --> sup

    sup["<b>supervise.sh</b><br/><small>201 lines</small><br/>watchdog only<br/><i>never dispatches a card</i>"]
    sup -->|"start · restart · recycle"| tick
    tick["<b>tick agent</b><br/><small>SKILL.md · 58KB</small><br/>holds no state<br/><i>re-derives everything</i>"]

    subgraph ONETICK[" ONE TICK "]
        direction TB
        rec["<b>reconcile.py</b><br/><small>1005 lines</small><br/>join Linear · gh · agents<br/><i>what happens to each card</i>"]
        pre["<b>preflight.py</b><br/><small>305 lines</small><br/>can this machine build?"]
        bri["<b>brief.py</b><br/><small>290 lines</small><br/>write the prompt"]
        dis["<b>dispatch.sh</b><br/><small>205 lines</small><br/>worktree · bootstrap · spawn"]
        wai["<b>waitfor.py · watch-agents.py</b><br/><small>272 + 140 lines</small><br/>block until work finishes"]
        swp["<b>sweep.sh</b><br/><small>199 lines</small><br/>reap worktrees"]
        rec -->|"needs an agent"| pre
        pre -->|"fit"| bri
        bri --> dis
        dis --> wai
        wai --> swp
    end

    tick --> rec
    swp -.->|"next tick re-derives"| rec
    pre -->|"unfit"| stop["<b>refuse to dispatch</b><br/><i>not the card's fault</i>"]

    subgraph AGENTS[" DETACHED AGENTS · own worktree "]
        direction LR
        bld["build<br/><small>implement · test · PR</small>"]
        rev["review<br/><small>read the diff</small>"]
        fix["fix<br/><small>answer findings</small>"]
    end
    dis --> bld
    dis --> rev
    dis --> fix

    ev["<b>evidence.sh</b><br/><small>362 lines</small><br/>read what GitHub holds <i>now</i><br/><i>never the working tree</i>"]
    rev -.-> ev
    fix -.-> ev

    subgraph CONFIG[" READ BY EVERYTHING "]
        direction LR
        toml["board.toml<br/><small>the project declares</small>"]
        con["bin/contract.py<br/><small>parsed, never sourced</small>"]
        ids["instance.env · ids.env<br/><small>the machine declares</small>"]
        cfg["config.sh<br/><small>244 lines</small>"]
        toml --> con --> cfg
        ids --> cfg
    end
    cfg -.-> rec

    classDef brain fill:#fff7ed,stroke:#ea580c,stroke-width:2.5px,color:#7c2d12
    classDef gate  fill:#fefce8,stroke:#ca8a04,stroke-width:2px,color:#713f12
    classDef step  fill:#eff6ff,stroke:#93c5fd,stroke-width:1.5px,color:#1e3a5f
    classDef stop  fill:#fef2f2,stroke:#ef4444,stroke-width:2px,color:#7f1d1d
    classDef cfgn  fill:#f0fdf4,stroke:#86efac,stroke-width:1.5px,color:#14532d
    classDef agent fill:#f5f3ff,stroke:#c4b5fd,stroke-width:1.5px,color:#4c1d95
    classDef edge  fill:#f8fafc,stroke:#cbd5e1,stroke-width:1.5px,color:#334155

    class rec brain
    class pre,ev gate
    class bri,dis,wai,swp step
    class sup,tick,cron edge
    class stop stop
    class toml,con,ids,cfg cfgn
    class bld,rev,fix agent

    linkStyle default stroke:#94a3b8,stroke-width:1.5px
```

## Three things the diagram shows that a file list does not

- **`supervise.sh` deliberately cannot dispatch.** A watchdog that could also
  dispatch would double-dispatch the moment it misjudged liveness. That
  separation is why it is a whole file and not a function.
- **`waitfor.py` and `watch-agents.py` share one box** because they do one job
  between them. This is the clearest merge in the skill.
- **The dotted line from `sweep.sh` back to `reconcile.py` is the whole design.**
  Nothing is carried between ticks. The next tick rebuilds the picture from
  Linear, `gh` and `claude agents`. That is why there is no state file, and why
  the sidecar is a cache and never truth.

## Where the weight is

| File | Lines | Verdict |
|---|---:|---|
| `reconcile.py` | 1005 | Where the complexity lives. 23% of the skill. |
| `evidence.sh` | 362 | Keep. Exists because the working tree gave wrong answers. |
| `preflight.py` | 305 | Keep the idea. The implementation looks larger than the job. |
| `brief.py` | 290 | Keep. Small, one job. |
| `waitfor.py` | 272 | Merge candidate. |
| `config.sh` | 244 | Keep. It is the config. |
| `dispatch.sh` | 205 | Keep. One job. |
| `supervise.sh` | 201 | Keep. Separate from dispatch on purpose. |
| `sweep.sh` | 199 | Could be a step in the tick rather than its own script. |
| `watch-agents.py` | 140 | Merge candidate, with `waitfor.py`. |
| `withlock.py` | 84 | Fine. Tiny. |

Twelve files, but the count is not the problem.

- Six do real work in a tick. The rest are config, a lock and a watchdog.
- The two merges above save roughly 200 lines and take the count to ten.
- The real weight is `reconcile.py` at 1005 lines and `SKILL.md` at 58KB. `SKILL.md`
  is larger than any code file in this repository.
