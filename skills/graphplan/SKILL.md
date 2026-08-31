---
name: graphplan
description: "Plan and drive a whole task, from a cold start to a merged pull request. Use at the beginning of any non-trivial piece of work, before writing code. Produces one self-contained mermaid dependency graph as the plan, then executes it with parallel subagents, tests it, reviews it adversarially, and ships it. Use when asked to build, implement or add a feature, or when a task is large enough that the order of work matters."
---

# Graphplan

Five stages. Do not start one before the stage above it has passed its gate.

| Stage | Output | Gate |
|---|---|---|
| 1. Plan | one mermaid graph | the operator approves the graph |
| 2. Implement | code on a branch | every node in the graph is done |
| 3. Test | a green run of the target's test command | it actually ran, and passed |
| 4. Review | fixes for blocking findings | one round only |
| 5. Ship | a merged pull request | CI green, comments answered |

## Stage 1: Plan

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

## Stage 2: Implement

Translate the graph into one Workflow script. The mapping is mechanical:

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

## Stage 3: Test

Run the target's own command. Read it from the contract rather than guessing:

```bash
bin/contract.py board.toml | tr '\0' '\n' | grep -A1 TEST_COMMAND
```

Fan out only what is genuinely independent — a long suite split by directory, or
one agent per failing test. One green run of the whole suite at the end is what
the gate needs, and a fanned-out run does not replace it.

**A test you did not watch run is not a passing test.** Quote the output.

## Stage 4: Review

Run the `adversarial-reviewer` skill. **Once.**

- Fix every blocking finding.
- A finding you believe is wrong gets refuted with evidence, not ignored. Read
  the file as the remote has it with `skills/board/evidence.sh`, reproduce the
  stated failure path, and say what you ran.
- Do not re-run the reviewer after fixing. A second round on a diff the first
  round shaped finds the fixes, not the defects, and costs a full pass to learn
  nothing.

## Stage 5: Ship

1. Open the pull request. Ready for review, never a draft — a draft cannot be
   merged, so it blocks after its checks are green.
2. Watch the checks. `gh run watch`, or poll `gh pr checks`. An empty check list
   is not a pass: it means the build never queued, and an empty commit produces
   the `synchronize` event that starts it.
3. A red check is fixed on the same branch, not worked around.
4. Answer every review comment. Answering means a reply and a commit, or a reply
   explaining why no commit.
5. Merge.

**Do not merge if the board dispatched you.** `skills/board/brief.py` tells a
dispatched agent *"Do not merge, and do not enable auto-merge"*, and it is right:
merging deploys, and the board decides that after its own review rounds. In a
board-dispatched session this stage ends at step 4.

**In any other session, merging is the operator's call.** Ask before you do it.

## Red flags

| Thought | Reality |
|---|---|
| "I will plan as I go" | Then the work is serial. That is what the graph prevents. |
| "The graph needs a paragraph to explain it" | Then the graph is wrong. Fix the graph. |
| "Everything is opus · max" | You priced the plan, you did not plan it. |
| "These two nodes both touch that file" | They are one node, or they are sequential. |
| "I will add an edge to be safe" | A false edge costs the parallelism you planned for. |
| "The suite is probably green" | Run it. Quote it. |
| "One more review round" | Round two finds the fixes, not the defects. |
| "CI is red but unrelated" | It is red. Fix it on this branch. |
