---
name: graphplan
description: "Draw the architecture of a proposed change as one mermaid diagram, with the build order falling out of it. Use at the very beginning of any non-trivial piece of work, before writing code, and before deciding what to parallelise. Produces the plan and stops; AGENTS.md covers implementing and testing it, and the board owns review and merge. Use when asked to build, implement, add or design a feature, or when a task is large enough that the order of the work matters."
---

# Graphplan

Turn a task into one dependency graph, and stop there. `AGENTS.md` covers what
happens after: implement and test. Review and merge belong to the board, not to
you. This skill owns the plan and the contract it is written in.

## Plan

**The plan is drawn by a `fable` agent.** That is where the strongest model is
spent: once, on the design, before any code exists. Everything downstream is
only as good as this graph — a node whose label is wrong is wrong in every file
that node owns — and no build agent that runs a node ever gets to revisit it.
The board launches its planning stage with `--model fable` for this reason
(`PLAN_MODEL` in `skills/board/config.sh`).

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

**A node is a component of the system, not a task.** A file, a process, a data
store, an external service. The graph is what the thing *is* once it is built.

Every node label carries:

- an id, so edges and reports can name it
- what the component is, and what it holds or does
- its build state: `NEW`, `CHANGE`, or nothing at all if it is untouched context
- for `NEW` and `CHANGE` only, the model tier that builds it

```
c4["<b>c4 · config.sh</b> · CHANGE<br/>loads one board into the environment<br/>sourced per board in a subshell<br/><i>opus · high</i>"]
```

**Untouched components belong in the graph.** They are how a fresh agent
understands what it is building into. A graph showing only the new parts is a
task list again.

**Two nodes must never own the same file.** They get built in parallel; the
later write wins and the earlier work vanishes with no error.

### What an edge is

A real relationship in the built system: reads, writes, spawns, depends on.
Label it with the verb.

**Do not draw an edge for tidiness.** An edge is a claim about how the system
works, and a false one is a false claim before it is a scheduling mistake.

### The work order falls out of the graph

This is the whole return on drawing the architecture rather than a task list:

- Two `NEW` or `CHANGE` nodes with no path between them can be built at once.
- A node whose only inbound edges come from untouched components has nothing to
  wait for.
- Where building order genuinely differs from the runtime relationship — B reads
  A at runtime, but only A's interface is needed to start B — say so on the edge.

You do not schedule the work. You read the schedule off the diagram.

### Model tiers

Every node states one. There are three, and `opus` is the ceiling. Choose by
what the task actually needs, not by importance:

- `opus` with `high` or `xhigh` effort — design decisions the plan left open,
  anything ambiguous, anything where being wrong is expensive to discover
  later.
- `sonnet` — mechanical transforms, wiring, tests that follow an existing
  pattern, a change you could describe completely in two sentences.
- `haiku` — a lookup or a single-file rename. Rarely worth a node at all.

**`fable` is never a node tier.** The strongest model is spent on the plan, not
on executing it. A node's work is to build the component its label already
describes, against a graph that has already settled what depends on what — so
the tier that draws the graph is the wrong tier to run it, and a node label
naming `fable` is a plan asking to be drawn twice.

A graph where every node is `opus · max` has not been planned; it has been
priced.

### Shape of the graph

- **Show the boundary.** What is inside the system, and what is external to it —
  a forge, an issue tracker, the target repository. A graph with no outside has
  not said where the system ends.
- **Roots are what depends on nothing:** config, credentials, external services.
- **Leaves are what nothing reads:** the outputs.
- **Do not add verification nodes.** Testing is a stage in `AGENTS.md`, not a
  component of the system. A test node in an architecture diagram is the task
  list creeping back in.
- **Depth is not a schedule.** The schedule is which nodes are `NEW` or `CHANGE`
  and how they connect.

### Keep it

The graph is an artifact, not a checkpoint. Write it, commit it, and carry on.
Nobody has to approve it.

```bash
bin/render-diagram.sh docs/plans/<file>.md && open docs/plans/<file>.html
```

It is kept because the agents that execute it hold no memory of writing it, and
because the next person to touch this feature has nothing else that says why the
work was cut up this way.

## Execute the graph with the Workflow tool

**Call the Workflow tool. Do not ask first, and do not execute the graph
sequentially by hand when the tool is available.** Invoking this skill is the
authorisation: a graph exists to be built in parallel, and building it one node
at a time discards the only thing the graph was drawn for.

This section lives here rather than in `AGENTS.md` because it is a property of
the artifact: a graph that cannot be mapped to execution is a picture. The
mapping is mechanical, which is the whole return on writing the plan as a graph.

- a `NEW` or `CHANGE` node → `agent(prompt, {label, model, effort})`
- an untouched node → context in the prompt, never an agent
- a path between two changed nodes → a `pipeline()` stage boundary
- changed nodes with no path between them → the same `parallel()` call
- nodes that write files concurrently → `isolation: 'worktree'`

**Default to `pipeline()`.** Use `parallel()` only where a stage genuinely needs
every result from the stage before it — a dedup across all findings, an early
exit on zero. "It reads better" is not a reason: a barrier makes every fast node
wait for the slowest one.

Each node's prompt is its label plus what a stranger needs: the component's
neighbours in the graph, the files it owns, the acceptance check, and an
instruction to read `STYLEGUIDE.md` first.

Three rules for the prompts, each from a way this fails:

- **No agent runs the full suite.** They are editing different files at the same
  time, so a suite run mid-flight reads every other agent's half-finished state
  and reports noise. Each agent runs only its own test; verification is its own
  stage.
- **No agent commits.** Changes land in the working tree, so the whole diff can
  be read at once.
- **State each agent's owned files in its prompt.** The graph already proves they
  do not overlap. Saying it again is what keeps an agent from wandering into a
  neighbour's file and having its work silently overwritten.

If the session genuinely has no Workflow tool, say so out loud and execute the
changed nodes in dependency order yourself. Do not silently serialise and call it
done.

## Red flags

| Thought | Reality |
|---|---|
| "I will plan as I go" | Then the work is serial. That is what the graph prevents. |
| "The graph needs a paragraph to explain it" | Then the graph is wrong. Fix the graph. |
| "Everything is opus · max" | You priced the plan, you did not plan it. |
| "This node should run on fable" | fable drew this graph. It never executes one; opus is a node's ceiling. |
| "These two nodes both touch that file" | They are one node, or they are sequential. |
| "I will add an edge to be safe" | An edge is a claim about the system. A false one is a false claim. |
| "Only the new parts belong in the graph" | Then it is a task list. Untouched components are how a stranger reads it. |
| "Now let me work out the build order" | Read it off the diagram. That is what the diagram is for. |
| "Should I use a workflow for this?" | Yes. Invoking this skill already answered that. |
