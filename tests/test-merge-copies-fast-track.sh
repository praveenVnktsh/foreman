#!/usr/bin/env bash
# merge.py copies the card's fast-track label to the pull request before merging.
#
# A target that queues deploys fast-tracks only a merged PR carrying the label
# `[deploy] fast_track_label` names. The operator marks urgency on the Linear
# card. A merge that skips the copy, or merges after the copy failed, silently
# queues a deploy the operator asked to hurry.
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

# The stub gh logs `<physical cwd>|<argv>` per call. GH_FAIL_ON names the first
# two arguments of the call that fails, e.g. "pr edit".
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$GH_LOG"
if [[ -n "${GH_FAIL_ON:-}" && "$1 $2" == "$GH_FAIL_ON" ]]; then
  echo "could not add label: 'fast-track' not found" >&2
  exit 1
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
name="a card without fast-track merges with no label call"
run_merge fast "" '{"identifier":"PRA-2","labels":{"nodes":[{"name":"bug"},{"name":"fast-track-later"}]}}'
if [[ "$status" -eq 0 && "$(line_of "pr merge 42 --squash")" -gt 0 ]] \
   && ! grep -q '|pr edit' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

# --- 3 ------------------------------------------------------------------------
name="a failed label copy refuses the merge and reports why"
run_merge fast "pr edit" '{"identifier":"PRA-3","labels":{"nodes":[{"name":"fast-track"}]}}'
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
   && ! grep -q '|pr edit' "$log" \
   && [[ "$(json_field merged)" == true && "$(json_field fast_tracked)" == false \
         && "$(json_field label)" == '""' ]] \
   && ! cut -d'|' -f1 "$log" | grep -v -x -F -- "$plain_phys" >/dev/null; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all merge fast-track cases passed"
