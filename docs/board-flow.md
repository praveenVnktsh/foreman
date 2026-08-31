# What the board actually does

One tick, end to end. Line counts are current as of 2026-08-31.

GitHub renders the mermaid below. Nothing else does, so to see it anywhere else:

```bash
bin/render-diagram.sh docs/board-flow.md
```

That writes `docs/board-flow.svg`, which is gitignored. The mermaid is the
source; an SVG is a view of it.

```mermaid
flowchart TD
    cron(["cron"]) --> sup

    sup["<b>supervise.sh</b> · 201<br/>watchdog only<br/>guarantees exactly one tick alive<br/><i>never dispatches a card</i>"]
    sup -->|"starts · restarts · recycles"| tick

    tick["<b>tick agent</b><br/>claude --bg '/loop /board'<br/>driven by SKILL.md · 58KB<br/><i>holds no state, re-derives everything</i>"]

    subgraph ONETICK["ONE TICK"]
        direction TB
        rec["<b>reconcile.py</b> · 1005<br/>join Linear + gh + claude agents<br/>→ what should happen to each card"]
        pre["<b>preflight.py</b> · 305<br/>can this machine build at all?<br/>disk · quota · real write probes"]
        bri["<b>brief.py</b> · 290<br/>write the prompt<br/>build | review | fix | ci-fix"]
        dis["<b>dispatch.sh</b> · 205<br/>cut worktree · bootstrap · spawn"]
        wait["<b>waitfor.py</b> · 272<br/><b>watch-agents.py</b> · 140<br/>block until the work finishes"]
        swp["<b>sweep.sh</b> · 199<br/>reap worktrees and scratch"]

        rec -->|"card needs an agent"| pre
        pre -->|"machine is fit"| bri
        bri --> dis
        dis --> wait
        wait --> swp
    end

    tick --> rec
    swp -.->|"next tick re-derives from scratch"| rec

    pre -->|"machine is unfit"| unfit["<b>refuse to dispatch</b><br/>not the card's fault<br/>do not spend a build attempt"]

    dis --> agents["spawned agent"]

    subgraph AGENTS["DETACHED AGENTS · own worktree · permissions bypassed"]
        direction LR
        build["build<br/>implement · test · open PR"]
        review["review<br/>read the diff"]
        fix["fix<br/>answer blocking findings"]
    end

    agents --> build
    agents --> review
    agents --> fix

    ev["<b>evidence.sh</b> · 362<br/>read a file as GitHub holds it NOW<br/>fetches, then answers<br/><i>never the working tree</i>"]
    review -.->|"verify a claim"| ev
    fix -.->|"refute a finding"| ev

    subgraph CONFIG["READ BY EVERYTHING"]
        direction LR
        toml["board.toml<br/><i>what the project declares</i>"]
        contract["bin/contract.py<br/>parsed, never sourced"]
        inst["instance.env · ids.env<br/><i>what the machine declares</i>"]
        cfg["config.sh · 244"]
        toml --> contract --> cfg
        inst --> cfg
    end

    CONFIG -.-> ONETICK
    lock["withlock.py · 84<br/>serialise shared git metadata"]
    dis -.-> lock

    classDef brain fill:#7c2d12,stroke:#ea580c,color:#fff
    classDef gate fill:#713f12,stroke:#eab308,color:#fff
    classDef plain fill:#1e3a5f,stroke:#3b82f6,color:#fff
    classDef bad fill:#7f1d1d,stroke:#ef4444,color:#fff
    classDef cfg fill:#14532d,stroke:#22c55e,color:#fff

    class rec brain
    class pre,ev gate
    class bri,dis,wait,swp,sup,tick,lock,agents plain
    class unfit bad
    class toml,contract,inst,cfg cfg
    class build,review,fix plain
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
