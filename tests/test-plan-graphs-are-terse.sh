#!/usr/bin/env bash
# Claim: every plan under docs/plans/ is a graph inside the word budget,
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
# The third failure, found in review on 2026-09-09: a gate that reads the
# labels inside the fence without ever asking whether the fence holds a graph.
# An empty fence passed, one-word-per-line text passed, and a single
# 200-character token passed a budget counted in words. Each is a case below,
# because each was accepted by the version of the checker that this file
# already called green.
#
# The fourth, found in the review of the fix for the third: a budget calibrated
# on what plans had already said rather than on what a plan must be able to
# say, and a keyword line skipped whole, which let a label escape the budget by
# moving one line up. A gate that refuses correct work costs a card an attempt
# exactly as a gate that admits wrong work costs a review round, so both
# directions are cases here: what must be refused, and what must be accepted.
#
# The fifth, from the round after that: the same escape hatch, one keyword at a
# time. `flowchart` and `graph` were read past their semicolon; `class`,
# `classDef`, `style`, `linkStyle`, `direction` and `end` were still skipped a
# whole line at a time, and real plans in docs/plans/ use four of them. A fix
# that closes one seventh of a hole looks exactly like a fix, so every keyword
# is a case below.
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

# An edge label with too many words: refused.
cat >"$work_dir/wordy-edge.md" <<'MD'
```mermaid
flowchart TD
  c3 -->|this edge label has far too many words| c4
```
MD
if out="$(python3 "$checker" "$work_dir/wordy-edge.md" 2>&1)"; then
  bad "an edge label with too many words was accepted"
else
  case "$out" in
    *"edge label"*"words"*) ok "an edge label with too many words is refused" ;;
    *) bad "refused, but not for edge word count: $out" ;;
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

# An edge label written inline rather than in pipes: refused, not skipped.
cat >"$work_dir/inline-edge.md" <<'MD'
```mermaid
flowchart TD
  c9 -- this edge label has far too many words to be allowed --> c10
```
MD
if out="$(python3 "$checker" "$work_dir/inline-edge.md" 2>&1)"; then
  bad "an inline edge label was accepted, and it is 11 words long"
else
  case "$out" in
    *"belongs in pipes"*) ok "an edge label written inline is refused" ;;
    *) bad "refused, but not for the inline label: $out" ;;
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

exit "$fail"
