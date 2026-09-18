# Project-level installations, model candidates, and failover

## Goal

One tick per project, not per harness. A tick keeps its project's cards moving
even when a model becomes unavailable. The harness becomes a property of a
dispatch, not of an installation.

## Target model

- An installation is scoped to one project (one board). The card's project
  decides its owner, so the `foreman:<name>` label and the default-installation
  rule stop meaning anything.
- A stage names an ordered list of candidate models. Dispatch runs the first
  candidate that is available.
- Availability is per model. A provider's rate limit or exhausted quota marks
  that model unavailable for a cooldown.
- The runner can spawn any harness, so candidates may cross CLIs.

## First increment (this plan)

Within today's installation model, only the model side moves:

1. `[models]` stage values accept a string (one candidate) or an array (ordered
   candidates).
2. Dispatch picks the first candidate not marked unavailable.
3. A spawn that fails because the provider is unavailable marks that candidate
   and retries the next, without consuming the card's attempt budget.
4. Health is recorded per installation in `$FOREMAN_HOME/model-health.json` and
   expires after a cooldown.

## Wire format

- `bin/installation.py` emits two keys per stage: `<STAGE>_MODEL` is the first
  candidate, and `<STAGE>_MODELS` is the whole list, newline-separated. A
  candidate containing a newline is refused.
- `<STAGE>_MODEL` stays the primary so the operator override keeps working:
  `_foreman_load_pairs` reads it with `-`, so an exported `PLAN_MODEL=sonnet`
  wins and an empty `PLAN_MODEL=` reaches the CLI as an empty `--model`
  (`tests/test-the-plan-stage-dispatches-on-fable.sh:50-56`). `<STAGE>_MODELS`
  is what dispatch walks.
- `skills/board/config.sh` splits `<STAGE>_MODELS` into the candidate list.
  Every existing consumer reads `<STAGE>_MODEL` unchanged.
- An `installation.toml` written before this change carries single strings and
  yields a one-element list. No migration.

## Health store

- `$FOREMAN_HOME/model-health.json`:
  `{ "<model>": {"until": <epoch seconds>, "reason": "..."} }`.
- A model whose `until` is in the past, or absent from the file, is healthy.
- A missing or unreadable file reads as "all healthy". Health is an
  optimisation, not a gate, so its loss costs one probe and never a card.

## Failure classification

- A spawn is "provider unavailable" when the adapter exits non-zero and its
  stderr matches a small marker set: `429`, `rate limit`, `quota`, `usage`,
  `insufficient`, `unavailable`.
- The classifier lives in one place, `skills/board/dispatch.sh`, so every
  adapter is judged by the same rule.

## The runner: a candidate names its harness

A candidate is `<harness>:<model>`, for example `claude:opus` or
`opencode:foundry/gpt-5.6-sol`. The harness is optional; without it the
candidate uses the installation's declared `harness`. So an installation can
fall back across CLIs, not only across models, and the existing single-harness
config keeps working.

Dispatch resolves harness and model per candidate, resolves that harness's
adapter at `skills/board/harness/<harness>.sh`, and spawns through it. The
harness is written into the card's spawn history, so a later reader knows which
adapter owns an agent.

## The unified registry

Each harness adapter keeps its own registry. Codex and OpenCode share
`harness/detached.sh`'s `$FOREMAN_HOME/agents`; Claude uses its daemon. For the
runner, every agent an installation spawns must be visible to one `list`, and
`stop`/`transcript` must reach the adapter that owns it.

The rule: an agent's record carries its harness, and the readers
(`reconcile.py`, `sweep.sh`, `supervise.sh`, `watch-agents.py`) ask every
adapter and merge, keyed by harness. Claude is the cost: its daemon registry is
not a directory of records, so its adapter also writes a detached-style record
at spawn. That record is a pointer, not the truth — the daemon still owns
liveness — and `list` for claude reads it to answer in the common shape.

## Project-scoped installs

One board per installation, named for the project. The card's project decides
its owner, so `route.py`, `queue.py`'s routing, the `foreman:<name>` label and
the default-installation rule all stop meaning anything. A tick claims the Todo
cards of its board's project and no others. The host ceiling keeps counting
every board of every installation, unchanged.

## Still deferred

- A run-time failure after spawn — the agent dies mid-session. Recording that
  needs the tick's reconcile to read the agent log, not dispatch. It is the
  harder half of PRA-451.
- Review deliberately on a different harness than the build. The candidate
  syntax already permits it; the policy that chooses it does not exist yet.
