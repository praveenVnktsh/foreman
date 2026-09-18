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

## Deferred, deliberately

- Project-scoped installs: removing `route.py`/`queue.py` routing and the
  default-installation rule.
- The multi-harness runner and a unified agent registry. Codex and OpenCode
  share `harness/detached.sh`'s registry; Claude uses its own daemon, and that
  difference is the whole of the runner's cost.
- A run-time failure after spawn — the agent dies mid-session. Recording that
  needs the tick's reconcile to read the agent log, not dispatch. It is the
  harder half of PRA-451 and belongs with the runner.
- Cross-harness candidates, and review deliberately on a different model than
  the build.
