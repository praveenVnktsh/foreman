#!/usr/bin/env bash
# merge.py makes the pull request's fast-track label match the card before merging.
#
# A target that queues deploys fast-tracks only a merged PR carrying the label
# `[deploy] fast_track_label` names. The operator marks urgency on the Linear
# card. A merge that skips the copy, or merges after the copy failed, silently
# queues a deploy the operator asked to hurry. A label left on the PR that the
# card no longer carries fast-tracks a deploy nobody asked to hurry, so merge.py
# reads the PR's labels and removes it.
#
# Only gh is stubbed, because gh is the external boundary. config.sh,
# contract.py and route.py run for real. The stub logs each call's working
# directory and argv, so the test asserts the order of calls, not only that
# they happened.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

failures=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

merge="$repo_root/skills/board/merge.py"

# Two targets. `fast` declares the label; `plain` does not. TOML forbids a
# second [deploy] header, so the key goes in under the existing one.
fast_repo="$work_dir/target-fast"
plain_repo="$work_dir/target-plain"
mkdir -p "$fast_repo" "$plain_repo"
fixture_board_toml "$fast_repo"
fixture_board_toml "$plain_repo"
awk '{ print } /^\[deploy\]$/ { print "fast_track_label = \"fast-track\"" }' \
  "$fast_repo/board.toml" > "$fast_repo/board.toml.new"
mv "$fast_repo/board.toml.new" "$fast_repo/board.toml"
grep -q '^fast_track_label = "fast-track"$' "$fast_repo/board.toml" \
  || { echo "FAIL: fixture did not declare fast_track_label" >&2; exit 1; }

home="$work_dir/home"
fixture_add_instance "$home" fast "$fast_repo"
fixture_add_instance "$home" plain "$plain_repo"

# The stub gh logs `<physical cwd>|<argv>` per call. GH_FAIL_ON is a substring
# of the full argv of the call that fails, e.g. "--add-label", "--remove-label",
# "--json labels" or "isCrossRepository", so each call can fail on its own.
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$GH_LOG"
if [[ -n "${GH_FAIL_ON:-}" && "$*" == *"$GH_FAIL_ON"* ]]; then
  echo "gh refused: 'fast-track' not found" >&2
  exit 1
fi
if [[ "$1 $2" == "pr view" ]]; then
  if [[ "$*" == *"--json labels"* ]]; then
    # The PR's labels as `gh pr view --json labels` prints them. GH_PR_LABELS is
    # a space-separated list of names, none by default.
    printf '{"labels":['
    sep=""
    for l in ${GH_PR_LABELS:-}; do
      printf '%s{"name":"%s"}' "$sep" "$l"
      sep=","
    done
    printf ']}\n'
  else
    # merge.py asks where the head branch lives before it touches the PR. Real
    # gh answers `false` for a pull request from this repository, so that is the
    # default; GH_CROSS_REPO lets a case answer `true`, or something that is neither.
    printf '%s\n' "${GH_CROSS_REPO-false}"
  fi
fi
exit 0
SH
chmod +x "$stub_bin/gh"

# run_merge <board> <fail_on> <card-json>
# Sets status, out and log. REPO is unset so the board's declared repo wins.
run_merge() {
  local board="$1" fail_on="$2" card="$3"
  log="$work_dir/gh-$board-$RANDOM.log"
  : > "$log"
  status=0
  out="$(printf '%s' "$card" | env -u REPO HOME="$home" FOREMAN_HOME="$home/.foreman" \
    FOREMAN_INSTANCE="$board" PATH="$stub_bin:$PATH" GH_LOG="$log" \
    GH_FAIL_ON="$fail_on" python3 "$merge" 42)" || status=$?
}

json_field() {
  python3 -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(json.dumps(v))' "$out" "$1"
}

# line_of <pattern>: the 1-based line in the log whose argv equals <pattern>, or 0.
line_of() {
  local n
  n="$(cut -d'|' -f2- "$log" | grep -n -x -F -- "$1" | head -n1 | cut -d: -f1)"
  echo "${n:-0}"
}

fast_phys="$(cd "$fast_repo" && pwd -P)"
plain_phys="$(cd "$plain_repo" && pwd -P)"

