# What the board actually does

One tick, end to end. Line counts are current as of 2026-09-08.

GitHub renders the mermaid below. Nothing else does, so to read it anywhere
else:

```bash
bin/render-diagram.sh docs/board-flow.md && open docs/board-flow.html
```

That writes a self-contained page: scroll to zoom, drag to pan. It is gitignored.
The mermaid is the source; the page is a view of it.

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

    sup["<b>supervise.sh</b><br/><small>278 lines</small><br/>watchdog only<br/><i>never dispatches a card</i>"]
    sup -->|"start · restart · recycle"| tick
    tick["<b>tick agent</b><br/><small>SKILL.md · 95KB</small><br/>holds no state<br/><i>re-derives everything</i>"]

    subgraph ONETICK[" ONE TICK "]
        direction TB
        rec["<b>reconcile.py</b><br/><small>1550 lines</small><br/>join Linear · gh · agents<br/><i>what happens to each card</i>"]
        pre["<b>preflight.py</b><br/><small>420 lines</small><br/>can this machine build?"]
        bri["<b>brief.py</b><br/><small>362 lines</small><br/>write the prompt"]
        dis["<b>dispatch.sh</b><br/><small>316 lines</small><br/>worktree · bootstrap · spawn"]
        wai["<b>waitfor.py · watch-agents.py</b><br/><small>272 + 157 lines</small><br/>block until work finishes"]
        swp["<b>sweep.sh</b><br/><small>278 lines</small><br/>reap worktrees · forget sessions"]
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
        pln["plan<br/><small>draw the graph · post it</small><br/><i>a comment on the card is what moves it out of Plan; no push, no PR</i>"]
        bld["build<br/><small>implement · test · PR</small><br/><i>dispatched fresh from origin/main, plan text embedded in the brief · a fix is this same session resumed with findings, not a separate role</i>"]
        rev["review<br/><small>read the diff</small>"]
        cln["cleanup<br/><small>read main, file one planned card</small><br/><i>never pushes</i>"]
    end
    dis --> pln
    dis --> bld
    dis --> rev
    dis --> cln

    ev["<b>evidence.sh</b><br/><small>362 lines</small><br/>read what GitHub holds <i>now</i><br/><i>never the working tree</i>"]
    rev -.-> ev
    bld -.-> ev
    cln -.-> ev

    subgraph CONFIG[" READ BY EVERYTHING "]
        direction LR
        toml["board.toml<br/><small>the project declares</small>"]
        con["bin/contract.py<br/><small>parsed, never sourced</small>"]
        ids["instance.env · ids.env<br/><small>the machine declares</small>"]
        cfg["config.sh<br/><small>388 lines</small>"]
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
    class pln,bld,rev,cln agent

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
- **`rev` runs once.** A blocking finding buys one fix and no re-review; quality
  work that used to wait for a second round now runs in `cln` instead.

## Where the weight is

| File | Lines | Verdict |
|---|---:|---|
| `reconcile.py` | 1550 | Where the complexity lives. 35% of the skill. |
| `evidence.sh` | 362 | Keep. Exists because the working tree gave wrong answers. |
| `brief.py` | 362 | Keep. Small, one job. |
| `preflight.py` | 420 | Keep the idea. The implementation looks larger than the job. |
| `config.sh` | 388 | Keep. It is the config. |
| `dispatch.sh` | 316 | Keep. One job. |
| `supervise.sh` | 278 | Keep. Separate from dispatch on purpose. |
| `sweep.sh` | 278 | Could be a step in the tick rather than its own script. |
| `waitfor.py` | 272 | Merge candidate. |
| `watch-agents.py` | 157 | Merge candidate, with `waitfor.py`. |
| `withlock.py` | 84 | Fine. Tiny. |

Twelve files, but the count is not the problem.

- Six do real work in a tick. The rest are config, a lock and a watchdog.
- The two merges above save roughly 200 lines and take the count to ten.
- The real weight is `reconcile.py` at 1550 lines and `SKILL.md` at 95KB. `SKILL.md`
  is larger than any code file in this repository.
