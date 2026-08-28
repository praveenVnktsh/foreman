#!/usr/bin/env bash
# `evidence.sh` must never answer from a ref that some earlier fetch left behind.
#
# This is the harness for the defect that survived the first round of this card.
# The first version prescribed `git show origin/main:<path>` as the sanctioned
# verification read, on the argument that it is "current at the instant of the
# read". It is not. `git show` resolves the LOCAL ref `refs/remotes/origin/main`
# and touches no network. No fetch is *guaranteed* between a merge and a later
# read: step 0's preflight does not fetch at all, and `dispatch.sh` fetches only
# when a card is actually dispatched. A tick that merges in pass 1 and dispatches
# nothing after it never refreshes that ref again.
#
# So the blessed command reproduced the outage it was written for:
#
#   12:00  step 0 fetches; refs/remotes/origin/main = X
#   12:03  pass 1 merges a PR adding `--exclude='.claude/'` to deploy.sh
#   12:07  pass 3 weighs a blocking finding claiming the deploy strips
#          `.claude/`, runs `git show origin/main:ops/deploy.sh`, reads
#          blob X, greps nothing, refutes a correct finding, and merges
#
# A staleness number on the checkout could not catch that either -- `rev-list
# HEAD..origin/main` measures against the same stale ref, so it prints 0 and
# confirms the lie -- which is why preflight no longer computes one.
#
# What is pinned here, in order:
#
#   1. `git show origin/main:<path>` really does go stale that way -- asserted
#      directly, so the reason this helper exists cannot quietly stop being true
#   2. `evidence.sh main <path>` returns the NEW content on the same repo, in
#      the same state, with no fetch in between
#   3. it says where the bytes came from, with the SHA, on stderr -- the part an
#      overrule is required to paste onto the card
#   4. an unreachable origin produces no content and a non-zero exit, rather
#      than falling back to the local ref. Serving stale bytes under a confident
#      provenance line is the failure above with better paperwork.
#   5. concurrent reads answer their own question, and neither leaks a ref
#   6. the `pr <n>` DIFF path makes the same promise as the file paths: a head
#      that moves mid-read produces no diff at all. It used to stream the diff
#      before it re-read the head, so its one failing path emitted a full,
#      well-formed patch attributable to neither SHA and complained afterwards
#      on stderr -- and piped as `evidence.sh pr 166 2>/dev/null | grep -c ...`
#      the bytes are consumed and the exit code is invisible.
#   6b. and what that path prints is byte for byte what the server sent -- a
#      missing trailing newline, a blank line at the end. The buffer was a shell
#      variable, and `$(...)` deletes NUL bytes and strips trailing newlines;
#      the assertion was `[[ "$out" == "$(cat ...)" ]]` and could see neither,
#      because command substitution strips the tail off both sides of it. So the
#      repair (`printf '%s\n'`, which re-adds exactly one newline however many
#      there were) passed a test advertised as a byte-exact round trip. The
#      comparison is `cmp` on files now, and case 6b checks that the comparison
#      itself can see one byte, anywhere.
#   6c. a read whose bytes carry a NUL prints NOTHING and exits non-zero, on
#      both the diff and the file path, unless `--text` is given. Emitting it
#      intact is not the safe half of that choice: a NUL makes the whole stream
#      binary, and the documented `evidence.sh … 2>/dev/null | grep` then reads
#      as "the mechanism is absent" for a diff that contains it -- exit 0 and a
#      discarded stderr notice under GNU grep, exit 1 and total silence under
#      the ugrep wrapper the agents run. That is #159 with the audit trail
#      intact and the answer wrong. `--text` still round-trips byte for byte,
#      which is where the buffer's fidelity on NUL-carrying content is pinned.
#   7. a read killed mid-fetch leaves no `refs/foreman/fixture/evidence/<pid>` behind.
#      Nothing else reaps that namespace, and the ref pins every object the
#      fetch brought with it.
#
# Runs against a full checkout, via tests/run-all.sh (Task 9 wires this into
# CI; see docs/plans/2026-08-27-foreman-layer-1.md).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"
evidence="$board_dir/evidence.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$evidence" ]] || {
  echo "FAIL: $evidence is missing or not executable" >&2
  exit 1
}

