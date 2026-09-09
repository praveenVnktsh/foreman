# foreman

An autonomous build loop that lives outside the project it builds.

A card moved into `Todo` on a Linear board is the only dispatch authorisation.
Everything after that — building it in a worktree, reviewing the diff
adversarially by sessions that did not write it, gating the merge on evidence,
watching the deploy, writing follow-ups — happens without anyone present.

A repository becomes buildable by adding one `board.toml`. Forking this
repository gives you a project that already has a builder.

Seeded from the board orchestrator built inside `murmr`, which remains its own
installation. See `docs/specs/`.

## Installing

foreman is installed once and pointed at repositories.

    git clone <url> ~/.foreman/install
    ~/.foreman/install/bin/install-skills.sh
    install -m 600 ~/.config/linear.key ~/.foreman/linear.key
    cp <your linear mcp config> ~/.foreman/mcp.json
    ~/.foreman/install/bin/boardctl add myproject --repo ~/Developer/myproject

`install-skills.sh` is not optional and not cosmetic. A tick runs `/board`, and
Claude Code resolves a skill by name from `~/.claude/skills/` -- never from this
install directory. Skip it and the loop looks installed and is not: the watchdog
starts a tick, reports it healthy, and the tick cannot find its own skill. If
another project has left a skill of the same name there, the tick runs that one
instead. `install-skills.sh` refuses to replace a skill it did not put there.

The key is one file per Linear workspace, not one per board.

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
would notice is the tick that just replaced itself. `git -C ~/.foreman/install
pull` moves the pin, deliberately by hand.

Pulling is only half of it. A running tick keeps reading the skill it started
with, so the new install takes effect at the next restart:

    ~/.foreman/install/skills/board/supervise.sh --restart

That replaces the tick and leaves every card that is mid-build alone. Each
dispatched agent is parented to the shared `claude daemon` rather than to the
tick, and the tick holds no state, so the replacement re-derives every card's
position from Linear, `gh` and `git`.