# --- 1 ------------------------------------------------------------------------
name="a card carrying fast-track gets the label on its PR before the merge"
run_merge fast "" '{"identifier":"PRA-1","labels":{"nodes":[{"name":"bug"},{"name":"fast-track"}]}}'
edit_at="$(line_of "pr edit 42 --add-label fast-track")"
merge_at="$(line_of "pr merge 42 --squash")"
if [[ "$status" -eq 0 && "$edit_at" -gt 0 && "$merge_at" -gt "$edit_at" \
      && "$(json_field merged)" == true && "$(json_field fast_tracked)" == true \
      && "$(json_field label)" == '"fast-track"' ]]; then
  ok "$name"
else
  bad "$name (exit $status, edit line $edit_at, merge line $merge_at, out: $out, log: $(cat "$log"))"
fi

name="every gh call runs in the target repository"
if [[ -s "$log" ]] && ! cut -d'|' -f1 "$log" | grep -v -x -F -- "$fast_phys" >/dev/null; then
  ok "$name"
else
  bad "$name (expected $fast_phys, log: $(cat "$log"))"
fi

# --- 2 ------------------------------------------------------------------------
name="a card without fast-track on a PR without it merges with no label change"
GH_PR_LABELS="bug fast-track-later" run_merge fast "" '{"identifier":"PRA-2","labels":{"nodes":[{"name":"bug"},{"name":"fast-track-later"}]}}'
read_at="$(line_of "pr view 42 --json labels")"
if [[ "$status" -eq 0 && "$read_at" -gt 0 && "$(line_of "pr merge 42 --squash")" -gt "$read_at" ]] \
   && ! grep -q '|pr edit' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 3 ------------------------------------------------------------------------
name="a failed label copy refuses the merge and reports why"
run_merge fast "--add-label" '{"identifier":"PRA-3","labels":{"nodes":[{"name":"fast-track"}]}}'
reason="$(json_field reason 2>/dev/null || true)"
if [[ "$status" -eq 1 && "$(line_of "pr edit 42 --add-label fast-track")" -gt 0 ]] \
   && ! grep -q '|pr merge' "$log" \
   && [[ "$(json_field merged)" == false && "$(json_field fast_tracked)" == false \
         && "$reason" == *"not found"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 4 ------------------------------------------------------------------------
name="a target without fast_track_label merges a labelled card with no label call"
run_merge plain "" '{"identifier":"PRA-4","labels":{"nodes":[{"name":"fast-track"}]}}'
if [[ "$status" -eq 0 && "$(line_of "pr merge 42 --squash")" -gt 0 ]] \
   && ! grep -q '|pr edit' "$log" && ! grep -q 'labels' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false \
         && "$(json_field label)" == '""' ]] \
   && ! cut -d'|' -f1 "$log" | grep -v -x -F -- "$plain_phys" >/dev/null; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 5 ------------------------------------------------------------------------
# THE CASE THAT MATTERS ONCE THE REPOSITORY IS PUBLIC. A fork's pull request can
# carry a board branch's exact name, and a PR number carries no record of where
# it came from. So merge.py establishes the origin itself, and a fork is refused
# before ANY call that changes the PR -- the label included: copying the
# operator's fast-track label onto a stranger's pull request is a change too.
name="a pull request from a fork is refused before it is labelled or merged"
GH_CROSS_REPO=true run_merge fast "" '{"identifier":"PRA-5","labels":{"nodes":[{"name":"fast-track"}]}}'
reason="$(json_field reason 2>/dev/null || true)"
if [[ "$status" -eq 4 ]] \
   && ! grep -q '|pr edit' "$log" && ! grep -q '|pr merge' "$log" \
   && ! grep -q 'labels' "$log" \
   && [[ "$(json_field merged)" == false && "$(json_field fast_tracked)" == false \
         && "$reason" == *"another repository"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 6 ------------------------------------------------------------------------
# An origin nobody established is not "this repository". A failed `gh pr view`
# and an answer that is neither true nor false both refuse: the cost of guessing
# wrong is a stranger's code on main.
name="an origin that cannot be established is refused, not assumed"
run_merge fast "isCrossRepository" '{"identifier":"PRA-6","labels":{"nodes":[]}}'
view_failed_status="$status"; view_failed_log="$(cat "$log")"
GH_CROSS_REPO="" run_merge fast "" '{"identifier":"PRA-6","labels":{"nodes":[]}}'
if [[ "$view_failed_status" -eq 4 && "$status" -eq 4 ]] \
   && ! grep -q '|pr merge' <<<"$view_failed_log" && ! grep -q '|pr merge' "$log" \
   && ! grep -q 'labels' <<<"$view_failed_log" && ! grep -q 'labels' "$log" \
   && [[ "$(json_field merged)" == false ]]; then
  ok "$name"
else
  bad "$name (failed view: exit $view_failed_status; empty answer: exit $status, out: $out)"
fi

# --- 7 ------------------------------------------------------------------------
# The card is the only source. A label on the PR the card does not carry -- left
# by a failed earlier tick, a build agent, or a person -- would fast-track the
# deploy all the same, so it comes off before the merge.
name="a fast-track label the card lacks is removed from the PR before the merge"
GH_PR_LABELS="bug fast-track" run_merge fast "" '{"identifier":"PRA-7","labels":{"nodes":[{"name":"bug"}]}}'
read_at="$(line_of "pr view 42 --json labels")"
remove_at="$(line_of "pr edit 42 --remove-label fast-track")"
merge_at="$(line_of "pr merge 42 --squash")"
if [[ "$status" -eq 0 && "$read_at" -gt 0 && "$remove_at" -gt "$read_at" && "$merge_at" -gt "$remove_at" ]] \
   && ! grep -q -- '--add-label' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false ]]; then
  ok "$name"
