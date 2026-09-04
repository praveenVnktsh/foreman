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
# What is deliberately NOT covered: rendering (another test owns it) and the
# wording of SKILL.md's prose, only the two lines it must reproduce verbatim.
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

# A terse graph: accepted.
cat >"$work_dir/terse.md" <<'MD'
```mermaid
flowchart TD
  c6["<b>c6 · brief.py</b> · CHANGE<br/>writes the dispatch prompt"]
  c7["<b>c7 · queue.py</b> · CHANGE<br/>orders todo cards"]
  c6 -->|feeds| c7
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
