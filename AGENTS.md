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
| Plan, only when the change is not small | invoke `graphplan` | the graph is posted to the Linear card as a comment |
| Implement | make the change, or execute the graph | the change is made, or every node is done |
| Test | run the target's own test command | it ran, and it passed |

- **Judge the size first.** A small change is one coherent change to a handful
  of files with no design decision in it. It skips Plan and goes straight to
  Implement. Anything larger is planned first. Say which you judged, SMALL or
  PLANNED, in the pull request body.
- **A card labelled `needs-plan` is always planned, by a separate plan agent.**
  The board dispatches that agent for the Plan stage alone. It posts the graph
  on the card and stops: it pushes no commit and opens no pull request. The card
  sits in `Plan` until the graph lands as a comment and the operator signs it
  off, so a plan never posted is a card that never moves.
- **A build agent that plans its own card posts the graph and carries on.**
  Post it on the card with the footer line your prompt gives you, then execute
  it and open the pull request without stopping. The board reads your card's
  comments, not your branch.
- **When you plan, invoke `graphplan` as a skill, not from memory.** Its
  instructions authorise the Workflow tool, so invoking it is what makes the
  Implement stage run in parallel. Reading the file without invoking it leaves
  the work serial.
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
| Merge a card's pull request | `skills/board/merge.py <n> --head <sha> < card.json`, with the `merge_head` from `reconcile.py` | a bare `gh pr merge`; it skips the fast-track label and merges whatever the head is by then |
| Get a Linear id | `ids.env`, from `bin/resolve-ids.py` | a literal UUID, ever |
| Get an agent's scratch dir | `bin/tmp-dir.sh <worktree>` | `$TMPDIR`, or a path you compose |
| Serialise shared git metadata | `skills/board/withlock.py` | hoping two ticks do not collide |
| Order a board's Todo candidates for dispatch | `skills/board/queue.py` | ordering the queue by eye |
| Order this machine's boards for one pass | `skills/board/reconcile.py --board-order` | the name order `bin/boards.py --list` prints |
| See the whole machine at once | `skills/board/reconcile.py --overview` (add `--with-remote` for main's CI) | asking Linear, `gh` or the registry yourself; the overview is local-file-only so a browser can poll it |
| Watch a board from another device | `bin/install-dashboard.sh`, then publish it (`tailscale serve`) | a second reader of `boards.toml` or `instances/`; `bin/dashboard.py` derives nothing |
| Record that a board's slice reached it | `skills/board/reconcile.py --served <board>` | assuming `history.jsonl` shows it; an idle slice writes nothing |
| Record that a board wants a slot, so its share of the machine is reserved | `skills/board/reconcile.py --wants-slot <board>` (`dispatch.sh` already does it) | leaving it unsaid; a board that never asks reserves nothing |
| Manage a board | `bin/boardctl add\|list\|status\|halt\|resume` | editing `boards.toml` by hand |
| Retire a board | `bin/boardctl remove` (sweep its worktrees first), then `forget` to delete its runtime directory | deleting `instances/<board>/` by hand; `list` is what surfaces an orphan |
| Write foreman's config | `bin/install.sh --harness H ...` | writing `foreman.toml` by hand |
| Change a stage's model or its fallback | `foreman.toml` `[models]` and `[fallback]` (a tier is `model` or `harness:model`) | editing `config.sh`; it reads the declaration |
| See every live agent, across harnesses | `"$HARNESS_SH" list` (`skills/board/harness/registry.sh`) | one harness's adapter, which sees only its own registry |
| Make skills resolvable | `bin/install-skills.sh` | assuming the install directory is searched |
| View a diagram | `bin/render-diagram.sh <file.md>` | committing the render |
| Check a plan is a graph | `bin/check-plan-graph.py --max-label-chars <N> <file>` | reading the plan by eye, or the checker's default budget over a target that sets its own |
| Restart the tick, leaving cards alone | `skills/board/supervise.sh --restart` | `systemctl --user restart foreman.service`; it finds a healthy tick |
| Update foreman to the latest release | `bin/self-update.sh` | `git -C ~/.foreman/install pull` by hand; the tick keeps running the code it started with, so the machine reports healthy while running a version nobody chose |
| Cut a release foreman follows | `bin/release.sh` (`release.yml` runs it once CI passes on `main`) | assuming a merge deploys; it does, so a commit that should not ship needs the marker below |
| Opt a commit out of releasing | `Release: skip` (or `[skip release]`) in the commit or PR body | editing `release.yml`; the marker is per commit |

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
  contains them is the throwaway worktree, the Claude Code deny rules
  `dispatch.sh` adds per role (they stop editing tools, not programs), the
  required checks, and the review.
  Risk paths are a per-target gate; this repository leaves it empty by choice,
  not by omission.
- **Keep this repository's `board.toml` `[risk].paths` empty.** An agent must not
  add a path to it, nor remove the explicit empty list; only the operator
  changes it. A path added here parks every card that touches it for a human
  the operator has chosen not to put in the loop, so the board stalls.
- **CI's job name must keep matching `checks.required`.** A mismatch makes the
  board wait forever for a check that never reports. Waiting looks exactly like
  running, so nothing says so.
- **A test drives the real script**, stubbing at the external boundary.
  `tests/lib/linear-stub.py` is the pattern.
