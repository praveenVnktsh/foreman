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
