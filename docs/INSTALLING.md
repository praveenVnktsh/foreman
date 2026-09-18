# Installing foreman

The full reference. The [README](../README.md) has the short version.

## A first installation

`~/.foreman` is the machine root. Each installation is one directory under it,
named by the operator, holding its own clone and its own tick. A first install
on Claude Code, with no name chosen, lands at `~/.foreman/claude`:

    git clone https://github.com/praveenVnktsh/foreman.git ~/.foreman/claude/install
    ~/.foreman/claude/install/bin/install.sh --harness claude
    ~/.foreman/claude/install/bin/install-skills.sh
    install -m 600 ~/.config/linear.key ~/.foreman/linear.key
    cp <your linear mcp config> ~/.foreman/mcp.json
    ~/.foreman/claude/install/bin/boardctl add myproject --repo ~/Developer/myproject

`bin/install.sh` writes `installation.toml`: the harness, this installation's
models, and whether it is the machine's default. `--harness` is required; on
Claude Code the four models default to what foreman has always spent. It
refuses to overwrite one that exists, so re-running it is safe and changing an
installation's settings means editing `installation.toml` by hand.

The first installation needs no `--default`: an installation with no sibling
owns every card on its boards, labelled or not, and `install.sh` prints which
cards this one owns.

`install-skills.sh` is not optional and not cosmetic. A tick runs `/board`, and
each harness resolves a skill by name from its own skills directory -- never
from an install directory. Skip it and the loop looks installed and is not: the
watchdog starts a tick, reports it healthy, and the tick cannot find its own
skill. If another project has left a skill of the same name there, the tick
runs that one instead. `install-skills.sh` refuses to replace a skill it did
not put there.

