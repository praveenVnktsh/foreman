#!/usr/bin/env bash
# merge.py merges only the pull request that was reviewed, at the commit reviewed.
#
# Found auditing the board on 2026-09-30: merge.py named only a PR number, so a
# push after the review, a closed PR, or a PR retargeted at another branch all
# merged. Now it reads the PR's state, base and head before any label call,
# refuses with exit 5 when one differs, and pins the merge with
# --match-head-commit. BOARD_DRY_RUN makes no gh write at all and exits 6.
#
# Only gh is stubbed, because gh is the external boundary. config.sh,
# contract.py and route.py run for real.

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

# The target declares a fast-track label, so a dry run proves that even the
# label edit is skipped, not only the merge.
target="$work_dir/target"
mkdir -p "$target"
fixture_board_toml "$target"
awk '{ print } /^\[deploy\]$/ { print "fast_track_label = \"fast-track\"" }' \
  "$target/board.toml" > "$target/board.toml.new"
mv "$target/board.toml.new" "$target/board.toml"
home="$work_dir/home"
fixture_add_instance "$home" demo "$target"

reviewed=0123456789abcdef0123456789abcdef01234567
pushed_after=fedcba9876543210fedcba9876543210fedcba98

# The stub gh logs each call's argv. The PR it describes is set per case:
# GH_PR_STATE, GH_PR_BASE, GH_PR_HEAD, and GH_DEFAULT_BRANCH for the repository.
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    if [[ "$*" == *"--json labels"* ]]; then
      echo '{"labels":[]}'
    else
      printf '{"state":"%s","baseRefName":"%s","headRefOid":"%s","isCrossRepository":false}\n' \
        "$GH_PR_STATE" "$GH_PR_BASE" "$GH_PR_HEAD"
    fi
    ;;
  "repo view") echo "$GH_DEFAULT_BRANCH" ;;
esac
exit 0
SH
chmod +x "$stub_bin/gh"

# run_merge [extra env...] -- sets status, out and log. The card carries the
# fast-track label, so a real run would edit the PR before merging it.
run_merge() {
  log="$work_dir/gh-$RANDOM.log"
  : > "$log"
  status=0
  out="$(printf '%s' '{"identifier":"PRA-1","labels":{"nodes":[{"name":"fast-track"}]}}' \
    | env -u REPO -u BOARD_DRY_RUN HOME="$home" FOREMAN_HOME="$home/.foreman" \
      FOREMAN_INSTANCE=demo PATH="$stub_bin:$PATH" GH_LOG="$log" \
      GH_PR_STATE=OPEN GH_PR_BASE=main GH_PR_HEAD="$reviewed" GH_DEFAULT_BRANCH=main \
      "$@" python3 "$merge" 42 --head "$reviewed")" || status=$?
}

json_field() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$out" "$1"
}

# no_write: the log holds no gh call that changes the PR.
no_write() { ! grep -q -e '^pr edit' -e '^pr merge' "$log"; }

name="the reviewed head merges pinned with --match-head-commit"
run_merge
if [[ "$status" -eq 0 ]] \
   && grep -q -x -F -- "pr merge 42 --squash --match-head-commit $reviewed" "$log" \
   && [[ "$(json_field merged)" == True ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="a head pushed after the review is refused with exit 5 before any label call"
run_merge GH_PR_HEAD="$pushed_after"
if [[ "$status" -eq 5 ]] && no_write && ! grep -q 'labels' "$log" \
   && [[ "$(json_field merged)" == False && "$(json_field reason)" == *"$pushed_after"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="a closed pull request is refused with exit 5"
run_merge GH_PR_STATE=CLOSED
if [[ "$status" -eq 5 ]] && no_write && [[ "$(json_field reason)" == *CLOSED* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="a pull request whose base is not the default branch is refused with exit 5"
run_merge GH_PR_BASE=release
if [[ "$status" -eq 5 ]] && no_write && [[ "$(json_field reason)" == *release* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="a default branch other than main is honoured"
run_merge GH_PR_BASE=trunk GH_DEFAULT_BRANCH=trunk
if [[ "$status" -eq 0 ]] && grep -q '^pr merge' "$log"; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="BOARD_DRY_RUN exits 6 and makes no gh write"
run_merge BOARD_DRY_RUN=1
if [[ "$status" -eq 6 ]] && no_write \
   && [[ "$(json_field merged)" == False && "$(json_field reason)" == "dry run"* ]]; then
  ok "$name"
else
  bad "$name (exit $status, out: $out, log: $(cat "$log"))"
fi

name="a merge without --head is refused as a usage error with no gh call"
log="$work_dir/gh-nohead.log"; : > "$log"; status=0
printf '{"labels":[]}' | env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
  PATH="$stub_bin:$PATH" GH_LOG="$log" python3 "$merge" 42 >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 2 && ! -s "$log" ]]; then
  ok "$name"
else
  bad "$name (exit $status, log: $(cat "$log"))"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all merge head-pinning cases passed"
