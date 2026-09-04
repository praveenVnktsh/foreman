# A plan the operator can answer

**Status:** awaiting review. Supersedes the first draft of this file, which
designed a `Plan` column that already exists and behaves differently.

## What is already there

`Plan` shipped as the build agent's planning phase made visible. Step 6
dispatches `Todo → Plan` and spawns; one agent plans and implements in a single
session; `reconcile.py` reports `plan: plan_pushed(branch_for(ticket))`; and once
a plan is on the branch with no pull request yet, step 2 moves the card to
`In Progress` and leaves the agent running. The card holds a slot throughout,
because an agent is running on it.

None of that changes. The column is right; it just cannot be interrupted.

## Decision

**One operator-written label, `needs-plan`, turns an existing transition into a
gate.** A card carrying it does not auto-advance out of `Plan` when its plan
lands. It parks: the plan is posted to the card, the slot is released, and the
board waits — indefinitely — for the operator. Comments arriving while it waits
resume the same agent to revise the plan. Removing the label is the sign-off,
and the card advances exactly as it does today.

The whole change is a guard on one bullet. With no `needs-plan`, every code path
is the one that runs now.

## Why a label and not a state

The first draft made `Plan` operator-exit-only. That contradicts what `Plan`
already is — the board moves cards out of it on every tick — and would have made
one column mean two things depending on which rule you read.

A label carries the second meaning instead, which keeps the column's default
behaviour untouched for every card nobody labelled. It also matches how the board
already waits for a human: `needs-merge` parks a card in `In Review` rather than
moving it somewhere new.

`needs-plan` is the first **operator-written, board-read** label. Every existing
label is written by the board and read by a human. The Labels table grows a row
saying so, and `resolve-ids.py` creates it if missing, because a label the
operator is expected to apply has to exist before they can apply it.

**No second label records sign-off.** `plan.state: present` already tells the
board a plan exists, and the absence of `needs-plan` already tells it the operator
is done. A `plan-written` label would be a third encoding of a fact two sources
already carry.

## The gate

Step 2's existing bullet — *card in `Plan`, plan present, no pull request → move
to `In Progress`* — gains one condition:

- **plan present, no `needs-plan`** → move to `In Progress`. Today's behaviour,
  unchanged.
- **plan present, `needs-plan`** → park. Post the plan comment, log
  `{"action":"released","reason":"parked: awaiting plan sign-off"}` once, and
  leave the card in `Plan`.
- **plan present, `needs-plan`, unconsumed operator comments** → resume the agent
  with them, round += 1, card does not move.
- **`MAX_PLAN_ROUNDS` reached** → back to `Backlog` with `board-failed` and a
  `released` entry, as `MAX_REVIEW_ROUNDS` already does.

Every other bullet in step 2 — phase classification, stalls, environmental
write-offs, attempts, deaths — reads identically. A parked card's agent is idle
and alive; that is what `phase` is for.

## Answering

The board writes to Linear through MCP, which acts as the operator's own user, so
its comments and theirs share an author and there is nothing to discriminate on.
A timestamp watermark loses the obvious race: a comment written while the agent is
still revising is older than the plan it then posts, and would be swallowed unread
— the worst available failure for a column whose purpose is that the operator can
talk to it.

**So every plan comment declares what it consumed**, in a footer:

    <!-- foreman:plan round=2 consumed=a1b2c3,d4e5f6 -->

Unconsumed input is any comment whose id appears in no `foreman:plan` footer on
that card. That is derivable from Linear alone — no sidecar, no clocks, no
ordering assumption — and a comment landing mid-revision is simply absent from the
next footer, so the following tick picks it up.

`plancomments.py` computes it. It is a **pure filter**: comment JSON on stdin, the
unconsumed ids and the next footer on stdout. No network and no Linear key, because
`reconcile.py` has never held one and this is not the change that should give it
one.

**Answering resumes the same agent**, structurally identical to sending blocking
review findings back to a build: `brief.py replan` renders the unconsumed comments,
`dispatch.sh --resume` continues the session that already read the code. Where the
worktree is gone — `--resume` refuses outright, correctly — the fallback is a fresh
dispatch given the pushed plan and the comment thread. It loses context and
re-reads; the card keeps moving.

**A comment that asks for nothing is not a special case.** The agent is handed it
and either revises or replies that nothing changed. Judging that before dispatch
would mean the board deciding whether the operator said anything worth acting on.

**The operator's text is fenced, not quarantined.** `quote_untrusted` exists because
another *agent* wrote the findings it wraps. The operator is the authorising
principal, so their words are not a privilege boundary — but `replan` still fences
each comment so a pasted snippet cannot read as an instruction.

## Slots

Step 6 counts cards in `Plan` against `MAX_CONCURRENT` because *"a card in `Plan`
holds an agent"*. A parked card does not: its agent is idle and only a human's
decision is outstanding. It logs `released` once, on the tick it parks, exactly as
a `needs-merge` card does.

That sentence in step 6 gains its exception, and `HOST_SLOT_STALE_MINUTES` remains
the backstop for a missed marker — it matters more here than anywhere, because a
card can legitimately sit parked for days.

## What changes

- `bin/contract.py` — `MAX_PLAN_ROUNDS` in `LIMITS`, declarable per target in
  `board.toml`'s `[limits]`. Not in `LIMIT_MINIMUMS`: zero means the plan is
  posted and never revised, which idles the conversation without disarming a gate.
- `bin/resolve-ids.py` — `LABEL_NEEDS_PLAN` in `LABEL_ROLES`. A `[risk]` path, so
  this parks for a human merge by construction.
- `skills/board/plancomments.py` — new; the footer protocol.
- `skills/board/brief.py` — a `replan` subcommand, modelled on `fix`.
- `skills/board/reconcile.py` — plan rounds counted from `history.jsonl`, as
  `build_attempts` already is.
- `skills/board/SKILL.md` — the Labels row, the guarded bullet in step 2, the
  comment protocol, and the slot exception in step 6.

**No new step, so nothing renumbers**, and the hand-written step cross-references
throughout the file stay correct. `config.sh` does not change — limits load from
`board.toml` through `contract.py`. `dispatch.sh` does not change — there is no new
role, only a resume of the agent the card already has.

## What deliberately does not change

**No timeout on sign-off.** A parked card waits until the operator returns.
`needs-merge` already waits forever for the same reason: proceeding on the board's
own assumptions after a window is the board approving its own plan on a delay.

**Nothing else waits.** An unlabelled card is planned, built, reviewed and merged
with no human present, exactly as today.

**Follow-ups do not inherit `needs-plan`.** Copying it onto a follow-up would have
the board queueing interactive work for itself.

## Open questions

1. **Does the plan comment repost whole each round, or edit in place?** Whole is
   append-only and matches the footer protocol; in-place keeps the card readable
   but makes "what did round 2 consume" unanswerable from Linear.
2. **Should `needs-plan` survive sign-off as a record?** Removing it is the
   signal, so the card ends with no trace it was ever planned interactively. The
   `history.jsonl` entries hold it, but the sidecar is a cache, never truth.
