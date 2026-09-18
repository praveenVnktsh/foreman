# Working in this repository

- `STYLEGUIDE.md` — how to write code. Not repeated here.
- `docs/board-flow.md` — what the board does, as one diagram.

## Who owns what

- Work arrives as a Linear card. The board dispatches you for it.
- **The board owns adversarial review, the merge, and the deploy.**
- **You own planning, implementing, testing, and reporting honestly.**
- **Your own prompt is the authority on what to do with your result.**
  `skills/board/brief.py` writes it, and it already covers pull requests and
  merging. This file repeats none of that.
- Do not review your own diff and call it done. The board reviews with sessions
  that did not write the code. A self-review shares the author's blind spots.
- Outside the board, the stages are the same. Reviewing and shipping are then the
  operator's call, so ask.

## Your three stages

| Stage | Do | Done when |
|---|---|---|
| Plan | invoke `graphplan` | the graph is posted to the Linear card as a comment |
| Implement | execute the graph | every node is done |
| Test | run the target's own test command | it ran, and it passed |

- The board reads your card's comments, not your branch. Your card sits in
  `Plan` until your graph lands as a comment on it, so a plan you never post is
  a card that never moves. Post it and stop: the plan stage pushes no commit and
  opens no pull request.
- **Invoke `graphplan` as a skill, not from memory.** Its instructions authorise
  the Workflow tool, so invoking it is what makes stage 2 run in parallel. Reading
  the file without invoking it leaves the work serial.
- No Workflow tool in this session? Say so and execute in dependency order by
  hand. Never serialise silently and report it as done.
- A test you did not watch run is not a passing test. Quote the output.
- Then stop and report: what you did, what you did not, what you assumed.
- Some failures are not about the code: no disk, a quota, a missing credential.
  Report one as exactly that, naming the command and quoting the error. The board
  repairs a machine it is told about and re-runs you for free. A build that works
  around a broken environment and then dies costs the card an attempt.

## What to use

| To | Use | Not |
|---|---|---|
| Run the tests | `tests/run-all.sh` | a framework or linter; there are none |
| See what a target declares | `bin/contract.py board.toml` | reading `board.toml` by hand |
| Read a file as `main` has it | `skills/board/evidence.sh main <path>` | `git show origin/main:<path>` |
| Read a PR's file or diff | `skills/board/evidence.sh pr <n> [path]` | the working tree |
| Get a Linear id | `ids.env`, from `bin/resolve-ids.py` | a literal UUID, ever |
| Get an agent's scratch dir | `bin/tmp-dir.sh <worktree>` | `$TMPDIR`, or a path you compose |
| Serialise shared git metadata | `skills/board/withlock.py` | hoping two ticks do not collide |
| Order a board's Todo candidates for dispatch | `skills/board/queue.py` | ordering the queue by eye |
| Order this machine's boards for one pass | `skills/board/reconcile.py --board-order` | the name order `bin/boards.py --list` prints |
| Record that a board's slice reached it | `skills/board/reconcile.py --served <board>` | assuming `history.jsonl` shows it; an idle slice writes nothing |
| Manage a board | `bin/boardctl add\|list\|status\|halt\|resume` | editing `boards.toml` by hand |
| Write a new installation's config | `bin/install.sh --harness H ...` | writing `installation.toml` by hand |
| Make skills resolvable | `bin/install-skills.sh` | assuming the install directory is searched |
| View a diagram | `bin/render-diagram.sh <file.md>` | committing the render |
| Check a plan is a graph | `bin/check-plan-graph.py --max-label-chars <N> <file>` | reading the plan by eye, or the checker's default budget over a target that sets its own |
| Restart the tick, leaving cards alone | `skills/board/supervise.sh --restart` | `systemctl --user restart foreman.service`; it finds a healthy tick |
| Update an installation to the latest `main` | `bin/self-update.sh` | `git -C ~/.foreman/<name>/install pull` by hand; the tick keeps running the code it started with, so the machine reports healthy while running a version nobody chose |
| Promote tested `main` to a release installations track | `bin/release.sh` | assuming a merge to `main` deploys; once an installation is pinned with `FOREMAN_UPDATE_REF=origin/release`, only a release does |

- `git show origin/main:<path>` reads a **local** ref. No fetch is guaranteed to
  have refreshed it, so it answers with a stale file and no warning.
  `evidence.sh` fetches, then answers.
- The test command comes from the contract, not from memory:

```bash
bin/contract.py board.toml | tr '\0' '\n' | grep -A1 TEST_COMMAND
```

- `skills/board/config.sh` needs `FOREMAN_INSTANCE` and refuses to guess. Source
  it, do not run it.

## Hard constraints

- **Python stdlib only.** No third-party packages. `tomllib` sets the floor at
  3.11; CI runs 3.12. This is why the contract is TOML: no install step before
  the config can be read.
- **bash 3.2.** No `mapfile`, no `declare -A`. Under `set -u`, `"${arr[@]}"` on
  an empty array is an error.
- **A target's config is parsed, never sourced.** Instances share a home, so a
  config that can run code runs beside every other instance's credential.
- **Name nothing outside this repository.** No other project, operator, ticket
  key or path. Read every such fact at runtime.
  `tests/test-no-target-specifics.sh` enforces it.
- **Do not commit a render.** The mermaid in the markdown is the source.
- **Do not weaken a gate.** Dispatched agents run with permissions bypassed. What
  contains them is the throwaway worktree, the required checks, the review, and
  high-risk paths parking for an operator.
- **CI's job name must keep matching `checks.required`.** A mismatch makes the
  board wait forever for a check that never reports. Waiting looks exactly like
  running, so nothing says so.
- **A test drives the real script**, stubbing at the external boundary.
  `tests/lib/linear-stub.py` is the pattern.
