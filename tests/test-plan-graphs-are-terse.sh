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
# the label-word budget a second time, in prose no test compared to it.
#
# The eighth, PRA-346 on 2026-09-09: a `subgraph` statement sharing its line
# with a graph statement and no ";" between them. The title ran from the first
# "[" to the last "]", so the checker reported a title nobody wrote and, in the
# same breath, a graph with no link -- on a line that draws one. The same card
# gave the character budget a --max-label-chars option, because 80 is
# calibrated on THIS tree and the gate runs against plans for any target.
#
# The ninth, reviewing that card on 2026-09-10, is what the eighth's own fix
# got wrong. It matched the subgraph id against IDENT, so `skills/board["..."]`
# fell to the bare form and measured the id and its brackets as the title. It
# declared a statement packed onto `style`, `class`, `classDef`, `linkStyle`
# or `direction` with no ";" to be that keyword's operand, where mermaid draws
# none of it -- and the eighth's own fixture asserted that swallowing was
# correct. `direction` was read to the next ";", where mermaid reads it to the
# end of the line, so a block drawing no node and no edge passed. And a `%%`
# comment after a subgraph title was refused with a ";" that does not help.
#
# The tenth, reviewing the ninth on 2026-09-10, is what the ninth got wrong,
# and it was settled by running mermaid 11.17.2's own flow parser rather than
# by reading its lexer. A `%%` is a comment only where it BEGINS a line:
# mermaid's cleanupComments is `/^\s*%%(?!{)[^\n]+\n?/gm`, so
# `a["one"] --> b["two"] %% why` is a parse error and the diagram draws
# nothing, while the ninth dropped that comment and called the block a graph.
# The same run showed `subgraph theboard %% one two three four five` keeping
# all seven words as its title. And the marker for a statement packed onto a
# keyword was a "[", which every other node shape walked through: mermaid
# refuses `style a fill:#f00 c1(("<200 characters>"))` and the {} and pipe
# forms alike, and this file passed all of them.
#
# The eighth, in review of PR #30 on 2026-09-10: a keyword-spelled node id at
# the head of a node list. `continues_a_node()` counted brackets, a `:::`
# suffix and a link as node syntax, but not the `&` that joins one id to the
# next, so `end & other["<seven words>"] --> x` read as the keyword statement
# `end` and exited 0 with no output at all. Every keyword is a case below, for
# the reason the two keyword loops already give.
#
# The ninth, same review, in this file: the drift guard that reads SKILL.md.
# It grepped line by line, so "80 characters" split by the prose wrap went
# unreported for as long as the guard existed. It typed four, six and eighty,
# so those three words were the whole of what it knew. And it found the exempt
# copy by the fence around it, so a language tag on that fence reported the
# exempt copy itself. The guard is now tests/lib/budget-drift-guard.py, which
# reads the file whole and takes the copy of --limits as its exemption.
#
# The tenth, reviewing PR #34 on 2026-09-10: the first fix for the ninth took
# the numbers to search for from --limits, so it searched for the limits of the
# day and nothing else. A limit changing is exactly when the prose goes stale,
# and the stale number is the old one, which that guard had just stopped
# looking for. It also refused any number it could not spell in English, so
# raising the character budget to 100 failed the suite over the guard's own
# word list while SKILL.md was correct. Any number beside a budget word is
# drift now, spelled or typed, and no number is refused. The fixtures below
# drive the guard over a superseded limit, a copy the wrap splits, and a file
# with no copy to exempt: a guard proved only against a file that passes
# reports coverage it has not got.
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
#
# `direction` is not in this loop and has a case of its own below: mermaid's
# lexer reads it as `direction\s+<DIR>[^\n]*`, so a `;` on its line separates
# nothing and the statement after one is never drawn.
for keyword in "class a hot" "classDef hot fill:#f00" "style a fill:#f00" \
               "linkStyle 0 stroke:#f00"; do
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

