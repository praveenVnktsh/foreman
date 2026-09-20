# Installing foreman

The full reference. The [README](../README.md) has the short version.

## Install

`~/.foreman` is foreman's home and its root: the clone, `boards.toml`, the
runtime under `instances/`, and the shared `linear.key` and `mcp.json` all sit
there. One foreman serves every board on the machine.

    git clone https://github.com/praveenVnktsh/foreman.git ~/.foreman/install
    ~/.foreman/install/bin/install.sh --harness claude
    ~/.foreman/install/bin/install-skills.sh
    install -m 600 ~/.config/linear.key ~/.foreman/linear.key
    cp <your linear mcp config> ~/.foreman/mcp.json
    ~/.foreman/install/bin/boardctl add myproject --repo ~/Developer/myproject

`bin/install.sh` writes `foreman.toml`: the harness and the stage models.
`--harness` is required; on Claude Code the four models default to what foreman
has always spent. It refuses to overwrite a file that exists, so re-running it is
safe and changing foreman's settings means editing `foreman.toml` by hand.

`install-skills.sh` is not optional and not cosmetic. A tick runs `/board`, and
each harness resolves a skill by name from its own skills directory -- never
from an install directory. Skip it and the loop looks installed and is not: the
watchdog starts a tick, reports it healthy, and the tick cannot find its own
skill. If another project has left a skill of the same name there, the tick
runs that one instead. `install-skills.sh` refuses to replace a skill it did
not put there.

`~/.foreman/mcp.json` is the tick's control plane, and it has to be foreman's own
rather than inherited. Claude Code resolves MCP servers per project, keyed on the
working directory; the tick runs from the install and serves every board, so it
inherits none. Without it the tick reads a board correctly and then has no way to
move a card. Inheriting the working directory's servers would be worse: which
servers the board may use would depend on where it started, and a target
repository could hand the tick a server of its choosing.

**The running loop uses the installed clone, never a working tree** — including
when the repository it is building is foreman itself. A board that reads its own
uncommitted code cannot survive merging a broken change to itself: the tick that
would notice is the tick that just replaced itself. `git -C
~/.foreman/install pull` moves the pin, deliberately by hand.

Pulling is only half of it. A running tick keeps reading the skill it started
with, so the new install takes effect at the next restart:

    ~/.foreman/install/skills/board/supervise.sh --restart

That replaces the tick and leaves every card that is mid-build alone. Each
dispatched agent is parented to the harness's own daemon rather than to the
tick, and the tick holds no state, so the replacement re-derives every card's
position from Linear, `gh` and `git`.

## Rate-limit fallback

A stage whose model is rate-limited falls back to the next tier down and keeps
working, instead of voiding every card that needs it. On 2026-09-16
`PLAN_MODEL=fable` was rate-limited for 11 hours and nothing moved; this table
is why it no longer does.

`foreman.toml` gains an optional `[fallback]` table:

    [fallback]
    tiers = ["opencode:foundry/gpt-6-astra", "opencode:foundry/gpt-5.6-sol", "claude:opus"]
    cooldown_minutes = 60                          # positive integer

    [fallback.floor]                               # optional, per stage
    plan = "claude:opus"

- **`tiers`** lists foreman's models, strongest first. A stage's
  own model (`plan`, `build`, and so on) must be one of them to fall back at
  all; a stage whose model is not in the list runs on it unconditionally, rate
  limit or not. **A tier is `model` or `harness:model`**, so one tick falls back
  across providers *and* across CLIs: `"opencode:foundry/gpt-5.6-sol"` spawns
  through the OpenCode adapter with model `foundry/gpt-5.6-sol`, and
  `"claude:opus"` through Claude Code. A tier without a prefix runs on the
  harness named by `harness` in `foreman.toml`. Because a tick may then have agents in more than
  one harness's registry, `$HARNESS_SH list` is
  [`harness/registry.sh`](../skills/board/harness/registry.sh), which merges
  every harness named in the tiers and stage models. Claude defaults `tiers` to
  `["fable", "opus", "sonnet", "haiku"]`. Codex and OpenCode default it to `[]`,
  off, because their model names are the operator's own and a guessed order
  could downgrade a stage onto a model foreman cannot run at all.
  Write `tiers = []` on Claude to turn fallback off the same way.
