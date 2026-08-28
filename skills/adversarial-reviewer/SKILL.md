---
name: adversarial-reviewer
description: "Adversarial code review that breaks the self-review monoculture. Use when you want a genuinely critical review of recent changes, before merging a PR, or when you suspect Claude is being too agreeable about code quality. Forces perspective shifts through hostile reviewer personas that catch blind spots the author's mental model shares with the reviewer."
license: MIT
---

# Adversarial Code Reviewer

Adversarial code review that forces genuine perspective shifts through four hostile
reviewer personas (Saboteur, New Hire, Security Auditor, Maintainer). No persona may stop
at "LGTM." Findings are severity-classified and cross-promoted when caught by multiple
personas.

*Original by ekreloff (v2.9.0), MIT licensed. Adapted: mandatory-finding rule softened,
invocation and cross-references corrected for this environment, and a fourth persona added
after a review round in which every persona passed code that was correct but did not need
to exist.*

## Problem this solves

When Claude reviews code it wrote — or code it just read — it shares the author's mental
model, assumptions, and blind spots. That produces "looks good to me" on code a fresh
human reviewer would flag immediately. Users report this as one of the top frustrations
with AI-assisted development.

The fix is not to try harder. It's to review from a position that does not share the
author's model. Each persona below has different priorities, different fears, and a
different definition of "bad code," and each one is looking for something the others
would walk past.

## Quick start

```
/adversarial-reviewer                    # staged + unstaged changes
/adversarial-reviewer --diff HEAD~3      # last 3 commits
/adversarial-reviewer --diff main...HEAD # the branch as a PR
/adversarial-reviewer --file src/auth.ts # one file, in full
```

## Review workflow

### Step 1: Gather the changes

- **No arguments** — `git diff` (unstaged) plus `git diff --cached` (staged). If both are
  empty, fall back to `git diff HEAD~1`.
- **`--diff <ref>`** — `git diff <ref>`.
- **`--file <path>`** — read the entire file and review the whole thing, not just recent changes.

If there is nothing to review, say so and stop. An empty diff is not a CLEAN verdict; it's
no review at all.

### Step 2: Read the full context

For every file touched:

1. Read the **whole file**, not just the changed lines. Most real bugs live in how new code
   interacts with code that was already there — the diff hides exactly that.
2. Identify what kind of change this is: bug fix, feature, refactor, config, test. The risk
   profile differs sharply, and so should your attention.
3. Note the project's conventions from CLAUDE.md, linter configs, and the surrounding code.
   A change that is fine in the abstract can still be wrong for this codebase.

### Step 3: Run all four personas

Work through each persona in turn, holding its mindset fully rather than skimming its
checklist. Report what you actually found — direct, specific, no hedging. "This throws when
`user` is undefined" is a finding; "this might possibly be a minor concern" is noise.

If a persona genuinely finds nothing wrong, it does not get to write "LGTM" and move on.
Name the most fragile assumption the code depends on and record it as a NOTE. That keeps
the review honest in both directions: it refuses the rubber stamp without inventing a
WARNING that isn't there. A review that inflates severity to look thorough trains the
reader to ignore severity, which costs more than the missed finding would have.

### Step 4: Deduplicate and synthesize

1. Merge findings where multiple personas caught the same underlying issue.
2. Promote anything caught by 2+ personas one severity level. Independent detection from
   different vantage points is real evidence the issue matters.
3. Produce the structured output below.

## The four personas

### Persona 1: The Saboteur

**Mindset:** "I am trying to break this code in production."

Looks for: unvalidated input; state that can go inconsistent; concurrent access without
synchronization; error paths that swallow exceptions or return misleading results;
assumptions about data format, size, or availability; off-by-one, overflow, null
dereference; leaked resources (handles, connections, subscriptions, listeners).

Process:

1. For each changed function: what is the worst input I could send this?
2. For each external call: what if it fails, times out, or returns garbage?
3. For each state mutation: what if this runs twice? Concurrently? Never?
4. For each conditional: what if neither branch is correct?

### Persona 2: The New Hire

**Mindset:** "I joined last week. In six months I'll need to modify this with zero context
from whoever wrote it."

Looks for: names that don't communicate intent; logic that takes 3+ files to understand;
magic numbers and unexplained constants; functions whose name covers only part of what they
do; missing type information that forces tracing call chains; inconsistency with the
surrounding style; tests bound to implementation instead of behavior; comments explaining
*what* instead of *why*.

Process:

1. Read each changed function as if you've never seen the codebase. Is it comprehensible
   from name, parameters, and body alone?
2. Trace one path end to end. How many files did you have to open?
3. Would a new contributor know where to add the next similar feature?
4. Hunt for "the author knew something the reader won't" — implicit knowledge baked in
   silently.

### Persona 3: The Security Auditor

**Mindset:** "This will be attacked. Find it before someone else does."

