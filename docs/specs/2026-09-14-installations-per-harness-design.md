# Several installations on one machine, each on its own harness

## Goal

One machine runs several foreman installations at once. Each installation runs
its own tick on a different coding-agent harness -- Claude Code, Codex, or
OpenCode -- so an operator with more than one subscription spends each of them.
The installations serve the same Linear boards. A label on the card says which
installation takes it; one installation is the default for cards with no label.

Everything Claude-specific in foreman today moves behind one adapter with five
verbs. The tick stays an LLM following `skills/board/SKILL.md`. Turning the tick
into a program is a later step this design makes possible and does not take.

## Layout

`~/.foreman` becomes the machine root. Each installation is one directory under
it, named by the operator:

```
~/.foreman/                      the machine root
  linear.key                     shared: one per Linear workspace, as today
  mcp.json                       shared: the Linear control plane, Claude's format
  claude/                        one installation; its FOREMAN_HOME
    install/                     its own clone, pinned on its own
    installation.toml            harness, default, models
    boards.toml                  this installation's boards
    instances/<board>/           cards/, ids.env, HALT, last-served, as today
    agents/                      the adapter's registry, for harnesses without one
    supervise.lock               one tick per installation
    tmp/                         agent scratch, as today
  codex/
    install/ ...                 same shape
```

**Identity comes from the path.** `config.sh` derives the installation home as
the parent of the install root when `FOREMAN_HOME` is unset, and the
installation name as that directory's basename. An explicit `FOREMAN_HOME` still
wins, which is how the tests point everything at a temporary directory. A name
follows the board-name rule: letters, digits and underscore, because it is
pasted into worktree globs, agent names and a Linear label.

**A home with no `installation.toml` is a lone Claude installation.** That is
exactly today's layout, so an un-migrated home keeps working: name `claude`,
harness `claude`, default, no siblings. `bin/installation.py` says so on stdout
rather than leaving each consumer to guess.

### installation.toml

```toml
harness = "codex"        # claude | codex | opencode
default = false          # at most one sibling may say true

[models]
tick = "gpt-5-codex"
plan = "gpt-5-codex"
build = "gpt-5-codex"
review = "gpt-5-codex"
```

`bin/installation.py` reads it, in the style of `bin/boards.py`: NUL-separated
`KEY, VALUE` pairs, every key always emitted, parsed never sourced, refusing
anything it cannot make sense of.

```
installation.py                    this home's INSTALLATION, HARNESS, IS_DEFAULT,
                                   FOREMAN_ROOT, TICK_MODEL, PLAN_MODEL,
                                   BUILD_MODEL, REVIEW_MODEL
installation.py --siblings         every installation under FOREMAN_ROOT, as
                                   NAME, HOME pairs -- two fields each, the
                                   same wire format as every other mode here
installation.py --write --harness codex [--default] [--model-tick M] ...
                                   write installation.toml for this home
```

**Which installation is the default**, in three rules, because every card that
carries no `foreman:*` label belongs to it:

- **A lone installation is the default**, whatever its `installation.toml`
  says, and a home with no `installation.toml` at all is a lone installation.
  There is no second reader to disagree with, and an operator who never learned
  about labels keeps a working machine.
- **Several installations, exactly one saying `default = true`** is the normal
  shape of a machine running two harnesses.
- **Several installations and no default is refused**, not tolerated. With no
  default, `queue.py` drops every unlabelled card as foreign and exits 0, so
  every tick on the machine reports a healthy, empty board while the cards sit
  in `Todo` forever. A silent stop is worse than a refusal.

Refusals, all exit 1 with the reason on stderr:

- `harness` missing or not one of the three.
- `default = true` in more than one sibling. Every reader checks this, so a
  second default is refused before its tick starts, not after both dispatched.
- More than one sibling and `default = true` in none of them, for the reason
  above. Checked on every read, the same way.
- A Codex or OpenCode installation with any of the four models unset. Claude
  keeps today's defaults (`fable`, `fable`, `opus`, `opus`). The other two have
  no defaults because a wrong model name on those harnesses fails later and
  quietly.
- An installation name that breaks the name rule.

`config.sh` loads these pairs the way it loads `boards.py`'s, and exports
`INSTALLATION`, `HARNESS`, `IS_DEFAULT` and `FOREMAN_ROOT`. The four model
variables keep their names and their environment-wins semantics.

### Creating an installation

```bash
git clone <url> ~/.foreman/codex/install
~/.foreman/codex/install/bin/install.sh --harness codex --model-tick M --model-plan M --model-build M --model-review M
~/.foreman/codex/install/bin/install-skills.sh
~/.foreman/codex/install/bin/boardctl add myproject --repo ~/Developer/myproject
```