# The scratch root is asked of bin/tmp-dir.sh, never worked out here -- see
# bin/tmp-dir.sh's own header for why one derivation has to stay singular.
tmp_root="$("$repo_root/bin/tmp-dir.sh")"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# `evidence.sh` buffers a PR diff in a file it unlinks immediately, under the
# scratch root `config.sh` derives from BOARD_HOME. Pointed inside the work dir
# so this test creates nothing under a real installation's board home, and so
# case 6 can assert that nothing is left behind there. Set after TMPDIR above,
# which deliberately asks the real derivation for the real path.
export BOARD_HOME="$work_dir/board-home"

# `evidence.sh` sources config.sh, which since Task 2/3 requires a
# FOREMAN_INSTANCE and an instance directory declaring a REPO whose
# board.toml passes bin/contract.py -- regardless of what REPO is
# subsequently overridden to per call below. AGENT_TMP_ROOT (what evidence.sh
# actually buffers into) is derived from THIS installation's own
# bin/tmp-dir.sh, never the target's, so the fixture repos below need no
# tmp-dir.sh of their own.
inst_home="$work_dir/foreman-home"
fixture_add_instance "$inst_home" fixture
export HOME="$inst_home" FOREMAN_INSTANCE=fixture

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git_q() {
  git -c user.name="Evidence Test" -c user.email="evidence-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# The fixture is the #159 file, in miniature: a deploy script whose `.claude/`
# exclusion lands *after* the tick's checkout was last fetched.
origin="$work_dir/origin.git"
seed="$work_dir/seed"
git_q init -q --bare "$origin"
git_q init -q -b main "$seed"
fixture_board_toml "$seed"
cat > "$seed/deploy.sh" <<'EOF'
#!/usr/bin/env bash
rsync --archive --delete "$source/" "$target/"
EOF
git_q -C "$seed" add deploy.sh board.toml
git_q -C "$seed" commit -q -m "Deploy without the exclude"
git_q -C "$seed" remote add origin "$origin"
git_q -C "$seed" push -q origin main

# The tick's checkout, fetched once at "step 0" and never again.
tick="$work_dir/tick"
git_q clone -q "$origin" "$tick"

# Then the tick merges the PR that adds the exclude. On the real board this is
# `gh pr merge --squash`, which is server-side and moves no local ref -- which
# is precisely why the tick's `origin/main` is now behind its own merge.
cat > "$seed/deploy.sh" <<'EOF'
#!/usr/bin/env bash
rsync --archive --delete \
  --exclude='.claude/' \
  "$source/" "$target/"
EOF
git_q -C "$seed" commit -q -am "Keep .claude/ off the live checkout"
git_q -C "$seed" push -q origin main

# --- 1. the premise: `git show origin/main:` is stale here --------------------
#
# Asserted rather than assumed. If git ever made `show` consult the remote, the
# helper's whole reason for existing would be gone and this file should say so
# loudly rather than keep passing.

stale="$(git -C "$tick" show origin/main:deploy.sh)"
if grep -q -- "--exclude='.claude/'" <<<"$stale"; then
  fail "git show origin/main: returned the new content without a fetch.
  This harness exists because it does not. If git's behaviour changed, the
  argument for evidence.sh has changed with it -- re-read SKILL.md's
  'Refuting a blocking finding' before deleting anything."
fi
echo "  ok: git show origin/main: serves the pre-merge blob, as the outage did"

# --- 2. evidence.sh returns what origin actually holds now --------------------

out="$(REPO="$tick" "$evidence" main deploy.sh 2>"$work_dir/prov.err")"
grep -q -- "--exclude='.claude/'" <<<"$out" || {
  echo "  provenance line was:" >&2
  cat "$work_dir/prov.err" >&2
  fail "evidence.sh main did not return the current content of deploy.sh.
  A tick following the documented bar would refute a correct blocking finding."
}
echo "  ok: evidence.sh returns the post-merge content from the same checkout"

# The two disagreeing is the entire point; if they ever agree here, case 1 has
# stopped reproducing the trap and case 2 proves nothing.
[[ "$out" != "$stale" ]] || fail "evidence.sh and the stale git show agreed"

# --- 3. it says where the bytes came from ------------------------------------
#
# An overrule has to paste this line onto the card. Without the SHA the record
# is a claim; with it, the next tick can ask whether the read was new enough.

expected_sha="$(git -C "$seed" rev-parse HEAD)"
provenance="$(cat "$work_dir/prov.err")"
[[ "$provenance" == *"$expected_sha"* ]] || {
  fail "the provenance line does not carry the SHA that was read:
  wanted $expected_sha
  got:   $provenance"
}
[[ "$provenance" == *"deploy.sh"* && "$provenance" == *"origin/main"* ]] || {
  fail "the provenance line does not name the path and ref: [$provenance]"
}
# Provenance on stderr and content on stdout, so `| grep` still works.
[[ "$out" != *"evidence:"* ]] || fail "the provenance line leaked into stdout"
echo "  ok: provenance names the path, the ref and the exact SHA, on stderr"

# --- 4. an unreachable origin answers nothing, never something stale ---------
#
# The tempting fallback -- "the fetch failed, so serve the local ref" -- is the
# outage with better paperwork, because the provenance line would then vouch for
# bytes nobody re-checked.

git_q -C "$tick" remote set-url origin "$work_dir/no-such-origin.git"
status=0
out="$(REPO="$tick" "$evidence" main deploy.sh 2>"$work_dir/fail.err")" || status=$?
[[ "$status" != "0" ]] || fail "evidence.sh succeeded with an unreachable origin"
[[ -z "$out" ]] || {
  fail "evidence.sh printed content after a failed fetch:
$out"
}
grep -q "could not fetch" "$work_dir/fail.err" || {
  fail "the failure does not say the fetch failed: $(cat "$work_dir/fail.err")"
}
echo "  ok: a failed fetch yields no content and a non-zero exit"

# --- 5. two reads at once do not answer each other's question ----------------
#
# The board runs many agents against one shared `.git` -- `config.sh` resolves
# REPO through `--git-common-dir`, so every worktree's board processes land on
# the same one. `FETCH_HEAD` is a single file there, git takes no lock on it,
# and the obvious implementation of this script wrote and read exactly that.
#
# Measured before the fix: 15 of 15 parallel pairs returned the wrong blob, exit
# 0, nothing on stderr, under a provenance line naming the ref that was *asked
# for* and a SHA that was real and current. That is strictly worse than #159 --
# there the audit trail was absent, here it would vouch for the wrong bytes and
# the "was this newer than the merge it needed to see?" check would answer yes.
#
# This case also carries the mutation coverage the single-threaded ones cannot:
# an explicit refspec updates `refs/remotes/origin/main` opportunistically, so
# swapping the private ref back for `origin/main` still passes cases 1-4 and
# fails here, where the `pr` read would come back as main's.

git_q -C "$tick" remote set-url origin "$origin"

# `refs/pull/7/head` in the fixture, holding content that main does not have --
# which is the real shape: a PR whose file differs from the branch it targets.
pr_seed="$work_dir/pr-seed"
git_q clone -q "$origin" "$pr_seed"
cat > "$pr_seed/deploy.sh" <<'EOF'
#!/usr/bin/env bash
rsync --archive --delete --exclude='vault/' "$source/" "$target/"
EOF
git_q -C "$pr_seed" commit -q -am "A pull request that is not main"
git_q -C "$pr_seed" push -q origin HEAD:refs/pull/7/head

# Both pids are captured and waited on BY PID. An argument-less `wait` returns 0
# unconditionally -- POSIX says so, and `bash -c 'false & wait; echo $?'` prints
# 0 -- so `wait || fail` on the second read was a guard that could never fire,
# and a `pr` read dying outright would have surfaced below as the FETCH_HEAD
# race, pointing at the wrong cause entirely.
races=8
for ((i = 0; i < races; i++)); do
  REPO="$tick" "$evidence" main deploy.sh > "$work_dir/race-main.$i" 2>/dev/null &
  main_pid=$!
  REPO="$tick" "$evidence" pr 7 deploy.sh > "$work_dir/race-pr.$i" 2>/dev/null &
  pr_pid=$!
  wait "$main_pid" || fail "the concurrent 'main' read failed outright"
  wait "$pr_pid" || fail "the concurrent 'pr' read failed outright"
done

for ((i = 0; i < races; i++)); do
  grep -q -- "--exclude='.claude/'" "$work_dir/race-main.$i" || {
    fail "round $i: the concurrent 'main' read did not return main's content:
$(cat "$work_dir/race-main.$i")"
  }
  grep -q -- "--exclude='vault/'" "$work_dir/race-pr.$i" || {
    fail "round $i: the concurrent 'pr 7' read returned something other than the
  pull request's content -- this is the FETCH_HEAD race, and the provenance line
  would have sworn to it:
$(cat "$work_dir/race-pr.$i")"
  }
done
echo "  ok: $races concurrent pairs each answered their own question"

# Nothing accumulates in the shared ref namespace either: a leaked private ref
# per call would keep every fetched commit alive forever in a repository the
# board fetches into every few minutes.
leaked="$(git -C "$tick" for-each-ref --format='%(refname)' 'refs/foreman/fixture/evidence/*')"
[[ -z "$leaked" ]] || fail "evidence.sh left private refs behind:
$leaked"
echo "  ok: no private refs left behind"

# --- 6. the diff path attributes its bytes, or prints none -------------------
#
# `gh` is stubbed rather than reached: this case is about the ORDER of the two
# head reads around the diff, which is a property of the script and not of
# GitHub. The stub serves head SHAs from a file, one per `pr view` call, so a
# head that moves between call 1 and call 2 -- exactly what a resumed build
# agent pushing while the tick works the card produces -- is one line of fixture.

shim_dir="$work_dir/shim"
mkdir -p "$shim_dir"
cat > "$shim_dir/gh" <<'SHIM'
#!/usr/bin/env bash
# The two calls show_pr_diff makes, and nothing else.
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  n=$(( $(cat "$GH_SHIM_STATE/views" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$GH_SHIM_STATE/views"
  sed -n "${n}p" "$GH_SHIM_STATE/heads"
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
  if [[ -f "$GH_SHIM_STATE/diff-fails" ]]; then
    echo "gh: could not read the diff" >&2
    exit 1
  fi
  cat "$GH_SHIM_STATE/diff"
  exit 0
fi
echo "gh stub: unexpected call: $*" >&2
exit 64
SHIM
chmod +x "$shim_dir/gh"

shim_state="$work_dir/shim-state"
mkdir -p "$shim_state"
cat > "$shim_state/diff" <<'DIFF'
diff --git a/deploy.sh b/deploy.sh
--- a/deploy.sh
+++ b/deploy.sh
@@ -1,2 +1,2 @@
-rsync --archive --delete "$source/" "$target/"
+rsync --archive --delete --exclude='.claude/' "$source/" "$target/"
\ No newline at end of file
DIFF

diff_out="$work_dir/diff.out"

# Captured to a FILE, not to `$(...)`. The thing under test is what reaches
# stdout byte for byte, and command substitution here would delete NUL bytes and
# strip the tail off the reply before any assertion could look at it -- so the
# harness would share the exact blindness of the code it is checking.
run_diff() {
  rm -f "$shim_state/views"
  status=0
  REPO="$tick" PATH="$shim_dir:$PATH" GH_SHIM_STATE="$shim_state" \
    "$evidence" pr 166 "$@" >"$diff_out" 2>"$work_dir/diff.err" || status=$?
}

# The one comparison every round trip below goes through, and the one case 6b
# mutates against. Both must call this, or 6b stops guarding anything.
same_bytes() { cmp -s "$1" "$2"; }

# A head that holds still: the diff comes back, attributed to the one SHA.
printf 'aaaaaaa1\naaaaaaa1\n' > "$shim_state/heads"
run_diff
[[ "$status" == "0" ]] || {
  cat "$work_dir/diff.err" >&2
  fail "evidence.sh pr <n> failed on a head that did not move"
}
grep -q -- "--exclude='.claude/'" "$diff_out" || fail "the diff was not returned:
$(cat "$diff_out")"
same_bytes "$diff_out" "$shim_state/diff" || {
  fail "the buffered diff is not what the server returned:
$(cmp "$diff_out" "$shim_state/diff" 2>&1 || true)"
}
grep -q "aaaaaaa1" "$work_dir/diff.err" || {
  fail "the provenance line does not carry the head SHA: $(cat "$work_dir/diff.err")"
}
! grep -q "evidence:" "$diff_out" || fail "the provenance line leaked into stdout"
echo "  ok: a diff read against a still head returns the diff and names the SHA"

# --- 6b. the round trip is byte-exact, and the comparison can prove it --------
#
# Two shapes the old buffer could not carry, and one check that the assertion
# above is not vacuous. The third shape -- a NUL -- is case 6c, because the
# right answer for it is a refusal rather than a round trip.
#
# The NUL fixture is built here because both cases need it. The old code's
# comment argued it could not exist: "it drops NUL bytes, which a diff cannot
# contain, because git calls any file holding one binary". Git's binary test
# scans only the FIRST 8000 BYTES of the blob, so a file that is text for 8KB
# and holds a NUL after it produces an ordinary text diff with the NUL in it --
# confirmed against real git, not argued.

{
  printf 'diff --git a/fixture.txt b/fixture.txt\n'
  printf -- '--- a/fixture.txt\n+++ b/fixture.txt\n@@ -1 +1,2 @@\n'
  # Comfortably past git's 8000-byte binary sniff, so the NUL below is in a diff
  # git itself would have produced as text.
  printf '+%s\n' "$(head -c 8200 /dev/zero | tr '\0' x)"
  printf '+past the sniff window:'
  printf '\0'
  printf 'and text again\n'
} > "$shim_state/diff-nul"

# No trailing newline at all: catches the `printf '%s\n'` that used to re-add
# one whether or not the server sent it.
printf 'diff --git a/a b/b\n@@ -1 +1 @@\n-old\n+new, and no newline here' \
  > "$shim_state/diff-no-eol"

# Two of them: catches the same repair from the other side, because command
# substitution strips *every* trailing newline and the printf restores one.
printf 'diff --git a/a b/b\n@@ -1 +1 @@\n-old\n+new\n\n\n' \
  > "$shim_state/diff-extra-eol"

printf 'aaaaaaa1\naaaaaaa1\n' > "$shim_state/heads"
for shape in no-eol extra-eol; do
  cp "$shim_state/diff-$shape" "$shim_state/diff"
  run_diff
  [[ "$status" == "0" ]] || {
    cat "$work_dir/diff.err" >&2
    fail "evidence.sh pr <n> failed on a $shape diff"
  }
  same_bytes "$diff_out" "$shim_state/diff-$shape" || {
    fail "a $shape diff did not survive the buffer byte for byte. The read
  printed something other than what the server sent, under an evidence: line
  that swears to the whole of it:
$(cmp "$diff_out" "$shim_state/diff-$shape" 2>&1 || true)
  wanted $(wc -c < "$shim_state/diff-$shape") bytes, got $(wc -c < "$diff_out")"
  }
done
echo "  ok: a missing trailing newline and a spare one survive the buffer"

# And the comparison itself can see one byte, anywhere -- including the tail,
# which is where the previous version was blind. Mutations are one byte each:
# a newline appended, a byte removed from the end, a byte removed from the
# middle. The first is deliberately a NEWLINE rather than any old byte, because
# a trailing newline is precisely what the old comparison could not see and what
# the old buffer's `printf '%s\n'` used to add.
mutant="$work_dir/mutant"
original="$shim_state/diff-nul"
size="$(wc -c < "$original")"

cat "$original" > "$mutant"; printf '\n' >> "$mutant"
! same_bytes "$original" "$mutant" || fail "the round-trip comparison cannot see
  a newline appended to the end. That is the defect this case exists for: the
  version it replaces compared two command substitutions, both of which strip
  trailing newlines, so a buffer that re-added one passed a test advertised as
  a byte-exact round trip."

head -c "$((size - 1))" "$original" > "$mutant"
! same_bytes "$original" "$mutant" || fail "the round-trip comparison cannot see
  a byte removed from the end"

{ head -c "$((size / 2))" "$original"; tail -c "+$((size / 2 + 2))" "$original"; } \
  > "$mutant"
! same_bytes "$original" "$mutant" || fail "the round-trip comparison cannot see
  a byte removed from the middle"
echo "  ok: the round-trip comparison fails on a single byte, tail included"

# --- 6c. a NUL refuses out loud, and --text is the way through ---------------
#
# Printing it intact looks like the honest option and is the #159 mechanism: a
# NUL anywhere makes the WHOLE stream binary to `grep`, so the pipeline the
# skill documents -- `evidence.sh pr <n> 2>/dev/null | grep -n '\.claude'` --
# reports the pattern absent for a diff that contains it. Measured on this host
# against a fixture holding both the pattern and a NUL: GNU grep 3.12 prints
# nothing to stdout, puts "binary file matches" on the stderr that idiom throws
# away, and exits 0; the ugrep wrapper the agents' Bash tool puts on PATH
# prints nothing and exits 1 from `-n`, `-c` and `-q` alike, with no message
# even when stderr is kept. Both read as "the mechanism is not there".
#
# So the read refuses, and says why. `--text` is for a caller who has understood
# that and wants the bytes anyway -- and on that path the buffer must still be
# byte-exact, which is what pins the fidelity the shell variable could not give.

cp "$shim_state/diff-nul" "$shim_state/diff"
run_diff
[[ "$status" != "0" ]] || fail "a diff carrying a NUL was served as if it were
  ordinary text. Piped to grep it reads as 'the mechanism is absent' -- with a
  clean exit under GNU grep and a 1 under the wrapper the agents run -- which is
  the #159 refutation, made by the one command written to prevent it."
[[ ! -s "$diff_out" ]] || fail "the NUL diff was refused and printed anyway:
$(cmp "$diff_out" "$shim_state/diff-nul" 2>&1 || true)"
grep -q "NUL byte" "$work_dir/diff.err" || {
  fail "the refusal does not say a NUL is why: $(cat "$work_dir/diff.err")"
}
grep -q -- "--text" "$work_dir/diff.err" || {
  fail "the refusal does not name the way through: $(cat "$work_dir/diff.err")"
}
echo "  ok: a diff carrying a NUL prints nothing and says why"

# And with --text, the same bytes come back exactly. `pr 166 --text` must still
# parse as the diff form: a third argument is a path, and `--text` is not one.
run_diff --text
[[ "$status" == "0" ]] || {
  cat "$work_dir/diff.err" >&2
  fail "--text did not get the diff through"
}
same_bytes "$diff_out" "$shim_state/diff-nul" || {
  fail "--text did not round-trip the NUL diff byte for byte:
$(cmp "$diff_out" "$shim_state/diff-nul" 2>&1 || true)
  wanted $(wc -c < "$shim_state/diff-nul") bytes, got $(wc -c < "$diff_out")"
}
grep -q "grep -a" "$work_dir/diff.err" || {
  fail "--text does not warn that plain grep will still miss: $(cat "$work_dir/diff.err")"
}
echo "  ok: --text round-trips the NUL diff byte for byte, and warns"

# The file path makes the same promise. `git show` used to stream straight to
# stdout, so this hazard was never the diff form's alone: a blob whose bytes
# carry a NUL hands the same binary stream to the same grep.
nul_blob="$work_dir/nul-blob"
{
  head -c 8200 /dev/zero | tr '\0' x
  printf '\npast the sniff window:'
  printf '\0'
  printf 'and text again\n'
} > "$nul_blob"
cp "$nul_blob" "$seed/carries-a-nul.txt"
git_q -C "$seed" add carries-a-nul.txt
git_q -C "$seed" commit -q -m "A file that is text for 8KB and then is not"
git_q -C "$seed" push -q origin main

file_out="$work_dir/file.out"
status=0
REPO="$tick" "$evidence" main carries-a-nul.txt \
  >"$file_out" 2>"$work_dir/file.err" || status=$?
[[ "$status" != "0" ]] || fail "a file carrying a NUL was served as ordinary text"
[[ ! -s "$file_out" ]] || fail "the NUL file was refused and printed anyway"
grep -q "NUL byte" "$work_dir/file.err" || {
  fail "the file refusal does not say a NUL is why: $(cat "$work_dir/file.err")"
}

status=0
REPO="$tick" "$evidence" main carries-a-nul.txt --text \
  >"$file_out" 2>"$work_dir/file.err" || status=$?
[[ "$status" == "0" ]] || {
  cat "$work_dir/file.err" >&2
  fail "--text did not get the file through"
}
same_bytes "$file_out" "$nul_blob" || {
  fail "--text did not round-trip the NUL file byte for byte:
$(cmp "$file_out" "$nul_blob" 2>&1 || true)"
}
echo "  ok: the file path refuses a NUL too, and --text round-trips it"

# Back to the ordinary fixture for the failure paths below.
cat > "$shim_state/diff" <<'DIFF'
diff --git a/deploy.sh b/deploy.sh
--- a/deploy.sh
+++ b/deploy.sh
@@ -1,2 +1,2 @@
-rsync --archive --delete "$source/" "$target/"
+rsync --archive --delete --exclude='.claude/' "$source/" "$target/"
\ No newline at end of file
DIFF

# A head that moves between the two reads. The bytes exist -- the stub served
# them -- and must not reach stdout, because they belong to neither SHA.
printf 'aaaaaaa1\nbbbbbbb2\n' > "$shim_state/heads"
run_diff
[[ "$status" != "0" ]] || fail "evidence.sh pr <n> succeeded after the head moved"
[[ ! -s "$diff_out" ]] || {
  fail "the head moved and a diff was printed anyway. This is the whole defect:
  a well-formed patch attributable to neither SHA, with the refusal on stderr
  where a pipeline never sees it.
$(cat "$diff_out")"
}
grep -q "pushed to while this ran" "$work_dir/diff.err" || {
  fail "the failure does not name the moving head: $(cat "$work_dir/diff.err")"
}
echo "  ok: a head that moves mid-read yields no diff, only the refusal"

# And a diff that cannot be read at all is the same shape: nothing on stdout.
printf 'aaaaaaa1\naaaaaaa1\n' > "$shim_state/heads"
: > "$shim_state/diff-fails"
run_diff
rm -f "$shim_state/diff-fails"
[[ "$status" != "0" ]] || fail "a failed 'gh pr diff' was reported as success"
[[ ! -s "$diff_out" ]] || fail "a failed 'gh pr diff' still printed something:
$(cat "$diff_out")"
echo "  ok: a diff that cannot be read prints nothing either"

# The buffer holding those bytes has no name by the time they are written, so
# nothing accumulates in the scratch root either -- including on the two paths
# just exercised, which leave through `die` rather than the end of the function.
buffer_leak="$(find "$BOARD_HOME" -name 'evidence-buffer.*' 2>/dev/null || true)"
[[ -z "$buffer_leak" ]] || fail "a diff buffer was left behind in the scratch root:
$buffer_leak
  It is meant to be unlinked the instant it is opened, so that a killed read
  leaves the kernel to free it and nothing has to reap a name."
echo "  ok: no diff buffer left behind in the scratch root"

# --- 7. a killed read leaves no ref behind -----------------------------------
#
# The leak window is between the fetch that creates `refs/foreman/fixture/evidence/<pid>`
# and the `update-ref -d` that removes it -- and the fetch is the slow part, so
# `claude stop` on a stalled tick and a tick's own budget expiring both land
# here. Nothing reaps that namespace: `sweep.sh` handles worktrees and board
# branches, `dispatch.sh` prunes worktrees, and `git fetch --prune` does not
# touch `refs/foreman/`. A leaked ref is permanent and pins everything its fetch
# brought with it, `git gc --prune=now` included.
#
# Widened here by a `git` stub that stalls on the `rev-parse` of that ref, which
# is the first thing to run inside the window.

real_git="$(command -v git)"
cat > "$shim_dir/git" <<SHIM
#!/usr/bin/env bash
# Stall inside evidence.sh's leak window, and only there.
for arg in "\$@"; do
  case "\$arg" in
    refs/foreman/fixture/evidence/*)
      case " \$* " in *" rev-parse "*) sleep 3 ;; esac
      ;;
  esac
done
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

REPO="$tick" PATH="$shim_dir:$PATH" "$evidence" main deploy.sh >/dev/null 2>&1 &
victim=$!
# The ref exists the moment the fetch returns, which is before the stall.
for _ in $(seq 1 100); do
  git -C "$tick" show-ref --verify --quiet "refs/foreman/fixture/evidence/$victim" && break
  sleep 0.1
done
git -C "$tick" show-ref --verify --quiet "refs/foreman/fixture/evidence/$victim" || {
  fail "the private ref never appeared, so this case proves nothing about the
  window it is supposed to widen"
}
kill -TERM "$victim"
wait "$victim" || true
rm -f "$shim_dir/git"

leaked="$(git -C "$tick" for-each-ref --format='%(refname)' 'refs/foreman/fixture/evidence/*')"
[[ -z "$leaked" ]] || fail "a killed read left its private ref behind:
$leaked
  SIGKILL cannot be trapped and the sweep reaps that case, but a TERM -- which
  is what stopping an agent sends -- must clean up after itself."
echo "  ok: a read killed inside its leak window deletes its own ref"

echo "PASS: evidence.sh reads are fetched, attributed, and never stale"