# A keyword-spelled node id at the head of a node list: the label on the node
# after the "&" is measured, and the message names the node the label belongs
# to. Before the fix reviewed in PR #30 on 2026-09-10, `continues_a_node()` did
# not count "&" as node syntax, so `end & other["<seven words>"] --> x` read as
# the keyword statement `end` and exited 0 with no output at all. Every keyword
# the checker knows is tried here, for the reason the two loops above try every
# one of them: a fix that covers one keyword looks exactly like a fix for all.
for keyword in flowchart graph subgraph direction classDef class linkStyle style end; do
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  %s & other["one two three four five six seven"] --> x["ok"]\n' "$keyword"
    printf '```\n'
  } >"$work_dir/keyword-node-list-head.md"
  if out="$(python3 "$checker" "$work_dir/keyword-node-list-head.md" 2>&1)"; then
    bad "the keyword \"$keyword\" heading a node list hid an over-budget label, exit 0"
  else
    case "$out" in
      *"node other"*"7 words"*)
        ok "the keyword \"$keyword\" heading a node list still measures the node after the \"&\"" ;;
      *) bad "keyword \"$keyword\" heading a node list refused, but not naming node other: $out" ;;
    esac
  fi
done

# The mirror of the `$keyword;` loop above, with no ";" after the keyword:
# refused, and the message names the separator. Mermaid needs a separator to
# end each of these statements, so a node packed on without one is drawn by
# nothing: the line fails to parse and the whole diagram with it. The first
# round of this card declared that swallowing correct, on the grounds that the
# packed text was the keyword's operand; review of PR #31 on 2026-09-10 measured
# mermaid's own parser and found `style a fill:#f00 c1["<200 characters>"]` renders no
# node and no edge, so the checker was reporting a valid graph for a block that
# draws nothing -- the hole this card had just closed for `subgraph`.
#
# A style declaration never holds a "[", so the "[" is what marks the packed
# statement and nothing correct is refused by it.
for keyword in "class a hot" "classDef hot fill:#f00" "style a fill:#f00" \
               "linkStyle 0 stroke:#f00"; do
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  %s c1["%s"] --> c2["ok"]\n' "$keyword" "$(printf 'x%.0s' {1..200})"
    printf '```\n'
  } >"$work_dir/keyword-no-semicolon.md"
  if out="$(python3 "$checker" "$work_dir/keyword-no-semicolon.md" 2>&1)"; then
    bad "a node packed onto \`$keyword\` with no \";\" was accepted, and mermaid draws neither"
  else
    case "$out" in
      *"text after the $(printf '%s' "${keyword%% *}") statement"*';'*)
        ok "a node packed onto \`$keyword\` with no \";\" is refused, naming the statement and the separator" ;;
      *) bad "refused, but not for the packed statement: $out" ;;
    esac
  fi
done

# The same packed statement in the node shapes that carry no "[" at all, and
# as an edge whose label sits in pipes. The round before this one marked a
# packed statement by looking for a "[", so mermaid's round, diamond and
# pipe-label forms all walked through the gate: review of PR #31 on 2026-09-10
# ran mermaid 11.17.2 over each and got `Parse error on line 3`, with this
# file exiting 0 and the 200-character label never measured.
for shape in '(("|"))' '{"|"}'; do
  open="${shape%%|*}"
  close="${shape#*|}"
  {
    printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
    printf '  style a fill:#f00 c1%s%s%s --> c2%sok%s\n' \
      "$open" "$(printf 'x%.0s' {1..200})" "$close" "$open" "$close"
    printf '```\n'
  } >"$work_dir/keyword-packed-shape.md"
  if out="$(python3 "$checker" "$work_dir/keyword-packed-shape.md" 2>&1)"; then
    bad "a node packed onto \`style\` in the shape ${open}...${close} was accepted, and mermaid draws neither"
  else
    case "$out" in
      *"text after the style statement"*)
        ok "a node packed onto \`style\` in the shape ${open}...${close} is refused" ;;
      *) bad "refused, but not for the packed statement: $out" ;;
    esac
  fi
done

# The packed statement with no bracket of any kind: an edge whose label sits
# between pipes. Nothing on this line holds a "[", so the marker had to become
# something else entirely.
cat >"$work_dir/keyword-packed-pipe.md" <<'MD'
```mermaid
flowchart TD
  a["one"] --> b["two"]
  style a fill:#f00 c -->|"one two three four five"| d
```
MD
if out="$(python3 "$checker" "$work_dir/keyword-packed-pipe.md" 2>&1)"; then
  bad "an edge packed onto \`style\` with its label in pipes was accepted, and mermaid draws neither"