The key and `mcp.json` are shared: one of each per Linear workspace, at
`~/.foreman`, not one per installation.

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
~/.foreman/claude/install pull` moves the pin, deliberately by hand.

Pulling is only half of it. A running tick keeps reading the skill it started
with, so the new install takes effect at the next restart:

    ~/.foreman/claude/install/skills/board/supervise.sh --restart

That replaces this installation's tick and leaves every card that is mid-build
alone. Each dispatched agent is parented to the harness's own daemon rather
than to the tick, and the tick holds no state, so the replacement re-derives
every card's position from Linear, `gh` and `git`. A sibling installation's
tick is unaffected: each has its own lock and its own `supervise.sh`.

## Rate-limit fallback

A stage whose model is rate-limited falls back to the next tier down and keeps
working, instead of voiding every card that needs it. On 2026-09-16
`PLAN_MODEL=fable` was rate-limited for 11 hours and nothing moved; this table
is why it no longer does.

`installation.toml` gains an optional `[fallback]` table:

    [fallback]
    tiers = ["opencode:foundry/gpt-6-astra", "opencode:foundry/gpt-5.6-sol", "claude:opus"]
    cooldown_minutes = 60                          # positive integer

    [fallback.floor]                               # optional, per stage
    plan = "claude:opus"

- **`tiers`** lists this installation's models, strongest first. A stage's
  own model (`plan`, `build`, and so on) must be one of them to fall back at
  all; a stage whose model is not in the list runs on it unconditionally, rate
  limit or not. **A tier is `model` or `harness:model`**, so one tick falls back
  across providers *and* across CLIs: `"opencode:foundry/gpt-5.6-sol"` spawns
  through the OpenCode adapter with model `foundry/gpt-5.6-sol`, and
  `"claude:opus"` through Claude Code. A tier without a prefix runs on this
  installation's own harness. Because a tick may then have agents in more than
  one harness's registry, `$HARNESS_SH list` is
  [`harness/registry.sh`](../skills/board/harness/registry.sh), which merges
  every harness named in the tiers and stage models. Claude defaults `tiers` to
  `["fable", "opus", "sonnet", "haiku"]`. Codex and OpenCode default it to `[]`,
  off, because their model names are the operator's own and a guessed order
  could downgrade a stage onto a model that installation cannot run at all.
  Write `tiers = []` on Claude to turn fallback off the same way.
- **`cooldown_minutes`** is how long a rate-limited model is skipped before a
  stage tries it again. It defaults to 60 minutes.
- **`[fallback.floor]`** names, per stage (`plan`, `build`, `review`),
  the weakest model that stage may fall back to. A stage with no floor may
  fall all the way to the bottom of `tiers`. A floor must name a model in
  `tiers`, and it must sit at or below the stage's own model in that list;
  fallback only walks down, so a floor above the stage's model would never be
  reached and `install.sh` refuses it. The cleanup stage shares the plan
  stage's floor, because it shares its model.

While a model is rate-limited, the stage runs on the strongest tier below it
that is not, and the card's history and its Linear comment say which model was
limited, until when, and which model the stage runs on instead. When the
cooldown ends, the stage tries its first-choice model again on the next pass.

**Reaching the floor changes nothing else.** A stage that has fallen back as
far as its floor and finds that model rate-limited too voids exactly as it did
before this table existed, and says so on the card: the board waits rather
than fall back past a model the installation declared safe.

## More than one installation (optional)

One installation serving every board is the normal setup, and the fallback tiers
are how it stays on a working model without a second tick. A machine *can* still
run several installations, each on its own harness -- Claude Code, Codex or
OpenCode -- for two subscriptions or a harness pinned to a different budget. They
serve the same Linear boards; a `foreman:<name>` label on a card says which
installation owns it, and one installation is the default for cards carrying no
such label. Nothing in the fallback design needs this; it is here for an
operator who wants it.

**Name the default before the second installation exists.** A machine with two
installations and no default refuses every read, because an unlabelled card
would then belong to nobody and every tick would report an empty board it was
silently dropping cards from. So first say which installation owns the
unlabelled cards -- usually the one already running -- by setting one line in
its own file by hand:

    default = true            # in ~/.foreman/claude/installation.toml

`install.sh` never edits a declaration that exists, which is why this is an
edit and not a command. Then a second installation, on Codex, follows the same
four commands under a name of its own:

    git clone https://github.com/praveenVnktsh/foreman.git ~/.foreman/codex/install
    ~/.foreman/codex/install/bin/install.sh --harness codex --model-tick M --model-plan M --model-build M --model-review M
    ~/.foreman/codex/install/bin/install-skills.sh
    ~/.foreman/codex/install/bin/boardctl add myproject --repo ~/Developer/myproject

It takes no `--default`, because `claude` now claims that. Pass `--default`
here instead if you want the new installation to own the unlabelled cards, and
leave `default = false` in the old one: exactly one installation on the machine
may say `true`.

Codex and OpenCode have no default model, unlike Claude, so `install.sh`
refuses to write `installation.toml` for either without all four `--model-*`
flags. `bin/boardctl add` on a repository the first installation already
serves adds a second builder for it; nothing about routing needs the operator
to say so, because the label does the routing.

**A non-default installation's boards take only surplus.** `boardctl add`
writes `priority = 0` there, so each board uses only the slots of
`HOST_MAX_CONCURRENT` the default installation is not using. At the implicit
priority 1, every new board reserves a slot while it holds no cards, and on a
machine running four slots that stopped the default installation's boards from
planning anything. To give a board a floor, add it with `--priority N`, for
example `boardctl add myproject --repo ~/Developer/myproject --priority 1`.

## Migrating an existing home

A home installed before installations existed has `~/.foreman/install`
directly, with no `installation.toml`. `boardctl migrate` moves it into
`~/.foreman/claude/`, writes `harness = "claude"`, `default = true` and
`names = "legacy"`, and
prints the three steps it cannot do for you: re-run `install-skills.sh` from
the moved clone, re-point `install-service.sh` or your cron line at the new
path, and disable the old watchdog -- `systemctl --user disable --now
foreman.timer`, or remove the old cron line. That last one is easy to miss and
loud when missed: the new timer is `foreman-claude.timer`, so the old
`foreman.timer` survives beside it and fails every ten minutes against a path
that has moved. `install-service.sh` refuses to install the new timer while the
old unit is still there.

**Names are kept.** The migrated installation keeps every agent, worktree and
branch name it had: `foreman/<board>/<ticket>`, not
`foreman/claude/<board>/<ticket>`. Your open pull requests stay on the branches
the board looks them up by, so no in-flight card is built a second time. Only
installations created from now on put their installation name into their
names. `migrate` still refuses if any `foreman/` agent is live, because it
moves the home, and with it the card history and scratch, under a running
agent.

## Self-updating

foreman updates itself by pulling, not by anything inbound. Nothing a pull
request runs ever executes on the host: CI runs on GitHub-hosted runners, and
the only way a merged commit reaches an installation is the installation
fetching it. That is deliberate now that this repository is public — a
self-hosted runner would let a stranger's fork send code straight to an
operator's machine.

`bin/self-update.sh` is the automated form of the `git pull` and
`supervise.sh --restart` described above. It fast-forwards this
installation's clone to `origin/main` and restarts the tick, leaving any
in-flight card alone. It refuses rather than guess: a dirty clone, a clone
that is not on `main`, or an `origin/main` that was force-pushed all stop it
instead of producing a clone nobody asked for.

`bin/install-self-update.sh` schedules it as a systemd user timer, beside the
watchdog `install-service.sh` installs:

    ~/.foreman/claude/install/bin/install-self-update.sh

## Releasing

An installation follows the **latest GitHub Release**. `.github/workflows/release.yml`
cuts one on every push to `main`, and `bin/self-update.sh` polls the latest and
fast-forwards the clone to its tag. So a merge deploys — unless the commit opts
out. This needs `gh` installed and authenticated for the user the timer runs as;
a gh that cannot answer is a refusal, not a silent no-op.

The workflow runs on GitHub-hosted runners, never on your machine, and only on a
push to `main` — never on a pull request — so no contributor's branch is in scope.

### Opting a commit out

A commit is not released when its message carries `[skip release]` or a
`Release: skip` trailer. A squash merge takes the pull request body as the commit
body, so `Release: skip` in the PR description is enough. `bin/release.sh` checks
the head commit and exits 0 without cutting, and the Action is a no-op for it.

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

    ~/.foreman/claude/install/bin/install-self-update.sh --ref origin/main

That writes `FOREMAN_UPDATE_REF=origin/main` into the unit. Running
`install-self-update.sh` with no `--ref` leaves the installation following
releases.