`bin/install.sh` writes `installation.toml` through `installation.py --write`
and refuses to overwrite one that exists. It is the one new operator command.

### Migration

`boardctl migrate` gains a second step, after the `instance.env` step it already
has. When the home holds `install/` directly and no `installation.toml`:

1. Refuse if any `foreman/` agent is live in the Claude registry. Names change
   shape below, and a live agent under the old name would become invisible.
2. Move `install`, `boards.toml`, `instances`, `installed-skills`,
   `replaced-skills`, `tmp` and `supervise.lock` into `~/.foreman/claude/`.
3. Write `~/.foreman/claude/installation.toml` with `harness = "claude"` and
   `default = true`.
4. Print the two things it cannot do: re-run `install-skills.sh` from the new
   path so the links point at the moved clone, and re-run `install-service.sh`
   or fix the cron line, because both name the old path.

The key and `mcp.json` stay at the root. Nothing else on the machine moves.

## Routing

**A card belongs to exactly one installation, in every column.** The label
`foreman:<name>` names the owner. Each installation creates its own label on
first resolve, through `LABEL_ROLES` in `bin/resolve-ids.py`, as
`LABEL_INSTALLATION`. The default installation also owns every card carrying
no `foreman:*` label.

**The filter is a program.** `queue.py` gains `--installation <name>` and
`--default`, and drops every card it does not own before ranking, naming each on
stderr as it names an unrankable one. A card whose `foreman:*` label matches no
sibling name is reported as unroutable and never ranked; `--siblings` from
`installation.py` is what it checks against. `reconcile.py` never sees a Linear
listing: it is handed ticket names one at a time, so the filter for the other
three columns is the tick's, stated once in `SKILL.md` where the columns are
listed. The tick's prose says to pass the flags to `queue.py` and to trust its
filter for `Todo`, not to re-derive it.

**Ownership is made durable at dispatch.** When a tick takes a card that has no
`foreman:*` label, it applies its own label before moving the card out of
`Todo`. Changing which installation is default later never re-routes a card
mid-build.

## The harness adapter

`skills/board/harness/<harness>.sh` for `claude`, `codex` and `opencode`.
`config.sh` exports `HARNESS_SH` as the selected one, and every script that runs
`claude` today runs `"$HARNESS_SH"` instead. `SKILL.md`'s table of "read it
from" changes its liveness row the same way.

### The five verbs

```
harness.sh spawn  --name N --cwd D --model M --prompt-file F
                  [--add-dir D] [--mcp-config F] [--skip-permissions]
                  [--max-budget-usd N] [--settings JSON] [--loop-minutes K]
                                                         prints the session id
harness.sh resume --name N --cwd D --prompt-file F
                  [--skip-permissions] [--max-budget-usd N] [--settings JSON]
                                                         prints the session id
harness.sh list                                          prints a JSON list
harness.sh stop   <id>
harness.sh transcript <cwd> <session-id>                 prints a path
harness.sh check                                         exit 0 if the binary runs
harness.sh skills-dir                                    where this harness resolves skills
harness.sh skill-prompt <name>                           the prompt text that invokes a skill
harness.sh reap <older-than-seconds>                     drops finished records past the window
```

`list` prints what `claude agents --json --all` prints today, and only the
fields foreman reads: `name`, `id`, `sessionId`, `pid`, `state`, `startedAt`
(epoch milliseconds), `cwd`, `status`. `state` is one of `working`, `done`,
`blocked`, `stopped`, which is the exact set `reconcile.py`'s `PHASE` table maps.
Several rows may share a name, the newest `startedAt` is the live one, and every
consumer already sorts by it.

`--max-budget-usd N` is the per-agent spend ceiling `dispatch.sh` passes when
`MAX_BUDGET_USD` is set. Only Claude Code has such a flag, so only its adapter
accepts it. The other two refuse it by name, so a cap set on a codex or
opencode installation fails every dispatch loudly instead of running uncapped.

`reap` is the lifecycle rule for the adapter's own registry. `sweep.sh` calls
it on its orphan pass with the same retention window it applies to review
worktrees, so finished records, logs and wrappers under `agents/` do not
accumulate for the life of the installation. Claude's registry is Claude's to
age out, so its adapter answers with a no-op.

`--settings JSON` is Claude Code's per-session settings. `dispatch.sh` passes
config.sh's `CARD_AGENT_SETTINGS` on every card agent, spawned or resumed, to
turn off the Remote Control registration a card agent would otherwise leave in
the operator's claude.ai account forever. The tick never gets it. The codex and
opencode adapters accept it and drop it, because nothing on those harnesses
registers with a claude.ai account.

