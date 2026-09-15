# Scheduled cleanup, and a review that runs once

## Goal

Review costs too many rounds and step 7 files too many cards. Each merged card
can write three follow-ups, most of them no-ops, and the tokens spent on them
keep growing. This design moves quality work out of the review loop and into two
cleanup passes:

1. **Self-cleanup in the build.** The build agent runs `/simplify` on its own
   diff before it opens the pull request.
2. **Scheduled cleanup.** Every `every_days` days, one agent reads the whole
   codebase and what merged since its last run. It files **at most one** card,
   well scoped and already planned. It is the only thing that files cards.

Review then runs once. It gates only on `blocking` findings. A blocking finding
buys exactly one fix, and the fix merges with no re-review.

## 1. Build: `/simplify` before the pull request

`brief.py build` gains one step between "tests pass" and "open the pull
request": invoke the built-in `/simplify` skill on the branch's diff, then re-run
the target's test command. The pass covers the diff only. Refactors outside it
belong to the scheduled cleanup.

`/simplify` exists only in Claude Code. On a codex or opencode installation the
brief says to skip the step and say so in the report. It never says to imitate
the skill by hand.

## 2. Review: one round, blocking only

### Reviewer

`brief.py review` is unchanged in substance. It keeps the `adversarial-reviewer`
skill with all four personas and the `blocking | warning | note` mapping. Only
`blocking` gates. `warning` and `note` stay in the review file, because the
scheduled cleanup reads them.

### Limits

`bin/contract.py` defaults change:

| Limit | Was | Now |
|---|---:|---:|
| `REVIEWERS_PER_ROUND` | 2 | 1 |
| `MAX_REVIEW_ROUNDS` | 2 | 1 |

`LIMIT_MINIMUMS` keeps both at 1, so review cannot be disarmed.

### Flow (`SKILL.md` §3)

- **No blocking findings** → step 4, as today.
- **Blocking findings, round 1** → card to `In Progress`, resume the build with
  `brief.py fix`. When the fix is pushed and `checks.passing`, go to step 4
  **without dispatching another reviewer**. Log
  `{"action":"merged-after-fix","round":1}` before the merge.
- **The fix agent reports it could not resolve a finding** → `Needs Human` with
  `board-failed` and the findings attached, logged as
  `released` with reason `board-failed: fix unresolved`.
- `brief.py fix` drops the "say so in a pull request comment if you believe a
  finding is wrong" route. The agent fixes the finding or reports that it cannot.
  The tick's own bar in *Refuting a blocking finding* is unchanged.
- Step 4 is unchanged: `[risk] paths` still park for the operator, and the draft,
  behind-main and migration checks still apply.

`reconcile.py` must stop reading "round 1 done, fix pushed" as "dispatch round
2". A card whose round-1 review blocked and whose fix is pushed and green is
`mergeable`, not `needs-review`.

### Step 7 removed

`SKILL.md` §7 *Follow-ups* is deleted. `MAX_FOLLOWUPS` is removed from `LIMITS`.
A `board.toml` that still sets `max_followups` loads with a one-line deprecation
warning on stderr, not a refusal. `LABEL_FOLLOW_UP` and
`LABEL_FOLLOW_UPS_WRITTEN` stay in `resolve-ids.py` so existing cards keep
resolving. Nothing writes them.

## 3. Scheduled cleanup

### Config

```toml
[cleanup]
every_days = 7        # 0 = off; the default
model = "opus"        # optional; defaults to PLAN_MODEL
max_plan_nodes = 8    # a larger plan, or one touching [risk] paths, waits for the operator
```

`contract.py` exports `CLEANUP_EVERY_DAYS`, `CLEANUP_MODEL` and
`CLEANUP_MAX_PLAN_NODES`. `every_days` and `max_plan_nodes` must be integers
`>= 0`. With `max_plan_nodes = 0`, every cleanup card waits for sign-off.

### When it runs

