#!/usr/bin/env bash
# Claim: every plan under docs/plans/ is a graph inside the budget,
# bin/check-plan-graph.py refuses one that is not, and skills/graphplan/SKILL.md
# states the exact budget the checker enforces.
#
# The failure this prevents: a plan graph drifting back into prose one word at
# a time. A node label grows a fifth line because it read fine at four; an edge
# label picks up a clause because it read fine short. Nothing catches that
# except a check run over the real files, so this test drives the real script
# -- never a copy of its word-counting -- the way tests/lib/curl-stub.sh drives
# real callers instead of asserting on a mock. It also drives the fixtures
# through the real script rather than reimplementing the budget here: a test
# that reimplements the rule stays green when the rule and the script disagree,
# which is the same defect test-render-diagram-extracts-one-block.sh's header
# describes for its own extraction logic.
#
# The second failure, found in review on 2026-09-03: a checker that only reads
# the label forms it expects. The first version recognised `c1["..."]` and
# nothing else, so `c1[seventeen words with no quotes]` -- valid mermaid, and
# exactly the prose the budget exists to refuse -- exited 0 with no output at
# all. Every label form below is therefore either measured or refused, and the
# cases assert the refusal, because a checker that stays quiet about what it
# cannot read is worse than no checker: it reports coverage it does not have.
#
# The third failure, found reviewing PR #18 on 2026-09-09: a gate that reads
# the labels inside a fence without ever asking whether the fence holds a
# graph. An empty fence passed, one-word-per-line text passed, and a single
# 200-character token passed a budget counted in words. Each is a case below,
# because each was accepted by the version of the checker that this file
# already called green.
#
# The fourth, from the same review: scan() stopped at the first ";" on a line.
# A plan that packed several node statements behind semicolons had every label
# after the first go unmeasured, and exited 0 with no output at all. That
# review also found two edge-label forms mermaid allows that scan() never read,
# two valid node forms it refused as unreadable, and a failure message that
# could name a node id no link in the graph produces.
#
# The fifth, in the rounds that fixed the fourth: an inline edge label ended at
# any run of link characters, so `a -- reads the plan, then... builds --> b`
# was cut at the "..." and passed at five words against a budget of four. And a
# statement packed after a keyword on the same line was never measured, because
# a line whose first word was a keyword was skipped whole. That one was found
# twice -- first for `flowchart` and `graph`, then for `class`, `classDef`,
# `style`, `linkStyle`, `direction` and `end`, four of which real plans under
# docs/plans/ use. A fix that closes one seventh of a hole looks exactly like a
# fix, so every keyword is a case below.
#
# The sixth: a character budget calibrated on what plans had already said
# rather than on what a plan must be able to say. It refused a correct label
# for six tracked files and offered no compliant wording. A gate that refuses
# correct work costs a card an attempt exactly as a gate that admits wrong work
# costs a review round, so both directions are cases here: what must be
# refused, and what must be accepted.
#
# The seventh, in round-2 review of PR #25 on 2026-09-09: three holes in the
# fifth and fourth failures' own shape, each closed with no fixture to guard
# it from opening again.
#
# `a == text ==> b` is in INLINE_LINKS, and nothing drove it. A change that
# dropped "==" from the dict, or let its closer match any run of "=" the way
# the fifth failure's "--" closer once matched any run of link characters,
# would still pass. Mermaid's tailed openers -- `o--`, `x--`, `<--`, and the
# same tails on `==` and `-.` -- matched no key in INLINE_LINKS at all, so a
# label on `a o-- one two three four five --> b` went unmeasured, or `one` was
# reported as a node the graph does not otherwise name. And `opening_keyword()`
# decided by the word alone, so a node id that spells a keyword, as in
# `end["<label>"] --> b`, was swallowed as a keyword statement and exited 0
# with no output -- where the checker measured it before that regression.
#
# SKILL.md carried a fourth hole of the same kind: "a four-word budget" typed
# MAX_LABEL_WORDS a second time, in prose no test compared to the constant.
#
# The eighth, PRA-346 on 2026-09-09: a `subgraph` statement sharing its line
# with a graph statement and no ";" between them. The title ran from the first
# "[" to the last "]", so the checker reported a title nobody wrote and, in the
# same breath, a graph with no link -- on a line that draws one. The same card
# gave the character budget a --max-label-chars option, because 80 is
# calibrated on THIS tree and the gate runs against plans for any target. The
# cases below: that subgraph line, the mirror of the fifth's keyword loop with
# no ";" after the keyword, the bare `subgraph <title>` form, and
# --max-label-chars moving the budget and refusing a junk value.
#
# What is deliberately NOT covered: rendering (another test owns it) and the
# wording of SKILL.md's prose, only the lines it must reproduce verbatim.
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/bin/check-plan-graph.py"
skill="$repo_root/skills/graphplan/SKILL.md"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# --- 1. Every real plan is inside the budget -------------------------------
#
# Globbed, never listed by name. A hand-written list of what to cover is a list
# somebody has to remember to widen -- bin/check-syntax.sh's own header names
# that as a repeat failure -- so a plan added tomorrow is covered by being
# committed.
#
# One file is exempt, and it is the only one that ever will be.
# 2026-08-27-foreman-layer-1.md is the checkbox task list that built this
# repository, written before skills/graphplan existed. Rewriting it as a graph
# would invent a history that did not happen, and deleting it would lose the
# only record of how the seed commit was cut. The exemption names one file
# rather than a class of file, so nothing new can fall into it by accident,
# and the skip prints so silence is never mistaken for coverage.
legacy="2026-08-27-foreman-layer-1.md"