`transcript` returns the file whose mtime is the agent's last activity. For
Claude that is the session `.jsonl` under `~/.claude/projects`, computed as
`reconcile.py` computes it today; the computation moves into the adapter.

`--loop-minutes K` is the tick's shape: run the prompt, wait K minutes, run it
again, until stopped. Claude's adapter ignores it because `/loop` already does
this inside one session. The other two adapters wrap the harness call in a
shell loop, because their commands return when the turn ends, and the tick
holds no state by design, so a fresh session per pass loses nothing.

### Claude

Wraps `claude --bg --name --model --add-dir --mcp-config`, `claude --bg
--resume`, `claude agents --json --all`, `claude stop`, and the transcript path.
The flag-order rule that `dispatch.sh` and `supervise.sh` document today, that a
non-variadic flag must sit before the prompt, moves into the adapter with its
comment. `skills-dir` is `~/.claude/skills`; `skill-prompt board` is
`/loop /board` under `--loop-minutes` and `/board` otherwise.

### Codex and OpenCode

Both run the harness in the foreground under `nohup`, detached from the caller,
with output to a log, and keep one record per agent under
`$FOREMAN_HOME/agents/<id>.json`: `name`, `cwd`, `pid`, `sessionId`,
`startedAt`, `log`, `exit` once known. `id` is a foreman-minted identifier, and
`sessionId` is the harness's own, parsed from its JSON event stream once it is
printed. `list` derives state from the record: `working` while the pid is alive,
`done` on exit 0, `stopped` on any other exit or after `stop`. `blocked` never
occurs, because both run with their bypass flag. `transcript` is the log.
`stop` signals the pid and its process group, so a loop and the harness call it
is inside die together.

- Codex: `codex exec --cd D -m M --dangerously-bypass-approvals-and-sandbox
  --json PROMPT`; resume is `codex exec resume <sessionId>`. MCP servers are
  passed as `-c mcp_servers.<name>.command=...` overrides translated from the
  shared `mcp.json`. `skills-dir` is `~/.codex/skills`.
- OpenCode: `opencode run --dir D -m M --auto --format json PROMPT`; resume is
  `--session <sessionId>`. MCP servers are written as an OpenCode config file
  under `$FOREMAN_HOME/agents/` translated from `mcp.json`, and the harness is
  pointed at it. `skills-dir` is `~/.config/opencode/skill`.

The exact flags are verified against the installed CLI at build time and
recorded in each adapter's header comment. What the design fixes is the verb
set and the record shape, not the flag spelling.

### Adding a harness

A fourth harness is six edits, and the list is here because every one of them
fails quietly on its own. A missing adapter is an installation nobody can
declare; an adapter nobody tests is a verb that answers differently from the
other three, which is exactly what the contract test exists to stop.

1. `bin/installation.py`, `HARNESSES` — the name becomes declarable. Until it
   is in that tuple, `installation.toml` is refused and no home can say it.
2. `skills/board/harness/<name>.sh` — the adapter, the whole verb set above,
   with the installed CLI's real flags recorded in its header comment.
3. `tests/lib/harness-stub.sh` — a stub for that CLI that prints what the real
   one prints, so the contract test can drive it with no subscription.
4. `tests/test-harness-adapters-agree.sh`, the `for harness in ...` loop — add
   the name. An adapter absent from that loop is an adapter nothing runs.
5. `README.md` — the install instruction for an installation on that harness,
   beside the Codex one.
6. `skills/board/SKILL.md` — anywhere the prose says which harness a step needs.
   Today that is the invocation section (`/loop` and the Monitor are Claude's
   alone) and `claude attach`.

Nothing else names a harness. Every other script reaches the CLI through
`$HARNESS_SH`, which `config.sh` selects and refuses when the adapter is
missing or not executable.

### What changes for callers

- `dispatch.sh`: `spawn` and `resume` through the adapter. `--add-dir` and the
  permission flags become adapter arguments. `lookup_session` reads `list`.
- `supervise.sh`: `start_agent` calls `spawn --loop-minutes
  $TICK_INTERVAL_MINUTES` with `skill-prompt board`; `read_registry`,
  `stop_ticks` and `card_agents` read `list` and call `stop`.
- `reconcile.py`, `watch-agents.py`, `waitfor.py`, `sweep.sh`: `list` and
  `transcript` in place of `claude agents` and the hard-coded transcript path.
