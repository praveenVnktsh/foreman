#!/usr/bin/env bash
# Claim: "Names carry the installation" in
# docs/specs/2026-09-14-installations-per-harness-design.md. Two installations
# may serve one repository, so every name that used to start at the board now
# starts at the installation, and a name missing that segment lets one
# installation reap or watch the other's work.
#
# tests/test-sweep-is-instance-scoped.sh and
# tests/test-agent-names-are-instance-scoped.sh already prove this SEPARATION
# for two boards (instances) sharing one repository. This file reuses their
# approach for the level above: two INSTALLATIONS -- alpha and beta, both on
# `claude`, alpha the default -- that both declare a board named `demo` on
# ONE shared repository. Getting the installation segment wrong is invisible
# at the board level: a build that dropped it would still pass both of those
# files, because both only ever build one installation.
#
# Every case here compares alpha's output against beta's, the same discipline
# test-agent-names-are-instance-scoped.sh states in its own header: a test
# that only checks one installation's names passes on a regex that matches
# both.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}
check_ne() { # name a b
  if [[ "$2" != "$3" ]]; then ok "$1"
  else printf 'FAIL %s\n  alpha and beta produced the SAME value: %q\n' "$1" "$2"; fail=1; fi
}

# --- fixture: one shared repository, two installations, one board each -----
#
# `demo`, not `alpha` or `beta`: the point is that the BOARD name is identical
# on both sides, so nothing but the installation segment can be what keeps
# alpha's and beta's names apart.
repo="$work_dir/target"
mkdir -p "$repo"
git -C "$repo" init -q -b main
fixture_board_toml "$repo"

root="$work_dir/root"
fixture_add_installation "$root" alpha claude --default
fixture_add_installation "$root" beta claude

alpha_home="$root/.foreman/alpha"
beta_home="$root/.foreman/beta"
fixture_add_board_in "$alpha_home" demo "$repo"
fixture_add_board_in "$beta_home" demo "$repo"

# --- a stub `claude` for the two verbs this file's checks reach: `agents
# --json --all` (behind the adapter's `list`) and nothing else. `FIXTURE_
# AGENTS_JSON`, when set to a readable file, is what the registry answers with
# -- unset or missing, it answers "[]", which is what "a registry showing
# nothing live" means below.
stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "agents" ]]; then
  if [[ -n "${FIXTURE_AGENTS_JSON:-}" && -f "$FIXTURE_AGENTS_JSON" ]]; then
    cat "$FIXTURE_AGENTS_JSON"
  else
    printf '[]\n'
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/claude"

# =============================================================================
# A. a dispatch from each installation cuts a differently-named worktree
# =============================================================================
#
# dispatch.sh's own full preflight gate reaches the network (a real `git
# fetch origin`, `gh api user`) and a `gh`-backed runner check -- none of
# which this claim is about. So this drives it through a SHIM skill dir,
# exactly the technique tests/lib/dispatch-fixture.sh uses for the same
# reason (see its own header): everything but preflight.py is the real
# script, symlinked in, and preflight.py is a two-line stub that always says
# the machine is fit. `BOARD_DRY_RUN=1` is what makes the point moot anyway --
# it prints the worktree dispatch.sh would cut and exits before spawning
# anything, which is all this claim needs.
shim_root="$work_dir/shim-repo"
mkdir -p "$shim_root/bin" "$shim_root/skills/board"
ln -s "$repo_root/bin/contract.py" "$shim_root/bin/contract.py"
ln -s "$repo_root/bin/boards.py" "$shim_root/bin/boards.py"
ln -s "$repo_root/bin/installation.py" "$shim_root/bin/installation.py"
# config.sh sources its pair reader from THIS root's bin/ on its first line.
ln -s "$repo_root/bin/load-pairs.sh" "$shim_root/bin/load-pairs.sh"
ln -s "$repo_root/bin/tmp-dir.sh" "$shim_root/bin/tmp-dir.sh"
ln -s "$board_dir/config.sh" "$shim_root/skills/board/config.sh"
ln -s "$board_dir/dispatch.sh" "$shim_root/skills/board/dispatch.sh"
ln -s "$board_dir/withlock.py" "$shim_root/skills/board/withlock.py"
# dispatch.sh refuses when it cannot count the machine's slots, so the shim
# needs the counter; a shim without it dies at the gate before the DRY RUN line.
ln -s "$board_dir/reconcile.py" "$shim_root/skills/board/reconcile.py"
ln -s "$board_dir/harness" "$shim_root/skills/board/harness"
cat > "$shim_root/skills/board/preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
chmod +x "$shim_root/skills/board/preflight.py"

