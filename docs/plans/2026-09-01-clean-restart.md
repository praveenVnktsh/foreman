```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "fontFamily": "Arial, Helvetica, sans-serif",
    "fontSize": "13px",
    "lineColor": "#94a3b8",
    "primaryTextColor": "#0f172a",
    "clusterBkg": "#f8fafc",
    "clusterBorder": "#cbd5e1"
  },
  "flowchart": { "curve": "basis", "nodeSpacing": 38, "rankSpacing": 55, "padding": 14 }
}}%%
flowchart TD

  subgraph OUT["OUTSIDE THE SYSTEM"]
    direction LR
    sysd["systemd --user<br/>runs the watchdog on a timer<br/>kills a unit's cgroup when it deactivates"]
    reg["claude agents registry<br/>ONE flat list for the whole machine<br/>outlives every session"]
    daemon["claude daemon<br/>parent of every dispatched agent<br/>started by whoever runs claude first"]
    forge["Linear, GitHub, target repositories<br/>where a card's real position lives"]
  end

  subgraph CODE["THE INSTALL · ~/.foreman/install"]
    direction TB
    cfg["<b>c1 · skills/board/config.sh</b> · CHANGE<br/>declares the tick's knobs<br/>adds TICK_DRAIN_SECONDS and TICK_START_TIMEOUT_SECONDS<br/>the two bounds a restart waits against<br/><i>opus · high</i>"]
    sup["<b>c2 · skills/board/supervise.sh</b> · CHANGE<br/>owns the tick's whole lifecycle<br/>gains --restart: drain, stop the tick, start one, confirm it<br/>--stop and --restart move under the machine lock<br/><i>opus · xhigh</i>"]
    inst["<b>c3 · bin/install-service.sh</b> · CHANGE<br/>writes foreman.service and foreman.timer<br/>adds KillMode=process so deactivating the unit<br/>never reaps the daemon sharing its cgroup<br/><i>opus · high</i>"]
    skill["<b>c4 · skills/board/SKILL.md</b> · CHANGE<br/>the tick's own instructions<br/>documents the restart gesture and what it does not touch<br/><i>opus · high</i>"]
    agents["<b>c5 · AGENTS.md</b> · CHANGE<br/>what to use for what<br/>one row: restart the tick<br/><i>sonnet · medium</i>"]
    disp["<b>skills/board/dispatch.sh</b><br/>spawns one agent per card<br/>parented to the daemon, not to the tick"]
    sweep["<b>skills/board/sweep.sh</b><br/>reaps a worktree only when its agent<br/>is positively stopped"]
  end

  subgraph RUN["MACHINE RUNTIME"]
    direction TB
    lock["<b>~/.foreman/supervise.lock</b><br/>machine-level flock<br/>serialises every check-and-spawn"]
    tick["<b>foreman/tick</b><br/>ONE agent for every board<br/>holds no state; re-derives everything"]
    card["<b>foreman/&lt;board&gt;/build/&lt;ticket&gt;-&lt;n&gt;</b><br/>an in-flight card's agent<br/>and the worktree it is building in"]
    cards["<b>instances/&lt;board&gt;/cards/</b><br/>history.jsonl per card<br/>a cache, never truth"]
  end

  sysd -->|fires on a timer| sup
  inst -->|writes the unit systemd runs| sysd
  cfg -->|sourced by| sup
  sup -->|takes before deciding| lock
  sup -->|inspects, stops and starts by name| tick
  sup -->|reads liveness from| reg
  tick -->|runs a slice per board through| skill
  tick -->|spawns card agents via| disp
  disp -->|parents each agent to| daemon
  daemon -->|keeps alive across a restart| card
  card -->|registers under its own name in| reg
  reg -->|names the card agents a restart leaves alone| sup
  tick -->|appends transitions to| cards
  tick -->|re-derives every card's position from| forge
  tick -->|reaps finished worktrees with| sweep
  sup -->|documented for the operator in| skill
  sup -->|named for the operator in| agents
```