else
  case "$out" in
    *"text after the style statement"*)
      ok "an edge packed onto \`style\` with its label in pipes is refused" ;;
    *) bad "refused, but not for the packed statement: $out" ;;
  esac
fi

# And a real styling statement is still accepted. Every declaration here parses
# in mermaid 11.17.2, so a marker that refused one of them would cost a card a
# plan attempt for a line that renders.
cat >"$work_dir/real-styling.md" <<'MD'
```mermaid
flowchart TD
  a["one"] --> b["two"]
  classDef chg fill:#e8f4ff,stroke:#4a90d9,stroke-width:2px
  class a,b chg
  style a fill:#f00,stroke:#333,stroke-width:2px
  linkStyle 0 stroke:#f00,stroke-width:2px
  linkStyle default stroke-dasharray: 3 5
```
MD
if out="$(python3 "$checker" "$work_dir/real-styling.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a real styling declaration is accepted, marker and all" \
    || bad "accepted, but printed something: $out"
else
  bad "a styling declaration mermaid parses was refused as a packed statement: $out"
fi

# `direction` takes the rest of its line, so neither a ";" nor anything else
# on that line separates a statement from it. Its remedy is a new line, and
# the message must say so rather than naming a ";" that changes nothing.
# Review of PR #31 on 2026-09-10 ran mermaid's own parser on
# `direction LR; a["one"] --> b["two"]` inside a subgraph and got no vertex and
# no link at all, while this checker counted the link and exited 0.
{
  printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
  printf '  direction LR; c1["%s"] --> c2["ok"]\n' "$(printf 'x%.0s' {1..200})"
  printf '```\n'
} >"$work_dir/direction-line.md"
if out="$(python3 "$checker" "$work_dir/direction-line.md" 2>&1)"; then
  bad "a node packed onto \`direction LR;\` was accepted, though mermaid draws none of it"
else
  case "$out" in
    *"put that on a line of its own"*)
      ok "a node packed onto \`direction\` is refused, and the remedy named is a new line, not a \";\"" ;;
    *) bad "refused, but not naming the line the statement needs: $out" ;;
  esac
fi

# `direction` in a node shape that carries no "[" either. Mermaid parses this
# line and then draws none of it -- the run on 2026-09-10 came back with only
# a and b as vertices and only a->b as an edge -- so the label is never
# measured and never rendered.
{
  printf '```mermaid\nflowchart TD\n  a["one"] --> b["two"]\n'
  printf '  direction LR; c1(("%s")) --> c2(("ok"))\n' "$(printf 'x%.0s' {1..200})"
  printf '```\n'
} >"$work_dir/direction-round.md"
if out="$(python3 "$checker" "$work_dir/direction-round.md" 2>&1)"; then
  bad "a round node packed onto \`direction LR;\` was accepted, though mermaid draws none of it"
else
  case "$out" in
    *"put that on a line of its own"*)
      ok "a round node packed onto \`direction\` is refused, and the remedy named is a new line" ;;
    *) bad "refused, but not naming the line the statement needs: $out" ;;
  esac
fi

# The other half of the same claim, with no label on the line at all: a link
# written behind `direction` is drawn by nothing, so a block whose only link
# sits there is not a graph and does not pass. The link itself is what marks
# the packed statement now, so the message names that rather than the missing
# link -- it says what to change, where "no link between any two nodes" asked
# the author to add an edge they had already drawn.
cat >"$work_dir/direction-swallows.md" <<'MD'
```mermaid
flowchart TD
  subgraph s["the board"]
  direction LR; a --> b
  end
```
MD
if out="$(python3 "$checker" "$work_dir/direction-swallows.md" 2>&1)"; then
  bad "a block whose only link sits behind \`direction LR;\` was called a graph"
else
  case "$out" in
    *"put that on a line of its own"*)
      ok "a link written behind \`direction\` on its line does not pass, and the message names the line it needs" ;;
    *) bad "refused, but not for the statement packed onto direction: $out" ;;
  esac
fi

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

