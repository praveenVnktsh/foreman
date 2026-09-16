# An autonomous board runner, outside any one project

> **Corrected 2026-08-31.** This spec said `board.toml` throughout. The
> implementation is `board.toml`. The change was deliberate. `tomllib` is stdlib
> from Python 3.11 and `pyyaml` is not. TOML therefore keeps the property that
> made the original installable anywhere: no install step before the config can
> be read. References and the example below are corrected. Everything else is
> the design as written.


**Status:** awaiting review. Working name `foreman` — the repo name is
not decided and every occurrence below is that placeholder.

## Decision

A standalone repository holding the autonomous build loop that today lives
inside murmr: Linear as the control plane, a card moved into `Todo` as the only
dispatch authorisation, an agent that builds it in a worktree, adversarial
review rounds by sessions that did not write the diff, gated merge, deploy
evidence, a scheduled cleanup card.

It is installed on a machine once and pointed at one or more repositories. A
repository becomes buildable by adding one file. Forking this repository gives
you a new project that already has a builder.

## This is a copy, not an extraction

murmr is not touched. It keeps `.claude/skills/board/` and `harness/`, keeps
running its own installation, and none of its CI, tests or in-flight pull
requests change. `foreman` is seeded by copying that code and is generalised
independently.

**The two copies will drift, and that is accepted.** murmr's board took four
changes in the week this was written; none of them will reach `foreman` unless
someone carries them by hand. The eventual resolution — murmr deletes its copy
and becomes an ordinary `foreman` target — is a later decision and explicitly
not part of this work. Until then, a fix made in one place is a fix made in one
place.

## The repository is both the tool and the template

Forking `foreman` yields a repository that contains the runner *and* is itself a
valid target: `board.toml`, CI, the doctrine documents an agent is told to read.
`init` rewrites the identity — new Linear project, new labels, new instance —
and the fork is building within minutes.

The cost is the ordinary cost of a forked template. Your project's history is
`foreman`'s history, and an upstream fix arrives only if you add an upstream
remote and merge it. The alternative is `foreman` as a dependency plus a
thin separate template. It keeps histories clean. It was rejected for two
reasons. It turns the common case, "fork this, get a builder", into a multi-step
install. And the dogfooding below depends on the tool and the target being one
repository.

## The contract: `board.toml`

One file in the target repository. Everything the loop needs to know about a
project that is not derivable from Linear, `gh` or `git`.

```toml
[linear]
team = "ABC"                      # by NAME; resolved to an id at init
project = "example"

[checks]
required = ["Tests"]
ci_workflow = "CI"                # workflow NAME, matching `name:` in the yml

[deploy]                          # optional
workflow = "deploy.yml"
step = "Deploy and verify"        # the step, not the job -- see below
selection_step = "Choose the revision to deploy"  # optional; reads a queued deploy's reason

[risk]
paths = ["migrations/"]

[test]
command = "tests/run-all.sh"

[bootstrap]
command = "uv sync"               # run in a fresh worktree before building

[docs]
required = ["STYLEGUIDE.md"]

[limits]
max_concurrent = 1
max_build_attempts = 3
max_review_rounds = 1
reviewers_per_round = 1
```

`max_review_rounds` and `reviewers_per_round` dropped to 1: see
`docs/specs/2026-09-15-cleanup-and-light-review-design.md` for why review
gates on `blocking` findings alone and quality work moved to scheduled
cleanup.

**Parsed, never sourced.** Today's `config.sh` is shell and every knob is an
environment variable, so a sourced file would be the obvious port. It is
rejected: with no isolation between instances, a config that can run code runs
as the operator's user beside every other instance's credentials, before
anything has decided whether that repository is trusted.

Four entries carry the reasoning that produced them and must not be flattened
into "settings":

- `deploy.step`, not `deploy.workflow` alone. A deploy job concludes `success`
  when it stands down on a stale revision, so job success is not deployment
  success. The step name is the evidence. `deploy` absent means the target has
  no deployment and merged is done.
- `deploy.selection_step` exists because a target that queues deploys instead
  of firing on every merge makes a *skipped* deploy step ambiguous three ways:
  standing down because a deploy is still coming, queued until the next
  scheduled run, or a selection that failed outright and will never resolve on
  its own. Job success and step name can't tell those apart, so the board
  reads the named step's own conclusion and the reason it logged to the job
  output. A `success` conclusion whose reason begins `queued:` is Done with
  `verified` false -- the wait is over even though nothing deployed yet. A
  `failure` conclusion is terminal and reported to the card, never waited on.
  `selection_step` absent leaves the old reading, where only the deploy step's
  own conclusion is examined.
- `risk.paths` is read from the diff, never from the ticket text. A path here
  parks the pull request for a human instead of merging it. The distinction
  worth preserving is reversibility, not sensitivity: a bad change to a service
  is a revert, a migration that ran is not.
- `docs.required` is the extension point for style guides and anything else a
  future project wants every agent to have read. A style guide is a contract
  entry, not new machinery.

The values above are murmr's, because they are the only ones that have ever
been proven. **murmr gets no such file under this spec** — they are shown
because a contract entry is easier to judge against a project that has actually
broken in the way it guards.