- **`cooldown_minutes`** is how long a rate-limited model is skipped before a
  stage tries it again. It defaults to 60 minutes.
- **`[fallback.floor]`** names, per stage (`plan`, `build`, `review`),
  the weakest model that stage may fall back to. A stage with no floor may
  fall all the way to the bottom of `tiers`. A floor must name a model in
  `tiers`, and it must sit at or below the stage's own model in that list;
  fallback only walks down, so a floor above the stage's model would never be
  reached and foreman refuses to load a `foreman.toml` that declares one. The
  cleanup stage shares the plan stage's floor, because it shares its model.

`install.sh` writes neither `tiers` nor `[fallback.floor]` — it takes only
`--harness` and the four `--model-<stage>` flags. Both tables are hand-edited
into `foreman.toml`, and every rule above is checked when that file is READ, so
a floor nothing could reach stops the next command that loads the declaration
rather than waiting for a rate limit to expose it.

While a model is rate-limited, the stage runs on the strongest tier below it
that is not, and the card's history and its Linear comment say which model was
limited, until when, and which model the stage runs on instead. When the
cooldown ends, the stage tries its first-choice model again on the next pass.

**Reaching the floor changes nothing else.** A stage that has fallen back as
far as its floor and finds that model rate-limited too voids exactly as it did
before this table existed, and says so on the card: the board waits rather
than fall back past a model the operator declared safe.

## Self-updating

foreman updates itself by pulling, not by anything inbound. Nothing a pull
request runs ever executes on the host: CI runs on GitHub-hosted runners, and
the only way a merged commit reaches a machine is foreman
fetching it. That is deliberate now that this repository is public — a
self-hosted runner would let a stranger's fork send code straight to an
operator's machine.

`bin/self-update.sh` is the automated form of the `git pull` and
`supervise.sh --restart` described above. It fast-forwards foreman's clone to
the latest release and restarts the tick, leaving any
in-flight card alone. It refuses rather than guess: a dirty clone, a clone
that is not on `main`, or an `origin/main` that was force-pushed all stop it
instead of producing a clone nobody asked for.

`bin/install-self-update.sh` schedules it as a systemd user timer, beside the
watchdog `install-service.sh` installs:

    ~/.foreman/install/bin/install-self-update.sh

## Releasing

foreman follows the **latest GitHub Release**. `.github/workflows/release.yml`
cuts one on every push to `main`, and `bin/self-update.sh` polls the latest and
fast-forwards the clone to its tag. So a merge deploys — unless the commit opts
out. This needs `gh` installed and authenticated for the user the timer runs as;
a gh that cannot answer is a refusal, not a silent no-op.

The workflow runs on GitHub-hosted runners, never on your machine, and only on a
push to `main` — never on a pull request — so no contributor's branch is in scope.

### Opting a commit out

A commit is not released when its message has a line of its own reading
`[skip release]` or `Release: skip`. It must be a whole line — a trailer — not a
phrase in a sentence: a squash merge takes the pull request body as the commit
body, so a looser match would fire on any prose that merely mentions the marker.
`bin/release.sh` checks the head commit and exits 0 without cutting, and the
Action is a no-op for it. `bin/release.sh --force` overrides.

### Cutting one by hand

Any clone with push access can cut a release, and `--force` overrides a skip:

    bin/release.sh --dry-run         # say what it would cut, change nothing
    bin/release.sh                   # tag origin/main and publish a release
    bin/release.sh --version v1.4.0  # name the tag (default vYYYY.MM.DD)
    bin/release.sh --force           # ignore a [skip release] marker

`gh release create <tag> --target <main sha> --generate-notes` makes the tag and
the release in one act. A tag that already exists is refused — a release is never
rewritten.

### Following a git ref instead

A development machine can track a ref rather than releases:

    ~/.foreman/install/bin/install-self-update.sh --ref origin/main

That writes `FOREMAN_UPDATE_REF=origin/main` into the unit. Running
`install-self-update.sh` with no `--ref` leaves foreman following
releases.
