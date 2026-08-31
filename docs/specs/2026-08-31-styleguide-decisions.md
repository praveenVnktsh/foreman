# Styleguide and review decisions

**2026-08-31.** What was built, what was rejected, and what is still open.

## What was built

Three files, not the twenty-two an earlier draft of this design called for.

- `STYLEGUIDE.md` — everything an agent needs, in one file.
- `tests/run-all.sh` — the runner `board.toml` has named as `test.command` since
  the contract was written, and which did not exist.
- `tests/test-nothing-outside-this-repository-is-named.sh` — enforces the rule
  below.

## Why one file

The first design had ten guides under `styleguides/`, seven skills, an index, a
precedence rule, and four tests to police the structure.

- **Delivery was already solved and the design missed it.** `brief.py` renders
  "Read `<docs.required>` before making non-trivial changes" on every build. One
  line in `board.toml` delivers one file. No plugin manifest, no skill discovery,
  no `--plugin-dir`.
- **Most of the structure existed to manage the structure.** An index for one file
  is nothing. A precedence rule between guides is nothing when there is one guide.
  Three of the four planned tests only policed the sprawl.
- **Nothing had been validated.** No card has run end to end. Ten guides for a
  loop with no proven output is the second floor before the first.

Split the file when it stops being readable, and not before.

## The single rule: name nothing outside this repository

- Every fact about a project, a machine or a person is read at runtime, from
  `board.toml` or from instance state.
- A repository that names another project is not a template. It is a fork with the
  names left in.

**It caught real defects, not branding.**

- `skills/board/SKILL.md` documented the sidecar at a hardcoded path under a
  foreign project's name. `config.sh` resolves it under `$INSTANCE_HOME`. The
  prose named a path the code never used.
- The same file hardcoded the Linear team id, project id, five workflow state ids
  and four label ids. `bin/resolve-ids.py` resolves all of them into `ids.env`.
  Every id in that document was wrong for every installation but one.
- 41 occurrences in total across `SKILL.md` and `README.md`. All removed.

**Scope.** Bound: `skills/*/SKILL.md`, `STYLEGUIDE.md`, `README.md`. These
instruct a reader. Exempt: `docs/`, which records what happened, and code comments
recording an incident, which are history and true.

## Review: decided but not built

Review moves left. A defect caught in a plan costs a paragraph. The same defect
caught at review costs a build attempt, a fix round and two reviewers.

| Gate | Question | Status |
|---|---|---|
| Plan review | Is this the right thing, and is the design right? | **Not built.** Needs a plan role, artifact and board state that do not exist. |
| Merge | Is the code correct? | Exists: required checks. An external reviewer was proposed. |
| Daily pass | Is the codebase still coherent? | **Not built.** |

Two findings that stand regardless of whether the gates change:

- **The two reviewers get byte-identical prompts.** `dispatch.sh` runs
  `REVIEWERS_PER_ROUND: 2` in slots `a` and `b`, but `brief.py`'s `review()` takes
  no slot. It is one review run twice — the monoculture adversarial review exists
  to break. Fixing it costs one `brief.py` change.
- **`adversarial-reviewer` carries a second contract.** Its severity scale
  (`CRITICAL / MAJOR / MINOR / NOTE`), its prose output format, its rule promoting
  anything two personas caught, and its "find something even if it is only a NOTE"
  all contradict what `brief.py` asks for. `STYLEGUIDE.md` section 9 now holds the
  contract. The skill was left alone.

**Do not weaken the merge gate to nothing.** Agents run with permissions bypassed.
`config.sh` records what contains them: the throwaway worktree, the required
checks, the review, and high-risk paths parking for an operator.

## Rejected

- **A `styleguides/` directory of ten files.** Sprawl before validation.
- **Skills as separate directories with frontmatter.** The procedures that matter
  are four sentences each. They are sections of `STYLEGUIDE.md`.
- **Making this repository a plugin.** `docs.required` already delivers.
- **Depending on an external skill harness.** No skill or plan here may require one
  to be installed. A target repository is not guaranteed to have it.

## Open

- **Which cards get a plan**, if plan review is built. Every card is overhead on a
  one-line fix.
- **Whether an external reviewer can read `STYLEGUIDE.md`.** If it cannot, the
  file loses its enforcement point at merge and an agent reviewer has to stay.
- **`reconcile.py` is 1005 lines**, 23% of the board skill. Unexamined.
- **`SKILL.md` is 58KB**, larger than any code file here.
- **`waitfor.py` and `watch-agents.py` do one job between them.** Clearest merge.

See `docs/board-flow.md` for what the board actually does.