`limits` are defaults; an instance may override any of them, because they
describe what a *machine* can sustain and the same repository may be built on
two different machines.

**The scratch root and the halt file are not in here.** Both are properties of
an installation, not of a repository. The same checkout built on two machines has
two scratch roots. The halt file stops *this machine's* dispatch. They live in instance state. A target whose CI writes the halt file on
a failed deploy is told the path by the instance; a repository cannot know it.

## Names in the file, ids at runtime

> **Corrected 2026-09-09.** This section understated the columns and labels the
> resolver pins, and named none of them. `Plan` and `Needs Human` joined the
> loop after this spec was written, and the `needs-plan` label with them. The
> counts below now match `STATE_ROLES` and `LABEL_ROLES` in
> `bin/resolve-ids.py`, and the states are named, because an agent editing that
> list reads this spec first and has to see which columns are already there.
> Everything else is the design as written.

The contract names the Linear team and project. `init` resolves them — and the
seven states and five labels — to ids, creates any label that does not exist,
and writes the ids into instance state. The states are `Backlog`, `Todo`,
`Plan`, `In Progress`, `In Review`, `Done` and `Needs Human`, in the order
`STATE_ROLES` declares them.

This keeps both properties that matter. The file is forkable, because a fork
does not inherit somebody else's project UUID. And the running loop still moves
cards by id and never by name, so renaming a column cannot silently change which
column the orchestrator is allowed to write to.

Resolution is verified, not trusted: a label id must belong to a label with the
name that asked for it, and the dispatch-authorising state must be of type
`unstarted`. A wrong id fails closed.

## Instance state

`~/.foreman/instances/<name>/` — resolved ids, the board credential, the card
sidecar, per-card `history.jsonl`, the instance's copy of `limits`.

It remains a cache and never truth. Delete it and the next tick reconstructs
every card's position from Linear, `gh` and `claude agents`. A fact that exists
only here is a design failure, and is reported as one.

## What changes in the copied skill

1. **`REPO` inverts.** `config.sh` derives it from the skill's own
   `--git-common-dir`, which is correct for a skill checked into the repository
   it builds and wrong for a skill installed once and pointed at many. The
   instance names the repository.
2. **`config.sh` becomes defaults plus a loader** over `board.toml` and instance
   state. Every value keeps its environment-variable override.
3. **Agent names carry the instance.** `board/tick` and
   `board/build/PRA-28-1` are matched by prefix against one flat, host-global
   `claude agents` registry. Two instances collide there, and the failure is one
   board reaping another board's agents. Names become
   `foreman/<instance>/<role>/<ticket>-<attempt>`, and every matcher —
   `reconcile.py`, `supervise.sh`, `waitfor.py`, `watch-agents.py`, `sweep.sh` —
   follows. Cheap now, a retrofit across five files later.
4. **The host ceiling is a count.** `reconcile.py` already counts cards holding
   slots; counting across `~/.foreman/instances/*/cards/` is the same read.
   `HOST_MAX_CONCURRENT` bounds the machine, `max_concurrent` bounds one
   instance.
5. **`preflight.py` takes a lock.** Two instances writing gigabyte probes
   concurrently both observe room that only one of them can have. The probe
   sizes stop being calibrated to one project's test suite and are declared.
6. **`just test-all` becomes `test.command`**, and a fresh worktree runs
   `bootstrap.command` before building.
7. **The prose generalises.** Incidents that justify the code are kept as
   reasoning and rewritten as portable lessons: a named host becomes its
   specification, a ticket key becomes "a card", murmr becomes "the target".
   Nothing is deleted merely for being a story — the stories are why the
   constraints are believed.

Toolchain isolation is deliberately not attempted. One installation on one
machine accumulates whatever its targets need to build.

## Instance #1 is this repository

`foreman` gets its own Linear project, `board.toml`, CI and test suite, and its
own instance builds it. Until a card walks from `Todo` to merged on a repository
that is not murmr, the contract is a hypothesis.

**The running instance builds from a pinned install, never from the working
tree.** A board that reads its own uncommitted code cannot survive merging a
broken change to itself. The tick that would notice is the tick that just
replaced itself. `boardctl upgrade` moves the pin, deliberately by hand.

## Tests

The board's tests are copied out of murmr's `ops/tests/` and are the reason any
of this is trustworthy: evidence reads are fresh, preflight fetches only to
gate, deploy outcomes are read from the step. They run in `foreman`'s own CI
against `foreman`'s own contract, which is also the first proof that the loop
works on a repository that is not murmr.

## Out of scope for this spec

- `boardctl` beyond what dogfooding needs, and multi-instance systemd units
- The sandboxed judge (`harness/bin/`) and the job format. It is
  layer-independent, and jobs are repo-local by nature: a job's `spec.md` is a
  statement about one project's expected behaviour. It gets its own spec.
- `init` and the fork path
- Anything that would require a change in murmr

## Open questions

- The repository name.
- Whether `foreman` targets a Linear project per repository or one project with
  a label per repository. Assumed per-repository: the scope filter is the only
  thing standing between an instance and another instance's cards.