- `preflight.py`: `check` in place of `claude --version`.
- `install-skills.sh`: `skills-dir` in place of `~/.claude/skills`; the
  manifest stays under `FOREMAN_HOME`.
- `install-service.sh`: the unit is `foreman-<installation>.service` and
  `.timer`, and it checks the skill link under the adapter's `skills-dir`.

## Names carry the installation

Two installations may serve one repository, so every name that used to start at
the board starts at the installation:

| Was | Becomes |
|---|---|
| `foreman/<board>/<ticket>/<role>-<attempt>` | `foreman/<installation>/<board>/<ticket>/<role>-<attempt>` |
| `foreman/tick` | `foreman/<installation>/tick` |
| `$REPO/.claude/worktrees/foreman-<board>-<ticket>` | `.../foreman-<installation>-<board>-<ticket>` |
| `foreman/<board>/<ticket>` (branch) | `foreman/<installation>/<board>/<ticket>` |
| `refs/foreman/<board>/evidence/<n>` | `refs/foreman/<installation>/<board>/evidence/<n>` |

`sweep.sh`'s globs, `watch-agents.py`'s `DISPATCHED` regex and `reconcile.py`'s
prefix all gain the segment. The worktree directory stays under `.claude/` on
every harness: it is a path, not a dependency.

## The host ceiling

`reconcile.py --host-slots` counts cards under every sibling's
`instances/*/cards/`, not only this home's, keyed as `<installation>/<board>`.
`--may-dispatch` weighs those keys by each board's `priority` from its own
installation's `boards.toml`. `HOST_MAX_CONCURRENT` stays one number for the
machine, read from the environment as today. A lone installation counts only
itself, which is today's behaviour.

## Supervision

Each installation has its own `supervise.sh`, because it lives in that
installation's clone, and its own lock and tick name. `install-service.sh`
installs one timer per installation, and the README's cron line for macOS is one
line per installation.

## Testing

Every test drives the real script and stubs at the external boundary, in the
style of `tests/lib/dispatch-fixture.sh`.

- **Adapter contract.** One test runs the same script of verbs against all
  three adapters, with a stub `claude`, `codex` and `opencode` on `PATH` that
  print what the real ones print. It checks `spawn` prints an id, `list` shows
  it `working` then `done`, `stop` makes it `stopped`, `transcript` names a
  file whose mtime moves, `resume` continues the same session id, and
  `--loop-minutes` runs the prompt more than once.
- **Routing.** `queue.py` with `--installation` and `--default`: keeps its own
  cards, keeps unlabeled cards only under `--default`, reports a label naming
  no sibling, and ranks the survivors exactly as before.
- **Default uniqueness.** `installation.py` refuses two siblings that both
  say `default = true`, and `config.sh` therefore exits before any script runs.
- **Migration.** `boardctl migrate` on today's layout produces the new one,
  refuses with a live agent, and is a no-op the second time.
- **Names.** A dispatch, a sweep and a watch on two installations sharing one
  repository never touch each other's worktrees or agents.
- **Host slots across installations.** `--host-slots` on a root with two
  installations counts both, and `--may-dispatch` refuses when they jointly
  reach the ceiling.
- **Fixture.** `dispatch-fixture.sh` gains a harness stub and points
  `FOREMAN_HOME` at an installation directory under a root, so every existing
  dispatch test runs unchanged in the new layout.

## Known limits

- The tick is edge-triggered on Claude alone. `/loop` and the Monitor tool are
  Claude Code's own, so on Codex and OpenCode the cadence is the adapter's
  `--loop-minutes` wrapper -- one fresh pass per interval -- no Monitor is
  armed, and a dispatched agent that finishes wakes nothing. That tick finds it
  on its next pass through `"$HARNESS_SH" list`. Slower, not wrong: every pass
  re-derives the whole picture, which is the same property that makes a lost
  edge survivable on Claude. `SKILL.md`'s invocation section says so where the
  Monitor is armed.
- Graphplan's per-node model tiers are Claude names. On Codex and OpenCode
  every build node runs the installation's build model, and the plan brief says
  so.
- The Workflow tool exists only on Claude. `AGENTS.md` already tells an agent
  without it to execute in dependency order by hand and say so.
- How faithfully Codex and OpenCode follow the tick prose is measured by running
  them, not by this design.
- A card's label is applied by the tick over MCP, so a tick that dies between
  the label write and the column move leaves a labelled card in `Todo`, which
  the next pass of the same installation picks up: the label made it theirs.

## Out of scope

- A deterministic tick.
- Choosing the harness per role within one installation.
- More than one Linear workspace per installation, beyond the per-board `key`
  that `boards.toml` already allows.
