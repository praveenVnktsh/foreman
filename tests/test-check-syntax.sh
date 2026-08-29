#!/usr/bin/env bash
# The syntax check has to fail, and it has to fail for the right file.
#
# Four versions of this check passed while covering less than they claimed: a
# hand-listed file set, a glob that would have passed matching nothing,
# `-exec bash -n {} +` (which parses only the first file of each batch), and a
# `find src scripts .claude` root list that omitted the repository-root scripts
# and every extensionless one. So most of what follows asserts *coverage*
# rather than syntax -- the cases that were green in CI were never "a syntax
# error slipped through", they were "that file was never read".
#
# Run against throwaway git repositories. The checker takes its file set from
# `git ls-files`, so each fixture is a real `git init` + `git add`; that is also
# what pins down the two properties worth having: a file is covered by being
# committed, and an untracked file is not read at all.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/bin/check-syntax.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ -f "$work_dir/out.log" ]] && cat "$work_dir/out.log" >&2
  exit 1
}

# A fixture repo per case, so one case cannot leave state in another.
new_repo() {
  local dir="$work_dir/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo "$dir"
}

track() { git -C "$1" add -A; }

run_checker() {
  ( cd "$1" && "$checker" ) > "$work_dir/out.log" 2>&1
}

good_shell()  { printf '#!/usr/bin/env bash\nset -euo pipefail\necho ok\n' > "$1"; }
bad_shell()   { printf '#!/usr/bin/env bash\nif then; fi(((\n' > "$1"; }
good_python() { printf 'VALUE = 1\n' > "$1"; }
bad_python()  { printf 'def broken(:\n    pass\n' > "$1"; }

echo "==> a tree where everything parses"
repo="$(new_repo clean)"
mkdir -p "$repo/nested"
good_shell "$repo/a.sh"
good_shell "$repo/nested/b.sh"
good_python "$repo/c.py"
good_python "$repo/nested/d.py"
track "$repo"
run_checker "$repo" || fail "a clean tree was rejected"
grep -q 'PASS: 4 ' "$work_dir/out.log" || fail "wrong file count for a clean tree"
echo "  ok: passes, and reports the number of files it read"

echo "==> a broken shell script that does not sort first"
repo="$(new_repo shell_late)"
good_shell "$repo/aaa-good.sh"
good_shell "$repo/mmm-good.sh"
bad_shell "$repo/zzz-broken.sh"
track "$repo"
if run_checker "$repo"; then
  fail "a syntax error in a shell script passed the check"
fi
grep -q 'zzz-broken.sh does not parse' "$work_dir/out.log" ||
  fail "the failure did not name the broken shell script"
echo "  ok: caught, and named"

echo "==> a broken file first does not mask the ones after it"
repo="$(new_repo both_broken)"
bad_shell "$repo/aaa-broken.sh"
bad_shell "$repo/zzz-broken.sh"
bad_python "$repo/mmm-broken.py"
track "$repo"
if run_checker "$repo"; then
  fail "three broken files passed the check"
fi
for expected in aaa-broken.sh mmm-broken.py zzz-broken.sh; do
  grep -q "$expected does not parse" "$work_dir/out.log" ||
    fail "the check stopped early and never reported $expected"
done
echo "  ok: every broken file is reported, not just the first"

echo "==> a broken Python module"
repo="$(new_repo python_late)"
good_python "$repo/aaa-good.py"
bad_python "$repo/zzz-broken.py"
track "$repo"
if run_checker "$repo"; then
  fail "a syntax error in a Python module passed the check"
fi
grep -q 'zzz-broken.py does not parse' "$work_dir/out.log" ||
  fail "the failure did not name the broken Python module"
echo "  ok: caught, and named"

echo "==> py_compile leaves no build output in the tree it checked"
[[ -z "$(find "$work_dir" -name '__pycache__' -o -name '*.pyc')" ]] ||
  fail "py_compile wrote bytecode into a checked tree"
echo "  ok: no __pycache__, no .pyc"

# The two findings that blocked this change, as regression tests. Both were
# "the file was never read", and both were invisible to a per-root file count.
echo "==> a script at the repository root, where no find root reached"
repo="$(new_repo repo_root_script)"
good_shell "$repo/keeps-the-count-up.sh"
mkdir -p "$repo/deploy"
good_shell "$repo/deploy/release.sh"
bad_shell "$repo/setup.sh"
track "$repo"
if run_checker "$repo"; then
  fail "a broken setup.sh at the repository root passed the check"
fi
grep -q 'setup.sh does not parse' "$work_dir/out.log" ||
  fail "the root-level script was not read"
echo "  ok: read -- every deploy runs setup.sh after rsync has replaced the tree"

