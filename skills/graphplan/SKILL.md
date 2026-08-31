---
name: graphplan
description: "Turn a task into one mermaid dependency graph that a fresh subagent can execute. Use at the very beginning of any non-trivial piece of work, before writing code, and before deciding what to parallelise. Produces the plan and stops; implementing, testing, reviewing and shipping it are the loop in AGENTS.md. Use when asked to build, implement, add or design a feature, or when a task is large enough that the order of the work matters."
---

# Graphplan

Turn a task into one dependency graph, and stop there. `AGENTS.md` owns what
happens after: implement, test, review, ship. This skill owns the plan and the
contract the plan is written in.

## Plan

**Read before you plan.** Name what you read: the task, the files it touches,
`STYLEGUIDE.md`, `AGENTS.md`, and the surrounding code. A plan written before
reading is a guess with a diagram attached.

**The plan is one mermaid graph and nothing else.** Write it to
`docs/plans/<date>-<topic>.md` as a single ```mermaid block. No prose above it,
none below it. If something matters, it is a node or an edge. If it will not fit
in the graph, it is not part of the plan.

That constraint is the point. Prose lets a plan stay vague about what depends on
what, and the vagueness is exactly what makes the work serial. A graph cannot be
vague about dependencies: either the edge is there or it is not.

**The graph must be executable by someone with no memory of this conversation.**
That is not a style preference. The agent that runs a node is a fresh subagent
with none of your context. If a node's label does not say what to do, the node
cannot be done.

### What a node is

One node is one subagent task. Every node label carries four things:

- an id, so edges and reports can name it
- what to do, in an imperative sentence
- the model tier
- the files it owns

```
n3["<b>n3 · brief.py</b><br/>add --lens to review(); slot a gets correctness, b design<br/><i>opus · high</i><br/>skills/board/brief.py"]
```

**Two nodes must never own the same file.** They run in parallel; the later
write wins and the earlier work vanishes with no error. If two pieces of work
touch one file, they are one node or they are sequential.

### What an edge is

A real dependency: the target cannot start until the source has finished.

**Do not draw an edge for tidiness.** Every edge you add that is not a genuine
dependency serialises work that could have run in parallel, and that is the cost
this whole skill exists to avoid. If you are unsure whether B needs A, ask
whether B's subagent could do its job with A's files unchanged. If yes, no edge.

### Model tiers

Every node states one. Choose by what the task actually needs, not by
importance:

- `opus` with `high` or `xhigh` effort — design decisions, anything ambiguous,
  anything where being wrong is expensive to discover later.
- `sonnet` — mechanical transforms, wiring, tests that follow an existing
  pattern, a change you could describe completely in two sentences.
- `haiku` — a lookup or a single-file rename. Rarely worth a node at all.

A graph where every node is `opus · max` has not been planned; it has been
priced.

### Shape of the graph

- Roots are nodes that need nothing. There should be several. One root means the
  work is serial and the graph is not earning its keep.
- Leaves are verification. The last thing on every path is something that
  checks, not something that writes.
- Rank is a wave. Nodes at the same depth run together.

### Gate

Render it and show the operator:

```bash
bin/render-diagram.sh docs/plans/<file>.md && open docs/plans/<file>.html
```

Stop. Do not implement until they approve the graph. A plan is the cheapest
place to be wrong, which is the only reason to write one.

## How the graph is executed

This belongs here rather than in `AGENTS.md` because it is a property of the
artifact: a graph that cannot be mapped to execution is a picture. The mapping
is mechanical, which is the whole return on writing the plan as a graph.

- a node → `agent(prompt, {label, model, effort})`
- an edge → a `pipeline()` stage boundary
- nodes at one rank with no edges between them → the same `parallel()` call
- nodes that write files concurrently → `isolation: 'worktree'`

**Default to `pipeline()`.** Use `parallel()` only where a stage genuinely needs
every result from the stage before it — a dedup across all findings, an
early exit on zero. "It reads better" is not a reason: a barrier makes every fast
node wait for the slowest one.

Each node's prompt is its label plus what a stranger needs: the files it owns,
the acceptance check, and an instruction to read `STYLEGUIDE.md` first.

If the session has no Workflow tool, say so and execute the graph in rank order
yourself. Do not silently serialise and call it done.

## Red flags

| Thought | Reality |
|---|---|
| "I will plan as I go" | Then the work is serial. That is what the graph prevents. |
| "The graph needs a paragraph to explain it" | Then the graph is wrong. Fix the graph. |
| "Everything is opus · max" | You priced the plan, you did not plan it. |
| "These two nodes both touch that file" | They are one node, or they are sequential. |
| "I will add an edge to be safe" | A false edge costs the parallelism you planned for. |