else
  bad "$name (exit $status, read $read_at, remove $remove_at, merge $merge_at, out: $out, log: $(cat "$log"))"
fi

# --- 8 ------------------------------------------------------------------------
name="a failed removal of a label the card lacks refuses the merge and reports why"
GH_PR_LABELS="fast-track" run_merge fast "--remove-label" '{"identifier":"PRA-8","labels":{"nodes":[]}}'
reason="$(json_field reason 2>/dev/null || true)"
if [[ "$status" -eq 1 && "$(line_of "pr edit 42 --remove-label fast-track")" -gt 0 ]] \
   && ! grep -q '|pr merge' "$log" \
   && [[ "$(json_field merged)" == false && "$reason" == *"not found"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 9 ------------------------------------------------------------------------
name="a failed read of the PR's labels refuses the merge and changes nothing"
run_merge fast "--json labels" '{"identifier":"PRA-9","labels":{"nodes":[{"name":"fast-track"}]}}'
reason="$(json_field reason 2>/dev/null || true)"
if [[ "$status" -eq 1 && "$(line_of "pr view 42 --json labels")" -gt 0 ]] \
   && ! grep -q '|pr edit' "$log" && ! grep -q '|pr merge' "$log" \
   && [[ "$(json_field merged)" == false && "$(json_field fast_tracked)" == false \
         && "$reason" == *"not found"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 10 -----------------------------------------------------------------------
name="a card carrying fast-track on a PR that already has it merges fast-tracked"
GH_PR_LABELS="fast-track" run_merge fast "" '{"identifier":"PRA-10","labels":{"nodes":[{"name":"fast-track"}]}}'
if [[ "$status" -eq 0 && "$(line_of "pr merge 42 --squash")" -gt 0 ]] \
   && ! grep -q -- '--remove-label' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == true ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 11 -----------------------------------------------------------------------
# GitHub labels are case-insensitive. gh pr view returns the stored name
# (Fast-Track) while FAST_TRACK_LABEL is fast-track. Exact membership misses
# it, so the stale label stays on and the merge still fast-tracks. PRA-459.
name="a differently-cased fast-track label the card lacks is removed before the merge"
GH_PR_LABELS="Fast-Track" run_merge fast "" '{"identifier":"PRA-11","labels":{"nodes":[{"name":"bug"}]}}'
remove_at="$(line_of "pr edit 42 --remove-label fast-track")"
merge_at="$(line_of "pr merge 42 --squash")"
if [[ "$status" -eq 0 && "$remove_at" -gt 0 && "$merge_at" -gt "$remove_at" ]] \
   && ! grep -q -- '--add-label' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false ]]; then
  ok "$name"
else
  bad "$name (exit $status, remove $remove_at, merge $merge_at, out: $out, log: $(cat "$log"))"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all merge fast-track cases passed"