The tick keeps no state, so "due" comes from a stamp file
`instances/<board>/last-cleanup`, the same pattern as `last-served`.

`reconcile.py --cleanup-due <board>` prints `due` and exits 0 when all of these
hold, and otherwise prints the first reason it is not due and exits 1:

- `CLEANUP_EVERY_DAYS > 0`
- the stamp is missing, or older than `every_days`
- no agent named `foreman/[<inst>/]<board>/cleanup/…` is alive
- the board has a free concurrency slot, and so does the host

The tick asks at the **end** of each board's slice, after cards have been
handled, so cleanup never displaces card work. If the answer is `due`, the tick
writes the stamp, then dispatches. Writing the stamp first means an agent that
dies, or files nothing, does not come back on the next tick.

`boardctl cleanup <board>` deletes the stamp, so the next slice runs one.

### What the agent does

`brief.py cleanup --board <board> --since <stamp-iso>` writes the prompt. The
role is `cleanup`, the model is `CLEANUP_MODEL`, and the worktree is fresh from
`origin/main`. The agent:

1. **Gathers** the codebase at `origin/main`, the pull requests merged since
   `--since`, and the `warning` and `note` findings in those cards'
   `reviews/*.json`.
2. **Verifies** each candidate with `evidence.sh main …` and drops anything
   already fixed. It searches the board's open cards and drops anything already
   filed.
3. **Picks one**, the candidate with the most value. If none survives, it files
   nothing and says so in its report. The rest are not queued; the next run
   re-derives them.
4. **Plans** by invoking `graphplan`, then runs `bin/check-plan-graph.py`. It
   counts the nodes and compares the paths the plan touches against
   `HIGH_RISK_PATHS`.
5. **Files one card** in `Plan`, in this board's project, labelled `cleanup`.
   The description has:
   - the problem, with file, line and the `evidence:` line and its SHA
   - in scope: the exact files and behaviour
   - out of scope, stated explicitly
   - done when: the tests that prove it
6. **Posts the graph** as the plan comment, with the footer
   `plancomments.py` prints for round 1.
7. **Gates it.** If the plan has more than `CLEANUP_MAX_PLAN_NODES` nodes, or
   touches a `[risk]` path, it adds `needs-plan`. Otherwise it leaves the label
   off, and step 2 builds the card on a later tick like any planned card.

The agent never pushes a commit and never opens a pull request. The brief says
so, and the brief's own test checks that it says so.

### Invariant change

`SKILL.md` currently says only the operator writes `needs-plan`. New wording:
**only the operator removes `needs-plan`. The cleanup agent may add it, and only
to the card it just created.** This can only make the gate stricter.

`resolve-ids.py` gains `LABEL_CLEANUP` (`cleanup`).

## Tests

All drive the real script and stub at the Linear and harness boundary.

- `test-contract.sh`: `[cleanup]` parses. `every_days = 0` is off. Negative
  values are refused. `max_followups` warns and does not refuse. The new review
  defaults are 1 and 1.
- `test-cleanup-due.sh`: no stamp → due. Fresh stamp → not due. Stale stamp →
  due. Live cleanup agent → not due. No free slot → not due. `every_days = 0` →
  not due.
- `test-brief-cleanup.sh`: the brief names the one-card cap, the `needs-plan`
  rule, `evidence.sh` and "never push, never open a pull request".
- `test-brief-build-simplify.sh`: the claude build brief invokes `/simplify`
  before opening the pull request. The codex and opencode briefs say to skip it.
- `test-review-single-round.sh`: blocking → one fix → green → `mergeable` with no
  round-2 dispatch. A fix reporting unresolved → `Needs Human`.
- `test-no-followups.sh`: `SKILL.md` has no follow-up step.
- `test-boardctl.sh`: `boardctl cleanup` removes the stamp.

## Out of scope

- Cleanup agents that push code or open pull requests.
- Changing the `adversarial-reviewer` skill.
- Migrating or closing existing `follow-up` cards. The operator triages those.
