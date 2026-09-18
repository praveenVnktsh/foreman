# One tick, every board, dispatching to whichever harness works

## Goal

One foreman installation serves all of an operator's boards. For each stage it
dispatches to a chosen `harness:model`, falling back across models and across
CLIs when a provider is rate-limited or its quota is spent. There is one tick,
one clone and one lock, and no routing.

## What it replaces

The earlier design
([2026-09-14-installations-per-harness-design.md](2026-09-14-installations-per-harness-design.md))
bound one harness and four models to an installation and routed cards to
installations by a `foreman:<name>` label, with one installation the default for
unlabelled cards. Several installations are still supported for an operator who
wants them, but they are no longer the shape the loop is designed around: with a
single tick that owns every project there is nothing to route.

## The model

- `installation.toml` `[models]` names each stage's first-choice model. A value
  is `model` or `harness:model`.
- `[fallback]` names the ordered `tiers`, an optional `cooldown_minutes`, and an
  optional per-stage `[fallback.floor]`. A tier is `model` or `harness:model`.
- `dispatch.sh` asks `fallback.py` for the model: it walks down from the stage's
  first choice while the current tier is stamped rate-limited, never below the
  stage's floor. Reaching the floor and finding it limited too voids the card,
  as before -- the board waits rather than fall past a model declared safe.
- A model is stamped when a **spawn** refuses it (the adapter's stderr matches
  the rate-limit set), or when an agent **dies mid-run** on an API rate-limit
  error `reconcile.py` reads from the transcript. A stamp expires on its own.
- `config.sh` derives the harness set from the tiers and stage models, and
  `HARNESS_SH` is `skills/board/harness/registry.sh`: it merges each harness's
  agent registry for `list`/`reap`, routes `stop`/`transcript` to the adapter
  that owns the agent, and delegates the harness-shaped verbs to the
  installation's default harness.
- The tick records the harness and the model on each spawn, so `reconcile.py`
  can name the model that was actually refused and the harness that owns the
  agent.

## Quota

Providers do not expose remaining quota over the API, so dispatch reacts to
refusals rather than reading a number: a model is "available" until it refuses,
then benched for the cooldown. The measure is "this model refused", never "X
percent left".

## Deferred

- Cross-harness resume. A resumed agent reconnects on the installation's default
  harness, not the one that spawned it; the adapter's `resume` verb takes no
  model and no harness.
- Removing the `foreman:<name>` label and the default-installation rule for
  operators who keep several installations. Nothing in this design needs them;
  they are kept for the multi-installation case.