prompt_file="$work_dir/prompt.md"
echo "do the thing" > "$prompt_file"

# run_dispatch <foreman_home> <ticket> -- the DRY RUN line, or empty on a
# non-zero exit (dispatch_fixture_run's own "swallow and let the caller's own
# assertion fail" rule).
run_dispatch() {
  local home="$1" ticket="$2"
  env -i HOME="$root" FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo \
    PATH="$stub_dir:$PATH" BOARD_DRY_RUN=1 \
    "$shim_root/skills/board/dispatch.sh" \
    --ticket "$ticket" --role build --attempt 1 --prompt-file "$prompt_file" \
    2>"$work_dir/dispatch.err" || true
}

# dry_run_worktree <dry-run-line> -- the value after `worktree=`, up to the
# next space. `DRY RUN: would spawn NAME (model=M worktree=W ref=R)` is
# dispatch.sh's own format string; this reads it rather than reimplementing
# worktree_path, so a drift between the two shows up as a parse failure, not
# a silently-agreeing duplicate.
dry_run_worktree() {
  local line="$1"
  [[ "$line" =~ worktree=([^[:space:]]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

alpha_dispatch_out="$(run_dispatch "$alpha_home" PRA-1)"
beta_dispatch_out="$(run_dispatch "$beta_home" PRA-1)"

alpha_worktree="$(dry_run_worktree "$alpha_dispatch_out" || true)"
beta_worktree="$(dry_run_worktree "$beta_dispatch_out" || true)"

if [[ -z "$alpha_worktree" ]]; then
  bad "alpha's dispatch never printed a DRY RUN worktree line: $alpha_dispatch_out ($(cat "$work_dir/dispatch.err" 2>/dev/null))"
elif [[ -z "$beta_worktree" ]]; then
  bad "beta's dispatch never printed a DRY RUN worktree line: $beta_dispatch_out"
else
  check "alpha's dispatch would cut foreman-alpha-demo-PRA-1" \
    "$repo/.claude/worktrees/foreman-alpha-demo-PRA-1" "$alpha_worktree"
  check "beta's dispatch would cut foreman-beta-demo-PRA-1" \
    "$repo/.claude/worktrees/foreman-beta-demo-PRA-1" "$beta_worktree"
  check_ne "alpha's and beta's worktrees differ" "$alpha_worktree" "$beta_worktree"
fi

# =============================================================================
# B. the branch name differs by the installation segment too
# =============================================================================
#
# config.sh's `branch_name` is the function `worktree_path` sits beside; a
# regression that carried the installation into one and not the other is
# exactly the kind of drift "one fact, one place" exists to catch, and the
# dry-run line above never exercises it.
ask_branch_name() { # <foreman_home> <ticket>
  env HOME="$root" FOREMAN_HOME="$1" FOREMAN_INSTANCE=demo \
    bash -c ". '$board_dir/config.sh' >/dev/null; branch_name \"\$1\"" _ "$2"
}

alpha_branch="$(ask_branch_name "$alpha_home" PRA-1)"
beta_branch="$(ask_branch_name "$beta_home" PRA-1)"

check "alpha's branch carries the alpha segment" "foreman/alpha/demo/PRA-1" "$alpha_branch"
check "beta's branch carries the beta segment" "foreman/beta/demo/PRA-1" "$beta_branch"
check_ne "alpha's and beta's branches differ" "$alpha_branch" "$beta_branch"

# =============================================================================
# C. alpha's sweep, with beta's worktree present and nothing live, reaps only
#    foreman-alpha-*
# =============================================================================
#
# The stub `claude` above answers "[]" here (FIXTURE_AGENTS_JSON unset) -- "a
# registry showing nothing live", the exact case the task names. Run against
# the REAL skills/board/sweep.sh, not the shim: sweep.sh never reaches
# preflight.py at all, so nothing here needs stubbing beyond the agent
# registry sweep.sh's own `--orphans` already reads through the harness
# adapter's `list`.
alpha_wt="$repo/.claude/worktrees/foreman-alpha-demo-PRA-2"
beta_wt="$repo/.claude/worktrees/foreman-beta-demo-PRA-2"
mkdir -p "$alpha_wt" "$beta_wt"

if HOME="$root" FOREMAN_HOME="$alpha_home" FOREMAN_INSTANCE=demo \
  PATH="$stub_dir:$PATH" "$board_dir/sweep.sh" --orphans \
  >"$work_dir/sweep.out" 2>&1; then
  if [[ ! -d "$alpha_wt" && -d "$beta_wt" ]]; then
    ok "alpha's --orphans reaps foreman-alpha-* and leaves beta's worktree alone"
  else
    bad "alpha's --orphans got the wrong worktree: alpha $([[ -d "$alpha_wt" ]] && echo survived || echo gone), beta $([[ -d "$beta_wt" ]] && echo survived || echo gone)"
  fi
else
  bad "alpha's --orphans exited non-zero: $(cat "$work_dir/sweep.out")"
fi

# =============================================================================
# D. watch-agents.py under alpha never reports beta's finishing agent
# =============================================================================
#
# Driven against the REAL skills/board/watch-agents.py source, the way
# test-agent-names-are-instance-scoped.sh drives it -- up to and including
# `poll()`, which this claim actually needs (that file only needed
# `_dispatched`). `main()`'s `while True` loop is excluded from the exec by
# the same split, so this never blocks.
agents_json="$work_dir/agents.json"
cat > "$agents_json" <<'JSON'
[
  {"name": "foreman/alpha/demo/PRA-9/build-1", "id": "a1", "sessionId": "s1",
   "pid": 1, "state": "done", "startedAt": 1, "cwd": "/tmp/a", "status": "done"},
  {"name": "foreman/beta/demo/PRA-9/build-1", "id": "b1", "sessionId": "s2",
   "pid": 2, "state": "done", "startedAt": 1, "cwd": "/tmp/b", "status": "done"}
]
JSON

watch_src="$board_dir/watch-agents.py"
poll_as_alpha="$(env HOME="$root" FOREMAN_HOME="$alpha_home" FOREMAN_INSTANCE=demo \
  PATH="$stub_dir:$PATH" FIXTURE_AGENTS_JSON="$agents_json" python3 - "$watch_src" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
ns = {"__file__": path}
exec(src.split("\ndef main")[0], ns)
result = ns["poll"]()
print("|".join(sorted(result.keys())))
PY
)"

case "$poll_as_alpha" in
  *"foreman/beta/"*)
    bad "watch-agents.py under alpha reported beta's agent: $poll_as_alpha"
    ;;
  "foreman/alpha/demo/PRA-9/build-1")
    ok "watch-agents.py under alpha reports only its own installation's finished agent"
    ;;
  *)
    bad "watch-agents.py under alpha reported an unexpected set: $poll_as_alpha"
    ;;
esac

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: names carry the installation, and a dispatch, a sweep and a watch on two installations sharing one repository never touch each other's worktrees or agents"
else
  echo "FAILED"
fi
exit "$fail"