# A subgraph id mermaid accepts and no identifier regex does: a path. Mermaid
# puts no constraint on the id beyond the "[" that ends it, so the bracket is
# what tells the bracketed form from the bare one. Review of PR #31 on
# 2026-09-10 found the id matched against IDENT instead, which stopped at the
# "/", read the whole statement as a bare title, and refused a 78-character
# title as 94 characters -- quoting a title the author never wrote, which is
# the failure the fix above was written to remove. Every id holding a "/", ":",
# "#", "+", "&", a space or a non-ASCII letter failed the same way, so the
# cases below spread across those shapes.
for sub_id in "skills/board" "s:1" "s#1" "café"; do
  {
    printf '```mermaid\nflowchart TD\n'
    printf '  subgraph %s["a title"]\n' "$sub_id"
    printf '  a["one"] --> b["two"]\n  end\n```\n'
  } >"$work_dir/subgraph-id.md"
  if out="$(python3 "$checker" "$work_dir/subgraph-id.md" 2>&1)"; then
    [[ -z "$out" ]] && ok "a subgraph id \"$sub_id\" is read as an id, not as part of the title" \
      || bad "accepted the id \"$sub_id\", but printed something: $out"
  else
    bad "a subgraph id \"$sub_id\" made the checker measure the id as the title: $out"
  fi
done

# An over-budget title on a statement that is ALSO missing its separator:
# both are reported. The title was already read when the separator was found
# missing, and scan()'s own docstring says a label already read comes back
# beside the error. Review of PR #31 on 2026-09-10 found it thrown away with
# the exception, so the author fixed the separator and only then learned the
# title was over budget -- two rounds for one line.
z85="$(printf 'z%.0s' {1..85})"
{
  printf '```mermaid\nflowchart TD\n'
  printf '  subgraph s["%s"] a["one"] --> b["two"]\n' "$z85"
  printf '  end\n```\n'
} >"$work_dir/subgraph-title-and-separator.md"
if out="$(python3 "$checker" "$work_dir/subgraph-title-and-separator.md" 2>&1)"; then
  bad "a subgraph line over budget AND missing its separator was accepted"
else
  case "$out" in
    *"85 characters"*"text after the title"*)
      ok "an over-budget subgraph title is reported beside the separator it is missing" ;;
    *) bad "refused, but did not report both the title and the separator: $out" ;;
  esac
fi

# A `%%` comment written after a statement: refused, and the message says the
# comment must begin its own line. Mermaid strips a comment ONLY where it
# begins one -- cleanupComments is `/^\s*%%(?!{)[^\n]+\n?/gm` -- so the line
# below is a parse error and the whole diagram draws nothing. The round before
# this one read mermaid's lexer instead of running it, dropped the comment
# wherever it fell, and called the block a graph; review of PR #31 on
# 2026-09-10 ran mermaid 11.17.2 over both lines and got `Parse error on line
# 2` for each.
cat >"$work_dir/trailing-comment-edge.md" <<'MD'
```mermaid
flowchart TD
  a["one"] --> b["two"] %% why
```
MD
if out="$(python3 "$checker" "$work_dir/trailing-comment-edge.md" 2>&1)"; then
  bad "a %% comment after an edge statement was accepted, though mermaid cannot parse the line"
else
  case "$out" in
    *"must begin its own line"*)
      ok "a %% comment after an edge statement is refused, naming the line a comment needs" ;;
    *) bad "refused, but not for the comment: $out" ;;
  esac
fi

# The same on a subgraph line, where the remedy the checker names is what the
# round before got wrong twice: first a ";", which does not put a comment on a
# line of its own, then dropping the comment entirely.
cat >"$work_dir/trailing-comment-subgraph.md" <<'MD'
```mermaid
flowchart TD
  subgraph s["the board"] %% the cluster
  a["one"] --> b["two"]
  end
```
MD
if out="$(python3 "$checker" "$work_dir/trailing-comment-subgraph.md" 2>&1)"; then
  bad "a %% comment after a subgraph title was accepted, though mermaid cannot parse the line"
else
  case "$out" in
    *'separate statements with ";"'*)
      bad "refused a trailing comment by naming a \";\", which does not put it on a line of its own: $out" ;;
    *"must begin its own line"*)
      ok "a %% comment after a subgraph title is refused, naming the line a comment needs" ;;
    *) bad "refused, but not for the comment: $out" ;;
  esac
