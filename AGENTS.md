# Working in this repository

Orientation for an agent. **What to reach for, and what to reach for instead.**

This file does not say how to write code. `STYLEGUIDE.md` does, and repeating it
here would create the second source of truth that both files forbid.

## Run things

| To | Use | Not |
|---|---|---|
| Run the tests | `tests/run-all.sh` | a test framework; there is none |
| Run one test | `tests/test-<name>.sh` | it is a plain script, run it directly |
| Check every script parses | `bin/check-syntax.sh` | a linter; there is none |
| See what a target declares | `bin/contract.py board.toml` | reading `board.toml` by hand |
| See what the board does | `docs/board-flow.md` | reading 12 files to find out |
| Look at a diagram | `bin/render-diagram.sh docs/board-flow.md` | committing a render |

CI runs `tests/run-all.sh` on Python 3.12 and nothing else. Its job is named
`Tests`, which must keep matching `checks.required` in `board.toml`. A mismatch
makes the board wait forever for a check that never reports, and waiting looks
exactly like running.

## Read the code the board reads

| To | Use | Not |
|---|---|---|
| Read a file as `main` has it | `skills/board/evidence.sh main <path>` | `git show origin/main:<path>` |
| Read a file at a PR's head | `skills/board/evidence.sh pr <n> <path>` | the working tree |
| Read a PR's diff | `skills/board/evidence.sh pr <n>` | `git diff` against a local ref |

This is the one that looks like pedantry and is not. `git show origin/main:...`
reads a **local** ref that no fetch is guaranteed to have refreshed, so it
answers confidently with a stale file. `evidence.sh` fetches, then answers. A
reviewer refuting a finding from the working tree is the specific failure this
exists to stop.

## Ids, paths and locks

| To | Use | Not |
|---|---|---|
| Get a Linear team, project, state or label id | `ids.env`, written by `bin/resolve-ids.py` | a literal UUID, ever |
| Get an agent's scratch dir | `bin/tmp-dir.sh <worktree>` | `$TMPDIR`, or a path you compose |
| Serialise shared git metadata | `skills/board/withlock.py` | hoping two ticks do not collide |
| Create or inspect an instance | `bin/boardctl add\|list\|status\|halt\|resume` | editing `instance.env` by hand |

`skills/board/config.sh` needs `FOREMAN_INSTANCE` set and refuses to guess. It
is sourced, not run: `. skills/board/config.sh`.

## Hard constraints

- **Python: stdlib only.** No third-party packages anywhere. `tomllib` sets the
  floor at 3.11; CI runs 3.12. This is why the contract is TOML and not YAML --
  it keeps the property that there is no install step before the config can be
  read.
- **bash 3.2.** macOS ships it. No `mapfile`, no `declare -A`. Under `set -u`,
  `"${arr[@]}"` on an empty array is an error, so use `"${arr[@]+"${arr[@]}"}"`
  or avoid the construct.
- **A target's config is parsed, never sourced.** Instances share a user and a
  home, so a config that can run code runs beside every other instance's
  credential before anything decided that repository was trusted.
- **Name nothing outside this repository.** No other project's name, no
  operator's name, no foreign ticket key or path. Every such fact is read at
  runtime from `board.toml` or instance state.
  `tests/test-no-target-specifics.sh` enforces it.
- **Renders are not committed.** `.gitignore` covers `/docs/*.html`. The mermaid
  in the markdown is the source.

## Where things live

- `skills/board/` — the loop. `SKILL.md` is the tick's instructions and is the
  largest file here; the rest are the scripts it calls.
- `bin/` — everything not specific to running the board.
- `tests/` — one file per invariant, named as the claim it makes.
- `docs/specs/`, `docs/plans/` — the record of what was decided and why. Exempt
  from the naming rule above, because they record what happened.
- `STYLEGUIDE.md` — how to write code here. `board.toml` hands it to every
  dispatched agent through `docs.required`.

## If you are about to

- **Add a dependency** — do not. See the constraint above.
- **Hardcode an id, a path or a name** — read it at runtime instead.
- **Commit a rendered diagram** — it is gitignored, and a committed render goes
  stale the first time nobody re-runs the script.
- **Write a test that reimplements the code it tests** — drive the real script
  and stub at the external boundary. `tests/lib/linear-stub.py` is the pattern.
- **Weaken a gate** — dispatched agents run with permissions bypassed. What
  contains them is the throwaway worktree, the required checks, the review, and
  high-risk paths parking for an operator. `skills/board/config.sh` says so where
  it turns permissions off.
