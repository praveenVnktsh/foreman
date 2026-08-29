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
    ~/.foreman/install/bin/boardctl add myproject --repo ~/Developer/myproject \
        --linear-key-file ~/.config/linear.key

**The running loop uses the installed clone, never a working tree** — including
when the repository it is building is foreman itself. A board that reads its own
uncommitted code cannot survive merging a broken change to itself: the tick that
would notice is the tick that just replaced itself. `git -C ~/.foreman/install
pull` moves the pin, deliberately by hand.