fi

# A comment that DOES begin its line is dropped, as mermaid drops it. This is
# the half of the rule the fix above must not take with it.
cat >"$work_dir/own-line-comment.md" <<'MD'
```mermaid
flowchart TD
  %% why this graph is shaped like this
  a["one"] --> b["two"]
```
MD
if out="$(python3 "$checker" "$work_dir/own-line-comment.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a %% comment on a line of its own is dropped, as mermaid drops it" \
    || bad "accepted, but printed something: $out"
else
  bad "a %% comment on its own line was read as graph syntax: $out"
fi

# A "%%" inside an edge label is label text, and the label is measured whole.
# Mermaid parses this line and draws the edge, so refusing it would turn a
# valid line into a rewrite the author has to guess at; the round before this
# one truncated the line at the "%%" and reported an edge label that never
# closes, naming a cause that is not there.
cat >"$work_dir/percent-in-edge-label.md" <<'MD'
```mermaid
flowchart TD
  a["one"] -->|100%% done here in this label| b["two"]
```
MD
if out="$(python3 "$checker" "$work_dir/percent-in-edge-label.md" 2>&1)"; then
  bad "an edge label holding %% was cut at it and passed under the word budget"
else
  case "$out" in
    *"never closes"*)
      bad "an edge label holding %% was reported as never closing, which is not what is wrong with it: $out" ;;
    *"edge label"*"6 words"*)
      ok "a %% inside an edge label is label text, and the label is measured whole" ;;
    *) bad "refused, but not for the whole edge label's word count: $out" ;;
  esac
fi

# And a "%%" written after a STYLING statement is accepted, because mermaid
# accepts it: its style lexer skips a comment where the graph lexer does not.
# Measured, not assumed -- `style a fill:#f00 %% why` and `direction LR %% turn`
# both parse in mermaid 11.17.2.
cat >"$work_dir/styling-comment.md" <<'MD'
```mermaid
flowchart TD
  a["one"] --> b["two"]
  style a fill:#f00 %% why
  linkStyle 0 stroke:#f00 %% and this
```
MD
if out="$(python3 "$checker" "$work_dir/styling-comment.md" 2>&1)"; then
  [[ -z "$out" ]] && ok "a %% comment after a styling statement is accepted, as mermaid accepts it" \
    || bad "accepted, but printed something: $out"
else
  bad "a %% comment after a styling statement was refused, though mermaid parses the line: $out"
fi

# The other side of that: a "%%" inside a quoted label is label text, and the
# label is still measured. A stripper that ignored quotes would cut the label
# in half and report a shorter one than the diagram draws.
cat >"$work_dir/quoted-percent.md" <<'MD'
```mermaid
flowchart TD
  c1["one two %% three four five six seven"] --> c2["ok"]
```
MD
if out="$(python3 "$checker" "$work_dir/quoted-percent.md" 2>&1)"; then
  bad "a label holding %% was cut at it and passed under the word budget"
else
  case "$out" in
    *"node c1"*"words"*) ok "a %% inside a quoted label is label text, and the label is measured whole" ;;
    *) bad "refused, but not for the whole label's word count: $out" ;;
  esac
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
# flag -- see the comment above Budget for why 80 is a default calibrated on
# this tree and not a ceiling on every tree.
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
limits="$(python3 "$checker" --limits)"
checker_limits="$(printf '%s\n' "$limits" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
skill_words="$(tr -s '[:space:]' ' ' <"$skill")"
case "$skill_words" in
  *"$checker_limits"*)
    ok "SKILL.md states the exact budget bin/check-plan-graph.py --limits prints"
    ;;
  *)
    bad "SKILL.md and bin/check-plan-graph.py --limits disagree.
--limits says:
$limits

If bin/check-plan-graph.py was changed, SKILL.md's budget sentence was not
updated to match. If SKILL.md was changed, its budget sentence no longer
reads as the checker's LIMITS constant, word for word."
    ;;
esac