plans=()
for plan in "$repo_root"/docs/plans/*.md; do
  [[ -e "$plan" ]] || continue
  if [[ "$(basename "$plan")" == "$legacy" ]]; then
    printf 'note skipping %s: it predates skills/graphplan\n' "$legacy"
    continue
  fi
  plans+=("$plan")
done

if [[ ${#plans[@]} -eq 0 ]]; then
  bad "docs/plans/*.md matched no plan graph; nothing to check"
else
  if out="$(python3 "$checker" "${plans[@]}" 2>&1)"; then
    ok "every plan graph under docs/plans/ is inside the budget"
  else
    bad "a plan under docs/plans/ is over budget:
$out"
  fi
fi

# --- 2. Fixtures, driving the real script -----------------------------------
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A node label with too many words on one line: refused, and the message
# names the node id.
cat >"$work_dir/wordy-node.md" <<'MD'
```mermaid
flowchart TD
  c1["this label has far too many words on its one and only line"]
```
MD
if out="$(python3 "$checker" "$work_dir/wordy-node.md" 2>&1)"; then
  bad "a node label with too many words a line was accepted"
else
  case "$out" in
    *"node c1"*"words"*) ok "a node label with too many words a line is refused, naming the node id" ;;
    *) bad "refused, but not naming node c1: $out" ;;
  esac
fi

# A node label with too many lines: refused.
cat >"$work_dir/tall-node.md" <<'MD'
```mermaid
flowchart TD
  c2["one<br/>two<br/>three<br/>four<br/>five"]
```
MD
if out="$(python3 "$checker" "$work_dir/tall-node.md" 2>&1)"; then
  bad "a node label with too many lines was accepted"
else
  case "$out" in
    *"node c2"*"lines"*) ok "a node label with too many lines is refused" ;;
    *) bad "refused, but not for line count: $out" ;;
  esac
fi

# Prose above the mermaid fence: refused.
cat >"$work_dir/prose-above.md" <<'MD'
# A plan with a stray sentence

```mermaid
flowchart TD
  c5["short label"]
```
MD
if out="$(python3 "$checker" "$work_dir/prose-above.md" 2>&1)"; then
  bad "prose above the mermaid fence was accepted"
else
  case "$out" in
    *"prose outside the mermaid block"*) ok "prose above the mermaid fence is refused" ;;
    *) bad "refused, but not for prose outside the block: $out" ;;
  esac
fi

# An unquoted node label: refused, not skipped. This is the line that exited 0
# silently before review; it is 17 words against a budget of six.
cat >"$work_dir/unquoted-node.md" <<'MD'
```mermaid
flowchart TD
  c8[loads one board into the environment, sourced per board in a subshell, so the key never enters]
```
MD
if out="$(python3 "$checker" "$work_dir/unquoted-node.md" 2>&1)"; then
  bad "an unquoted node label was accepted, and it is 17 words long"
else
  case "$out" in
    *"node c8"*"not quoted"*) ok "an unquoted node label is refused, naming the node id" ;;
    *) bad "refused, but not for the missing quotes: $out" ;;
  esac
fi

# Several node statements on one line, separated by ";": every one of them is
# measured, not only the first. Before the fix reviewed in PR #18 on
# 2026-09-09, scan() stopped at the first ";", so this line exited 0 with no
# output at all. The assertion below checks the last of the three, because the
# first was already being measured before that fix -- it is the ones after the
# first ";" that prove the bug is gone.
cat >"$work_dir/semicolons.md" <<'MD'
```mermaid
flowchart TD
  n1["one two three four five six seven"]; n2["one two three four five six seven"]; n3["one two three four five six seven"]
```
MD
if out="$(python3 "$checker" "$work_dir/semicolons.md" 2>&1)"; then
  bad "three over-budget node labels packed behind \";\" on one line were accepted"
else
  case "$out" in
    *"node n3"*"words"*) ok "a node label after \";\" on the same line is measured" ;;
    *) bad "refused, but not naming node n3: $out" ;;
  esac
fi

# The three forms mermaid writes an edge label in, one test each: pipes, inline
# on a solid link, inline on a dotted link. All three are measured against the
# same four-word budget, so all three refuse the same over-budget label.
#
# An over-budget edge label in the pipe form: refused.
cat >"$work_dir/pipe-edge.md" <<'MD'
```mermaid
flowchart TD
  a -->|one two three four five| b
```
MD
if out="$(python3 "$checker" "$work_dir/pipe-edge.md" 2>&1)"; then
  bad "an over-budget edge label in the pipe form was accepted"
else
  case "$out" in
    *"edge label"*"words"*) ok "an over-budget edge label in the pipe form is refused" ;;
    *) bad "refused, but not for edge word count: $out" ;;
  esac
fi

# An over-budget edge label written inline on a solid link: refused.
cat >"$work_dir/inline-edge-solid.md" <<'MD'
```mermaid
flowchart TD
  c9 -- this edge label has far too many words to be allowed --> c10
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge-solid.md" 2>&1)"; then
  bad "an inline edge label on a solid link was accepted, and it is 11 words long"
else
  case "$out" in
    *"edge label"*"words"*) ok "an over-budget edge label inline on a solid link is refused" ;;
    *) bad "refused, but not for edge word count: $out" ;;
  esac
fi

# An over-budget edge label written inline on a dotted link: refused.
cat >"$work_dir/inline-edge-dotted.md" <<'MD'
```mermaid
flowchart TD
  a -. one two three four five .-> b
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge-dotted.md" 2>&1)"; then
  bad "an inline edge label on a dotted link was accepted"
else
  case "$out" in
    *"edge label"*"words"*) ok "an over-budget edge label inline on a dotted link is refused" ;;
    *) bad "refused, but not for edge word count: $out" ;;
  esac
fi

# A ":::className" suffix on a node, on a label inside the budget: accepted
# silently. Before the fix reviewed in PR #18 on 2026-09-09, this valid mermaid
# was refused as "expected a link or a label".
cat >"$work_dir/class-suffix.md" <<'MD'
```mermaid
flowchart TD
  c1["short label"]:::changed --> c2:::changed
```
MD
if out="$(python3 "$checker" "$work_dir/class-suffix.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a :::className suffix on a node is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a :::className suffix on a node, inside the budget, was refused: $out"
fi

# A pipe label separated from its arrow by a space, inside the budget:
# accepted silently. Before the fix reviewed in PR #18 on 2026-09-09, this
# valid mermaid was refused the same way.
cat >"$work_dir/spaced-pipe.md" <<'MD'
```mermaid
flowchart TD
  a --> |short label| b
```
MD
if out="$(python3 "$checker" "$work_dir/spaced-pipe.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a pipe label separated from its arrow by a space is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a pipe label separated from its arrow by a space, inside the budget, was refused: $out"
fi

# An unspaced link with an "o" head, as in a---ob[...]: refused for its real
# node id. Before the fix reviewed in PR #18 on 2026-09-09, the tokeniser let
# the link's "o" leak into the id, so the message named a node "ob" that no
# link in the graph produces.
cat >"$work_dir/unspaced-o-head.md" <<'MD'
```mermaid
flowchart TD
  a---ob["one two three four five six seven eight"]
```
MD
if out="$(python3 "$checker" "$work_dir/unspaced-o-head.md" 2>&1)"; then
  bad "an over-budget label past an unspaced o-headed link was accepted"
else
  case "$out" in
    *"node ob"*) bad "refused, but naming node ob, which the graph does not contain: $out" ;;
    *"node b"*"words"*) ok "an unspaced o-headed link is refused, naming the node it actually links to" ;;
    *) bad "refused, but not naming node b: $out" ;;
  esac
fi

# Link characters inside an inline edge label are label text, not the end of
# the label. Review of PR #18 on 2026-09-09 found the closer matching any run
# of link characters, so this line was cut at the "..." and only its first
# three words were measured -- exit 0, five words against a budget of four.
cat >"$work_dir/inline-edge-dots.md" <<'MD'
```mermaid
flowchart TD
  a -- reads the plan, then... builds --> b
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge-dots.md" 2>&1)"; then
  bad "an inline edge label was cut at the \"...\" inside it and passed at 5 words"
else
  case "$out" in
    *"reads the plan, then... builds"*"5 words"*)
      ok "an inline edge label is measured whole, past the link characters inside it" ;;
    *) bad "refused, but not for the whole label at five words: $out" ;;
  esac
fi

# The thick inline form, `a == text ==> b`, is in INLINE_LINKS and until this
# case existed nothing drove it (found in round-2 review of PR #25,
# 2026-09-09). An over-budget label on it: refused for its edge word count.
cat >"$work_dir/inline-edge-thick.md" <<'MD'
```mermaid
flowchart TD
  a == one two three four five ==> b
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge-thick.md" 2>&1)"; then
  bad "an over-budget edge label on the thick inline form was accepted"
else
  case "$out" in
    *"edge label"*"5 words"*) ok "an over-budget edge label on the thick inline form is refused" ;;
    *) bad "refused, but not for edge word count: $out" ;;
  esac
fi

# The same thick inline form, with link characters inside the label: measured
# whole, not cut at the "...". This is the fifth failure's own case, for the
# opener that had no case of its own -- a closer that matched any run of "="
# would cut this one exactly as the "--" closer once cut the dotted case.
cat >"$work_dir/inline-edge-thick-dots.md" <<'MD'
```mermaid
flowchart TD
  a == reads the plan, then... builds ==> b
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge-thick-dots.md" 2>&1)"; then
  bad "a thick inline edge label was cut at the \"...\" inside it and passed at 5 words"
else
  case "$out" in
    *"reads the plan, then... builds"*"5 words"*)
      ok "a thick inline edge label is measured whole, past the link characters inside it" ;;
    *) bad "refused, but not for the whole label at five words: $out" ;;
  esac
fi

# Mermaid's tailed inline openers: `o--`, `x--`, `<--`, and the same three
# tails on the "==" and "-." bodies. Before the fix reviewed in PR #25's round
# 2 on 2026-09-09, a tailed opener matched no key in INLINE_LINKS, so its
# label went unmeasured or a word inside it was reported as a node the graph
# does not otherwise name. Looped the way the keyword case below loops over
# keywords: one opener passing must not hide another failing, because the fix
# that closed the bare openers looked exactly like a fix for all of them.
# Each opener is paired with a closer mermaid actually accepts for it.
for pair in "o--:-->" "x--:-->" "<--:-->" \
            "o==:==>" "x==:==>" "<==:==>" \
            "o-.:.->" "x-.:.->" "<-.:.->"; do
  opener="${pair%%:*}"
  closer="${pair##*:}"
  {
    printf '```mermaid\nflowchart TD\n'
    printf '  a %s one two three four five %s b\n' "$opener" "$closer"
    printf '```\n'
  } >"$work_dir/tailed-opener.md"
  if out="$(python3 "$checker" "$work_dir/tailed-opener.md" 2>&1)"; then
    bad "an over-budget edge label on tailed opener \"$opener\" was accepted"
  else
    case "$out" in
      *"edge label"*"5 words"*)
        ok "an over-budget edge label on tailed opener \"$opener\" is refused" ;;
      *) bad "tailed opener \"$opener\" refused, but not for edge word count: $out" ;;
    esac
  fi
done

# A statement packed after a styling statement on the same line: measured. The
# ";" fix of 2026-09-09 landed inside scan(), but check_line still skipped a
# whole line whose first word was a keyword, so this one exited 0 with no
# output. Five plans under docs/plans/ open a line with classDef.
cat >"$work_dir/after-classdef.md" <<'MD'
```mermaid
flowchart TD
  classDef chg fill:#eee; c1["one two three four five six seven eight"]
```
MD
if out="$(python3 "$checker" "$work_dir/after-classdef.md" 2>&1)"; then
  bad "a node label packed after classDef on one line was accepted at 8 words"
else
  case "$out" in
    *"node c1"*"words"*) ok "a node label after a styling statement on the same line is measured" ;;
    *) bad "refused, but not naming node c1: $out" ;;
  esac
fi

# An over-budget subgraph title: refused. The title is read as one statement
# among the others on its line, so this also proves a ";" does not hide it.
cat >"$work_dir/wordy-cluster.md" <<'MD'
```mermaid
flowchart TD
  subgraph out["a cluster title with far too many words"]
  end
```
MD
if out="$(python3 "$checker" "$work_dir/wordy-cluster.md" 2>&1)"; then
  bad "a subgraph title with too many words was accepted"
else
  case "$out" in
    *"subgraph title"*"words"*) ok "a subgraph title with too many words is refused" ;;
    *) bad "refused, but not for the title word count: $out" ;;
  esac
fi

# A label already measured is reported even when a later statement on the same
# line cannot be read. An author told only about the second one fixes it and
# only then learns about the first.
cat >"$work_dir/measured-then-unreadable.md" <<'MD'
```mermaid
flowchart TD
  n1["one two three four five six seven"]; a -- b
```
MD
if out="$(python3 "$checker" "$work_dir/measured-then-unreadable.md" 2>&1)"; then
  bad "an over-budget label before an unreadable statement was accepted"
else
  case "$out" in
    *"node n1"*"words"*"never closes"*)
      ok "a label measured before an unreadable statement is reported with it" ;;
    *) bad "refused, but not naming both the label and the unreadable statement: $out" ;;
  esac
fi

# A line in a shape the checker cannot read: refused, never passed over.
cat >"$work_dir/unreadable.md" <<'MD'
```mermaid
flowchart TD
  c11@{ shape: rect, label: "a label with a great many words in it" }
```
MD
if out="$(python3 "$checker" "$work_dir/unreadable.md" 2>&1)"; then
  bad "a line the checker cannot read was passed over in silence"
else
  case "$out" in
    *"expected a link or a label"*) ok "a line the checker cannot read is refused" ;;
    *) bad "refused, but not for being unreadable: $out" ;;
  esac
fi

# An empty mermaid fence: refused. It is a plan that says nothing, and it
# passed this gate until 2026-09-09.
cat >"$work_dir/empty-fence.md" <<'MD'
```mermaid
```
MD
if out="$(python3 "$checker" "$work_dir/empty-fence.md" 2>&1)"; then
  bad "an empty mermaid fence was accepted"
else
  case "$out" in
    *"empty"*"mermaid graph and nothing else"*) ok "an empty mermaid fence is refused" ;;
    *) bad "refused, but not for being empty: $out" ;;
  esac
fi

# A fence holding prose, not a graph: refused. Lines of one word each are what
# slipped through the old word-per-line budget, because a bare word parses as
# a node id with no label. The claim here is narrower: a fence with no
# flowchart/graph header is not a graph, whatever else it contains.
cat >"$work_dir/prose-fence.md" <<'MD'
```mermaid
this
document
explains
the
plan
```
MD
if out="$(python3 "$checker" "$work_dir/prose-fence.md" 2>&1)"; then
  bad "a fence holding prose with no graph header was accepted"
else
  case "$out" in
    *"not flowchart or graph"*) ok "a fence holding prose with no graph header is refused" ;;
    *) bad "refused, but not for the missing graph header: $out" ;;
  esac
fi

# A fence with a header and nodes but no edge: refused. A plan graph states
# what depends on what; boxes with nothing drawn between them are a list.
cat >"$work_dir/no-edge.md" <<'MD'
```mermaid
flowchart TD
  c1["a node"]
  c2["another node"]
```
MD
if out="$(python3 "$checker" "$work_dir/no-edge.md" 2>&1)"; then
  bad "a graph with no edge between any two nodes was accepted"
else
  case "$out" in
    *"no link between any two nodes"*) ok "a fence with nodes but no edge is refused" ;;
    *) bad "refused, but not for the missing edge: $out" ;;
  esac
fi

# A node label that is one 200-character token: refused for its character
# count. This is the case the ticket names: a single long token is one word,
# so it satisfied a six-word budget whose comment said it existed for
# on-screen legibility, while filling the screen anyway.
long_token="$(printf 'x%.0s' {1..200})"
printf '%s\n' \
  '```mermaid' \
  'flowchart TD' \
  "  c1[\"$long_token\"] --> c2[\"y\"]" \
  '```' \
  >"$work_dir/long-token.md"
if out="$(python3 "$checker" "$work_dir/long-token.md" 2>&1)"; then
  bad "a 200-character node label was accepted"
else
  case "$out" in
    *"node c1"*"characters"*) ok "a node label that is one 200-character token is refused" ;;
    *) bad "refused, but not for the character count: $out" ;;
  esac
fi

# The label a plan MUST be able to write: a node naming the longest path this
# repository tracks, in the form SKILL.md prescribes. The character budget was
# first set from the widest label already in docs/plans/, which refused a
# correct plan for six tracked files and offered no wording that would pass
# (found in review on 2026-09-09). The longest path is read from git rather
# than typed, so adding a longer one fails here -- where it is a budget to
# raise -- instead of on a card, where it costs a plan attempt.
longest_path="$(git -C "$repo_root" ls-files |
  awk '{ if (length($0) > n) { n = length($0); p = $0 } } END { print p }')"
if [[ -z "$longest_path" ]]; then
  bad "git ls-files named no path; the budget cannot be checked against what a plan must say"
else
  {
    printf '```mermaid\nflowchart TD\n'
    printf '  c1["<b>c1 · %s</b> · CHANGE<br/>does the work<br/><i>opus · high</i>"] --> c2["<b>c2 · done</b>"]\n' \
      "$longest_path"
    printf '```\n'
  } >"$work_dir/longest-path.md"
  if out="$(python3 "$checker" "$work_dir/longest-path.md" 2>&1)"; then
    ok "a node naming the longest tracked path is inside the budget"
  else
    bad "the budget refuses a plan node naming $longest_path, and SKILL.md offers no shorter form:
$out"
  fi
fi

# A label written on the header line: measured, not skipped. `flowchart TD;` is
# a keyword line, and skipping the whole line let the 200-character label above
# clear the budget by moving one line up (found in review on 2026-09-09).
{
  printf '```mermaid\n'
  printf 'flowchart TD; a["%s"] --> b["ok"]\n' "$(printf 'x%.0s' {1..200})"
  printf '```\n'
} >"$work_dir/header-line-label.md"
if out="$(python3 "$checker" "$work_dir/header-line-label.md" 2>&1)"; then
  bad "a 200-character label on the header line was accepted"
else
  case "$out" in
    *"node a"*"characters"*) ok "a label on the header line is measured, not skipped" ;;
    *) bad "refused, but not for the character count: $out" ;;
  esac
fi

# Mermaid's one-line form: accepted. The header line carries the only edge, so
# a checker that skips that line reports a graph with one edge as having none.
cat >"$work_dir/one-line.md" <<'MD'
```mermaid
graph TD; a["one"] --> b["two"]
```
MD
if out="$(python3 "$checker" "$work_dir/one-line.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a graph written on one line is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a graph whose only edge is on the header line was refused: $out"
fi

# A graph whose only link is invisible: refused. Mermaid draws `~~~` as
# nothing, so the boxes state no relationship and the fence is a list again.
cat >"$work_dir/invisible-link.md" <<'MD'
```mermaid
flowchart TD
  a["one"] ~~~ b["two"]
```
MD
if out="$(python3 "$checker" "$work_dir/invisible-link.md" 2>&1)"; then
  bad "a graph whose only link is invisible was accepted"
else
  case "$out" in
    *"no link between any two nodes"*) ok "a graph whose only link is invisible is refused" ;;
    *) bad "refused, but not for the missing link: $out" ;;
  esac
fi

# An unclosed %%{init directive: reported once, and never as an empty block.
# The directive swallows every line after it, so the lines are unread, not
# absent, and saying the block is empty would be false.
cat >"$work_dir/unclosed-directive.md" <<'MD'
```mermaid
%%{init: {
"theme": "base"
flowchart TD
  a["one"] --> b["two"]
```
MD
if out="$(python3 "$checker" "$work_dir/unclosed-directive.md" 2>&1)"; then
  bad "a block whose directive never closes was accepted"
else
  case "$out" in
    *empty*) bad "an unread block was reported as empty: $out" ;;
    *"never closed"*) ok "an unclosed directive is reported once, not as an empty block" ;;
    *) bad "refused, but not for the unclosed directive: $out" ;;
  esac
fi

# A label written after a keyword on the same line: measured, not skipped. A
# `;` separates statements, so a keyword is the first word of a STATEMENT and
# never of the line. Skipping the line let `class a hot; c1["<200 characters>"]`
# out of the budget entirely, and the file exited 0 with no output at all --
# found in review on 2026-09-09, after the same hole was closed for `flowchart`
# and `graph` alone. Every keyword the checker knows is tried here, because the
# first fix closed one seventh of the hole and looked complete.
for keyword in "class a hot" "classDef hot fill:#f00" "style a fill:#f00" \
               "linkStyle 0 stroke:#f00" "direction LR"; do
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  %s; c1["%s"] --> c2["ok"]\n' "$keyword" "$(printf 'x%.0s' {1..200})"
    printf '```\n'
  } >"$work_dir/keyword-line.md"
  if out="$(python3 "$checker" "$work_dir/keyword-line.md" 2>&1)"; then
    bad "a 200-character label after \`$keyword;\` was accepted"
  else
    case "$out" in
      *"node c1"*"characters"*) ok "a label after \`$keyword;\` is measured, not skipped" ;;
      *) bad "refused, but not for the character count: $out" ;;
    esac
  fi
done

# A node id that spells a keyword: an over-budget label on it is measured and
# refused, naming the node id. Before the fix reviewed in PR #25's round 2 on
# 2026-09-09, `opening_keyword()` decided by the word alone, so
# `end["<label>"] --> b` was swallowed as a keyword statement and exited 0
# with no output -- where the checker measured it before that regression.
# Every keyword the checker knows is tried here, for the reason the keyword-
# line loop above tries every one of them: a fix that covers one looks exactly
# like a fix for all. The other direction -- a real keyword statement still
# read as one -- is already covered by the keyword-line loop above; it is not
# repeated here.
for keyword in flowchart graph subgraph direction classDef class linkStyle style end; do
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  %s["one two three four five six seven"] --> c["ok"]\n' "$keyword"
    printf '```\n'
  } >"$work_dir/keyword-node-id.md"
  if out="$(python3 "$checker" "$work_dir/keyword-node-id.md" 2>&1)"; then
    bad "a node id spelling the keyword \"$keyword\" hid an over-budget label, exit 0"
  else
    case "$out" in
      *"node $keyword"*"7 words"*)
        ok "a node id spelling the keyword \"$keyword\" is measured, naming the node id" ;;
      *) bad "refused, but not naming node \"$keyword\": $out" ;;
    esac
  fi
done

# The mirror of the loop above, with no ";" after the keyword. `class`,
# `classDef`, `style`, `linkStyle` and `direction` all take an operand that
# mermaid itself reads to a ";" or the end of the statement, wherever that
# falls -- there is no other separator in their grammar. So text packed after
# one of them with no ";" is that keyword's own operand, not a second
# statement, and the loop above proves the opposite only because its ";" is
# what turns the packed text into one. This loop packs the same 200-character
# label with no ";" and expects it swallowed, unmeasured, because it was never
# a node statement to begin with.
for keyword in "class a hot" "classDef hot fill:#f00" "style a fill:#f00" \
               "linkStyle 0 stroke:#f00" "direction LR"; do
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  %s c1["%s"] --> c2["ok"]\n' "$keyword" "$(printf 'x%.0s' {1..200})"
    printf '```\n'
  } >"$work_dir/keyword-no-semicolon.md"
  if out="$(python3 "$checker" "$work_dir/keyword-no-semicolon.md" 2>&1)"; then
    [[ -z "$out" ]] && ok "\`$keyword\` with no \";\" folds the rest of the line into its own operand" \
      || bad "accepted \`$keyword\` with no \";\", but printed something: $out"
  else
    bad "\`$keyword\` with no \";\" was refused, though the packed text is its operand, not a statement: $out"
  fi
done

# A subgraph sharing its line with a graph statement: accepted. The title is
# read from the statement, not from the line. Read from the line, it ran to the
# last `]` on it, so this graph was refused for a five-word title nobody wrote
# and for having no link, while drawing one (review, 2026-09-09).
cat >"$work_dir/subgraph-line.md" <<'MD'
```mermaid
flowchart TD
  subgraph s["the board"]; a["one"] --> b["two"]
  end
```
MD
if out="$(python3 "$checker" "$work_dir/subgraph-line.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a subgraph sharing its line with an edge is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a subgraph sharing its line with an edge was refused: $out"
fi

# The same line with no ";" between the subgraph statement and the graph
# statement: refused, naming the trailing text and the missing separator.
# Mermaid puts a separator after the title's "]" and does not render this line
# either. Until PRA-346 on 2026-09-09 the title ran from the first "[" to the
# last "]" on the line, so this was refused for a five-word title nobody wrote
# and, in the same breath, for having no link -- though the line draws one.
# Neither false claim may come back.
cat >"$work_dir/subgraph-no-semicolon.md" <<'MD'
```mermaid
flowchart TD
  subgraph s["the board"] a["one"] --> b["two"]
  end
```
MD
if out="$(python3 "$checker" "$work_dir/subgraph-no-semicolon.md" 2>&1)"; then
  bad "a subgraph sharing its line with a graph statement and no \";\" was accepted"
else
  case "$out" in
    *"no link between any two nodes"*)
      bad "a subgraph line missing \";\" was told it draws no link, though the line draws one: $out" ;;
    *"subgraph title"*"words"*)
      bad "a subgraph line missing \";\" was refused for a title nobody wrote: $out" ;;
    *"text after the title"*)
      ok "a subgraph sharing its line with a graph statement and no \";\" is refused, naming the trailing text and the missing separator" ;;
    *) bad "refused, but not for the missing \";\": $out" ;;
  esac
fi

# The bare form of a subgraph title, with no id and no brackets: still
# measured against the four-word budget. `the whole board title` is exactly
# four words, so a checker that skipped this form, or measured it off by one,
# would show it here instead of on a plan.
cat >"$work_dir/subgraph-bare-title.md" <<'MD'
```mermaid
flowchart TD
  subgraph the whole board title
    a["one"] --> b["two"]
  end
```
MD
if out="$(python3 "$checker" "$work_dir/subgraph-bare-title.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a bare subgraph title at the four-word budget is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a bare subgraph title at the four-word budget was refused: $out"
fi

# A `;` inside a label is text, not a separator. The statement split is what
# makes every case above work, and a split that ignored quotes would cut this
# label in half and report syntax nobody wrote.
cat >"$work_dir/semicolon-label.md" <<'MD'
```mermaid
flowchart TD
  a["one; two"] --> b["three"]
```
MD
if out="$(python3 "$checker" "$work_dir/semicolon-label.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a semicolon inside a label is text, not a statement break" \
    || bad "accepted, but printed something: $out"
else
  bad "a label holding a semicolon was refused: $out"
fi

# A line the checker cannot read is never also reported as a missing edge. The
# statement draws one; nothing could read it, so nothing is claimed about it.
# Reporting "no link between any two nodes" told the plan agent -- which
# brief.py tells to fix what the checker refuses -- to add a dependency the
# graph already stated, which is the one edge SKILL.md forbids (review,
# 2026-09-09).
cat >"$work_dir/unreadable-edge.md" <<'MD'
```mermaid
flowchart TD
  c1[builds the thing] --> c2["done"]
```
MD
if out="$(python3 "$checker" "$work_dir/unreadable-edge.md" 2>&1)"; then
  bad "an unquoted label on the only edge line was accepted"
else
  case "$out" in
    *"no link between any two nodes"*)
      bad "a graph that draws an edge was told it draws none: $out" ;;
    *"not quoted"*) ok "an unreadable line is not also reported as a missing edge" ;;
    *) bad "refused, but not for the missing quotes: $out" ;;
  esac
fi

# A terse graph: accepted. Shapes other than the plain box are labels too, and
# a fix for the silent skip that refused them would be its own defect.
cat >"$work_dir/terse.md" <<'MD'
```mermaid
flowchart TD
  c6["<b>c6 · brief.py</b> · CHANGE<br/>writes the dispatch prompt"]
  c7["<b>c7 · queue.py</b> · CHANGE<br/>orders todo cards"]
  store[("the card history")]
  gate{"a free slot?"}
  c6 -->|feeds| c7
  c7 -.->|"reads at runtime"| store
  store --- gate
```
MD
if out="$(python3 "$checker" "$work_dir/terse.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a terse graph is accepted silently" \
    || bad "accepted, but printed something: $out"
else
  bad "a terse graph inside the budget was refused: $out"
fi

# --- 2b. --max-label-chars: the budget a deeper target raises -------------
#
# limits.max_label_chars in a target's board.toml reaches this file as this
# flag -- see the comment above DEFAULT_MAX_LABEL_CHARS for why 80 is a
# default calibrated on this tree and not a ceiling on every tree.
ninety_chars="$(printf 'x%.0s' {1..90})"
printf '%s\n' \
  '```mermaid' \
  'flowchart TD' \
  "  c1[\"$ninety_chars\"] --> c2[\"ok\"]" \
  '```' \
  >"$work_dir/max-label-chars.md"

if out="$(python3 "$checker" "$work_dir/max-label-chars.md" 2>&1)"; then
  bad "a 90-character node label was accepted at the default --max-label-chars"
else
  case "$out" in
    *"node c1"*"characters"*) ok "a 90-character node label is refused at the default --max-label-chars" ;;
    *) bad "refused, but not for the character count: $out" ;;
  esac
fi

if out="$(python3 "$checker" --max-label-chars 96 "$work_dir/max-label-chars.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "the same 90-character node label is accepted under --max-label-chars 96" \
    || bad "accepted under --max-label-chars 96, but printed something: $out"
else
  bad "a 90-character node label was refused under --max-label-chars 96: $out"
fi

case "$(python3 "$checker" --limits)" in
  *"at most 80 characters"*) ok "--limits with no option prints the default of 80 characters" ;;
  *) bad "--limits with no option did not print the default of 80 characters: $(python3 "$checker" --limits)" ;;
esac

case "$(python3 "$checker" --limits --max-label-chars 96)" in
  *"at most 96 characters"*) ok "--limits --max-label-chars 96 prints 96, not the default" ;;
  *) bad "--limits --max-label-chars 96 did not print 96: $(python3 "$checker" --limits --max-label-chars 96)" ;;
esac

# A junk value for --max-label-chars: a usage error naming the option, exit 2,
# never a stack trace and never a silent fallback to the default.
for junk in "wide" "-5"; do
  out="$(python3 "$checker" --max-label-chars "$junk" "$work_dir/max-label-chars.md" 2>&1)"
  status=$?
  if [[ $status -ne 2 ]]; then
    bad "--max-label-chars $junk exited $status, not 2: $out"
  else
    case "$out" in
      *"--max-label-chars"*) ok "--max-label-chars $junk is a usage error naming the option" ;;
      *) bad "--max-label-chars $junk exited 2 but did not name the option: $out" ;;
    esac
  fi
done

# --- 3. Drift: SKILL.md states the budget the checker enforces -------------
#
# SKILL.md wraps its prose at eighty columns; the checker's --limits prints
# two unwrapped lines. Whitespace is collapsed on both sides before comparing
# so the wrap point is not mistaken for a real difference.
checker_limits="$(python3 "$checker" --limits | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
skill_words="$(tr -s '[:space:]' ' ' <"$skill")"
case "$skill_words" in
  *"$checker_limits"*)
    ok "SKILL.md states the exact budget bin/check-plan-graph.py --limits prints"
    ;;
  *)
    bad "SKILL.md and bin/check-plan-graph.py --limits disagree.
--limits says:
$(python3 "$checker" --limits)

If bin/check-plan-graph.py was changed, SKILL.md's budget sentence was not
updated to match. If SKILL.md was changed, its budget sentence no longer
reads as the checker's LIMITS constant, word for word."
    ;;
esac

# SKILL.md is allowed exactly one copy of the budget numbers: the fenced block
# just compared above, verbatim, against --limits. Every other line that types
# "four", "six", "eighty" or a digit against words/lines/characters is a
# second copy quietly drifting out of step with MAX_LABEL_WORDS and friends --
# what "a four-word budget" was, in prose nothing compared to the constant,
# until round-2 review of PR #25 caught it on 2026-09-09.
budget_marker="$(grep -n '\*\*The budget\*\*' "$skill" | head -1 | cut -d: -f1)"
if [[ -z "$budget_marker" ]]; then
  bad "SKILL.md has no \"**The budget**\" marker; the drift guard cannot find the one fenced copy to exempt"
else
  fence_bounds="$(grep -n '^```$' "$skill" | cut -d: -f1 | awk -v m="$budget_marker" '$1 >= m' | sed -n '1p;2p')"
  fence_start="$(printf '%s\n' "$fence_bounds" | sed -n '1p')"
  fence_end="$(printf '%s\n' "$fence_bounds" | sed -n '2p')"
  if [[ -z "$fence_start" || -z "$fence_end" ]]; then
    bad "\"**The budget**\" in SKILL.md is not followed by a fenced block; the drift guard cannot find the one copy to exempt"
  else
    offenders="$(grep -n -E '(\b[0-9]+|four|six|eighty)[ -](words?|lines?|characters?)' "$skill" |
      awk -F: -v s="$fence_start" -v e="$fence_end" '$1 < s || $1 > e')"
    if [[ -z "$offenders" ]]; then
      ok "no line of SKILL.md outside the fenced budget block types a budget number"
    else
      bad "SKILL.md types a budget number outside its one fenced copy (lines $fence_start-$fence_end):
$offenders
Point this line at the fenced block instead of restating the number."
    fi
  fi
fi

exit "$fail"
