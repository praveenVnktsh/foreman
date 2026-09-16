# foreman

An autonomous build loop that lives outside the project it builds.

A card moved into `Todo` on a Linear board is the only dispatch authorisation.
Everything after that — building it in a worktree, reviewing the diff
adversarially by sessions that did not write it, gating the merge on evidence,
watching the deploy, filing one planned cleanup card every few days — happens
without anyone present.

A repository becomes buildable by adding one `board.toml`. Forking this
repository gives you a project that already has a builder.

Seeded from the board orchestrator built inside `murmr`, which remains its own
installation. See `docs/specs/`.

## Installing

`~/.foreman` is the machine root. Each installation is one directory under it,
named by the operator, holding its own clone and its own tick. A first install
on Claude Code, with no name chosen, lands at `~/.foreman/claude`:

    git clone <url> ~/.foreman/claude/install
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

### A second installation

One machine can run several installations at once, each on its own harness --
Claude Code, Codex or OpenCode -- so an operator with more than one
subscription spends each of them. They serve the same Linear boards; a
`foreman:<name>` label on a card says which installation owns it, and one
installation is the default for cards carrying no such label.

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

    git clone <url> ~/.foreman/codex/install
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

### Migrating an existing home

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