# SKILL.md is allowed exactly one copy of the budget numbers: the copy of
# --limits matched above. Every other number it names beside "words", "lines"
# or "characters" is a second copy, drifting out of step with MAX_LABEL_WORDS
# and friends -- what "a four-word budget" was, in prose nothing compared to
# the constant, until round-2 review of PR #25 caught it on 2026-09-09.
#
# The guard is a tracked file, not a heredoc, so bin/check-syntax.sh parses it
# as Python like every other source here. It takes the file it reads as an
# argument, so SKILL.md and the fixtures below go through the same code: a
# guard whose only input is a file that passes reports coverage it has not got.
guard="$repo_root/tests/lib/budget-drift-guard.py"

# Its three answers are reported apart. A guard that crashes, or one that finds
# no copy of --limits to exempt, says nothing about drift, and reporting either
# as drift sends the reader to edit a file that is already right.
drift() {
  guard_out="$(python3 "$guard" "$1" "$limits" 2>&1)"
  guard_exit=$?
}

drift "$skill"
case "$guard_exit" in
  0) ok "SKILL.md states no budget number outside its one copy of --limits" ;;
  1) bad "SKILL.md states a budget number outside its one copy of --limits:
$guard_out
The budget is stated once, in the block that reproduces --limits. Point each of
these at that block, or reword it to name no number. A second copy drifts when
a limit changes, and a stale one still reads as the rule." ;;
  *) bad "the drift guard could not read SKILL.md, so nothing was checked:
$guard_out" ;;
esac

# A number the checker no longer enforces: reported. This is the drift the
# guard exists to catch -- a limit changed, and the prose kept the old number
# -- and a guard that searches only for today's limits is the one thing that
# cannot see it. Review of PR #34 on 2026-09-10 found exactly that version
# here, where the grep it replaced had caught this case.
{
  printf '**The budget**, enforced by the checker:\n\n```text\n%s\n```\n\n' "$limits"
  printf 'A label line holds seven words and fits in 72 characters.\n'
} >"$work_dir/stale-budget.md"
drift "$work_dir/stale-budget.md"
if [[ "$guard_exit" -ne 1 ]]; then
  bad "the drift guard read a superseded limit as no offender at all (exit $guard_exit):
$guard_out"
else
  case "$guard_out" in
    *"seven words"*"72 characters"*)
      ok "the drift guard reports a number the checker no longer enforces" ;;
    *) bad "the drift guard refused the fixture, but not for the superseded numbers:
$guard_out" ;;
  esac
fi

# A copy the prose wrap splits in two: reported, with the line it starts on.
# Invisibility to the wrap is the fault that let "80 characters" live in the
# file this guards. The fence carries a language tag, because the guard this
# replaced found the exempt copy by the fence and a tag moved the range.
#
# The line is computed from --limits, not typed: a line added to LIMITS moves
# the copy down the fixture, and a fixture that pins the number reports the
# guard broken when only the fixture moved.
wrapped_line=$(( $(printf '%s\n' "$limits" | wc -l) + 6 ))
{
  printf '**The budget**, enforced by the checker:\n\n```text\n%s\n```\n\n' "$limits"
  printf 'Every label line renders inside eighty\ncharacters, so this copy drifts.\n'
} >"$work_dir/wrapped-budget.md"
drift "$work_dir/wrapped-budget.md"
if [[ "$guard_exit" -ne 1 ]]; then
  bad "the drift guard read a budget number split by a newline as no offender (exit $guard_exit):
$guard_out"
else
  case "$guard_out" in
    *"wrapped-budget.md:$wrapped_line: eighty characters"*)
      ok "the drift guard reports a budget number the wrap splits, with its line number" ;;
    *) bad "the drift guard refused the fixture, but not for the wrapped copy on line $wrapped_line:
$guard_out" ;;
  esac
fi

# A file stating no copy of --limits at all: refused as unanswerable, not
# reported as drift. The guard this replaced gave every failure the same
# message, so a crash read as "SKILL.md restates the budget" and sent the
# reader to edit a file that was already right (review, 2026-09-10).
printf 'A label line holds four words.\n' >"$work_dir/no-budget.md"
drift "$work_dir/no-budget.md"
if [[ "$guard_exit" -eq 2 ]]; then
  ok "a file stating no copy of --limits is refused as unanswerable, not as drift"
else
  bad "a file with no copy of --limits to exempt exited $guard_exit, not 2:
$guard_out"
fi

exit "$fail"