echo "==> an extensionless executable script, which no extension matcher saw"
repo="$(new_repo extensionless)"
mkdir -p "$repo/deploy/git-hooks"
good_shell "$repo/deploy/release.sh"
bad_shell "$repo/deploy/git-hooks/pre-commit"
chmod +x "$repo/deploy/git-hooks/pre-commit"
track "$repo"
if run_checker "$repo"; then
  fail "a broken extensionless hook passed the check"
fi
grep -q 'pre-commit does not parse' "$work_dir/out.log" ||
  fail "the extensionless hook was not read"
echo "  ok: classified by shebang, not by suffix"

echo "==> an extensionless executable Python script"
repo="$(new_repo extensionless_python)"
printf '#!/usr/bin/env python3\ndef broken(:\n' > "$repo/tool"
chmod +x "$repo/tool"
good_shell "$repo/keeps-the-count-up.sh"
track "$repo"
if run_checker "$repo"; then
  fail "a broken extensionless Python script passed the check"
fi
grep -q 'tool does not parse' "$work_dir/out.log" ||
  fail "the extensionless Python script was not read"
echo "  ok: python shebangs too"

echo "==> a non-executable extensionless file is not sniffed"
repo="$(new_repo not_executable)"
good_shell "$repo/real.sh"
printf 'Subject: notes\n\nif then; fi(((\n' > "$repo/NOTES"
track "$repo"
run_checker "$repo" || fail "prose was parsed as a shell script"
grep -q 'PASS: 1 ' "$work_dir/out.log" || fail "something other than real.sh was read"
echo "  ok: nothing can run it, so nothing parses it"

echo "==> a tracked executable with an unrecognized shebang fails loudly"
repo="$(new_repo unknown_shebang)"
good_shell "$repo/real.sh"
printf '#!/usr/bin/env node\nconsole.log(1)\n' > "$repo/runner"
chmod +x "$repo/runner"
track "$repo"
if run_checker "$repo"; then
  fail "an executable this check cannot parse was skipped in silence"
fi
grep -q 'cannot classify' "$work_dir/out.log" ||
  fail "the unclassified executable was not reported"
echo "  ok: silent non-coverage is the thing being engineered out"

echo "==> untracked files are not read"
# `.claude/worktrees/<name>/` is a live checkout per dispatched board agent and
# is gitignored, so this is also what keeps other agents' half-written code out.
repo="$(new_repo untracked)"
mkdir -p "$repo/.claude/skills/board" "$repo/.claude/worktrees/other-agent"
# Named for what they are rather than after real board scripts, which is not
# fussiness: a target's own design-invariant tests can name a specific source
# file (e.g. `reconcile.py`) and check that name against every non-comment
# occurrence in the tree. While these fixtures wore those names, such an
# invariant resolved against this test rather than against the board -- and
# renaming the real file would have gone unnoticed. What is under test here is
# the path, not the filename.
good_shell "$repo/.claude/skills/board/fixture.sh"
good_python "$repo/.claude/skills/board/fixture.py"
printf '.claude/worktrees/\n' > "$repo/.gitignore"
track "$repo"
bad_shell "$repo/.claude/worktrees/other-agent/mid-edit.sh"
bad_python "$repo/.claude/worktrees/other-agent/mid-edit.py"
bad_shell "$repo/never-added.sh"
run_checker "$repo" || fail "the checker read untracked files"
grep -q 'PASS: 2 ' "$work_dir/out.log" || fail "untracked files were counted"
echo "  ok: covered by being committed, and only by being committed"

echo "==> a broken file under .claude is caught"
repo="$(new_repo claude_dir)"
mkdir -p "$repo/.claude/skills/board"
good_shell "$repo/.claude/skills/board/fixture.sh"
bad_python "$repo/.claude/skills/board/fixture.py"
track "$repo"
if run_checker "$repo"; then
  fail "a syntax error under .claude passed the check"
fi
grep -q 'fixture.py does not parse' "$work_dir/out.log" ||
  fail "the failure did not name the broken board module"
echo "  ok: the code that gates every merge is gated itself"

echo "==> a tracked file deleted from the working tree"
repo="$(new_repo deleted)"
good_shell "$repo/a.sh"
good_shell "$repo/b.sh"
track "$repo"
rm "$repo/b.sh"
if run_checker "$repo"; then
  fail "a tree that does not match its index was reported as passing"
fi
grep -q 'missing from the working tree' "$work_dir/out.log" ||
  fail "the missing file failed unclearly"
echo "  ok: not silently skipped"

echo "==> a repository with nothing to check"
repo="$(new_repo empty)"
mkdir -p "$repo/docs"
printf '# just prose\n' > "$repo/docs/README.md"
track "$repo"
if run_checker "$repo"; then
  fail "a repository holding nothing to check was reported as passing"
fi
grep -q 'no tracked shell or Python sources' "$work_dir/out.log" ||
  fail "an empty repository failed for the wrong reason"
echo "  ok: zero coverage is a failure, not a pass"

echo "PASS: syntax errors fail the build, and zero coverage is not a pass"