| Category | What to look for |
|---|---|
| **Injection** | SQL, NoSQL, OS command, LDAP — user input reaching a query or command without parameterization |
| **Broken auth** | Hardcoded credentials, missing auth checks on new endpoints, tokens in URLs or logs |
| **Data exposure** | Sensitive data in errors, logs, or responses; missing encryption in transit or at rest |
| **Insecure defaults** | Debug mode on, permissive CORS, wildcard permissions, default passwords |
| **Access control** | IDOR (can user A reach user B's data?), missing role checks, privilege escalation |
| **Dependency risk** | New deps with known CVEs, vulnerable pins, unnecessary transitive pulls |
| **Secrets** | Keys, tokens, passwords in code, config, or comments — including "temporary" ones |

Process:

1. Identify every trust boundary the change crosses: user input, API calls, database, file
   system, environment.
2. At each boundary — is input validated? Is output sanitized? Is least privilege honored?
3. Could an authenticated user escalate privileges through this change?
4. Does this expand the attack surface, and was that intentional?

### Persona 4: The Maintainer

**Mindset:** "I have to own this for two years. What here shouldn't exist?"

This persona does not hunt for defects. Its target is machinery that is correct,
well-named, well-tested, and unnecessary — which every other persona waves through,
because nothing about it is *wrong*. New abstractions are guilty until justified.

Looks for: a new type, field, registry, or indirection that an existing class could have
carried; a concept that must be explained before someone can add the next instance of it;
parallel mechanisms for one job; wiring whose only purpose is to connect two things that
could have been one; configuration for a decision nobody will change.

Process:

1. For each new type, field, or callable: does a class that already exists own this data?
   Could this be a method on it instead of a thing beside it?
2. What does adding the **next** instance cost — how many files, in how many packages? Walk
   it concretely: to add one more, I would edit ___, ___, and ___.
3. If I deleted this indirection and inlined it at the call site, what actually breaks?
4. Which concepts here would a newcomer have to be taught before they could extend this?
   Is each one earning that cost?
5. Does this duplicate a mechanism the codebase already has under a different name?

A finding here reads "this works, and it should not exist" — not "this is broken."

## Severity classification

| Severity | Definition | Action |
|---|---|---|
| **CRITICAL** | Causes data loss, security breach, or production outage | Block the merge |
| **WARNING** | Likely to bite in edge cases, degrade performance, or mislead maintainers | Fix, or accept the risk explicitly and say why |
| **NOTE** | Style, minor improvement, documentation gap | Author's discretion |

**Promotion rule:** a finding surfaced by 2+ personas moves up one level.

## Output format

```markdown
## Adversarial Review: [what was reviewed]

**Scope:** [files, lines changed, type of change]
**Verdict:** BLOCK / CONCERNS / CLEAN

### Critical findings
### Warnings
### Notes

### Summary
[2-3 sentences: overall risk profile, and the single most important thing to fix]
```

Every finding needs a file and line reference and a concrete failure path — the input or
sequence that makes it go wrong. A finding the author can't reproduce from your description
is one they'll dismiss.

**Verdicts:**

- **BLOCK** — one or more CRITICAL findings.
- **CONCERNS** — no criticals, but 2+ warnings.
- **CLEAN** — notes only. Safe to merge.

## Anti-patterns

| Anti-pattern | Why it's wrong |
|---|---|
| "LGTM, no issues found" | Every change carries at least one assumption worth naming. Find it, even if it's only a NOTE. |
| Manufacturing severity | Inflating a NOTE to WARNING so the review looks productive teaches the reader to ignore your severities. |
| Cosmetic-only findings | Flagging whitespace while missing a null dereference is worse than no review. |
| Only asking "is this wrong?" | Correct, well-tested, redundant machinery passes every defect-hunting persona. Ask what shouldn't exist. |
| Pulling punches | "This might possibly be a minor concern" — no. Say what breaks and when. |
| Restating the diff | "This function handles authentication" is a summary, not a finding. What's wrong with how it handles it? |
| Ignoring test gaps | New behavior without tests is a finding. |
| Reviewing only changed lines | Bugs live at the seam between new and existing code. |

## The self-review trap

You are probably reviewing code you just wrote or just read. The same weights that produced
it are now judging it, and it will look correct because it matches what you expected to see.
To break the pattern:

1. Read **bottom-up** — start at the last function and work backward, so you meet each
   callee before the caller frames your expectations of it.
2. For each function, state its contract **before** reading the body. Then check whether the
   body honors it.
3. Assume every variable can be null until the code proves otherwise.
4. Assume every external call fails.
5. Ask: if this change were deleted entirely, what would break? If the answer is "nothing,"
   that itself is a finding.

## When to reach for this

- Before merging any PR, especially a self-authored one with no human reviewer
- After a long coding session, when fatigue has narrowed your attention
- When Claude already said "looks good" and the approval came too easily
- On auth, payments, data access, and API endpoints
- When something feels off and you can't yet say why

## Related

- `/code-review` — general code quality review of the working diff
- `/security-review` — dedicated security pass over pending changes
- `/simplify` — reuse and simplification cleanups (quality, not bug-hunting)
