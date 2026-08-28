#!/usr/bin/env bash
# `sweep.sh`'s worktree/scratch guards and globs (config.sh's `worktree_path`
# joins INSTANCE and the ticket with a HYPHEN: foreman-<instance>-<ticket>) are
# the last line of defence against reaping across instances, and reconcile.py's
# review-scoped test never runs them: nothing before this file exercised
# sweep.sh's own guard-and-glob lines directly, so a reversion to the old
# `board-*` shape passed the suite green.
#
# Every case here either proves a single instance's own reap still works, or
# -- the case that actually matters -- puts TWO instances on the SAME target
# repo (a coherent setup: two boards building one monorepo) and shows one
# instance's `--orphans` sweep leaves the other's worktree alone.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"
sweep="$board_dir/sweep.sh"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# --- fixture: one target repo, shared by two instances -----------------------
#
# Sharing REPO between "alpha" and "beta" is deliberate: it is exactly the
# setup the reviewer's collision needs (two instances legitimately pointed at
# the same checkout), and it is where a wrong guard/glob would actually reap
# the wrong instance's worktree.
fixture="$work_dir/target"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
fixture_board_toml "$fixture"

# `agent_tmp_for` still asks the TARGET's own `$REPO/ops/tmp-dir.sh` (config.sh
# leaves that alone -- see task-5-decisions.md section 6), so the fixture needs
# one. Mirrors `bin/tmp-dir.sh`'s own derivation exactly, so AGENT_TMP_ROOT
# (computed by config.sh from THIS installation's bin/tmp-dir.sh) and what this
# prints agree.
mkdir -p "$fixture/ops"
cat > "$fixture/ops/tmp-dir.sh" <<'TMPDIR'
#!/usr/bin/env bash
set -euo pipefail
root="${FOREMAN_TMP_ROOT:-${BOARD_HOME:-$HOME/.foreman}/tmp}"
case "${1:-}" in
  --root) printf '%s\n' "$root" ;;
  "") printf '%s/%s\n' "$root" "$(basename -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)")" ;;
  *) printf '%s/%s\n' "$root" "$(basename -- "$1")" ;;
esac
TMPDIR
chmod +x "$fixture/ops/tmp-dir.sh"

home="$work_dir/home"
fixture_add_instance "$home" alpha "$fixture"
fixture_add_instance "$home" beta "$fixture"

# BOARD_HOME defaults to INSTANCE_HOME when not overridden -- computed here so
# fixtures can be planted at the scratch path sweep.sh will actually look for.
board_home_alpha="$home/.foreman/instances/alpha"
board_home_beta="$home/.foreman/instances/beta"
tmp_root_alpha="$board_home_alpha/tmp"

# `--orphans` reads the live agent list before touching anything. Every dir
# planted below is meant to read as an orphan, so nothing is ever "live".
stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
STUB
chmod +x "$stub_dir/claude"

run_sweep() { # instance sweep-args...
  local inst="$1"; shift
  HOME="$home" FOREMAN_INSTANCE="$inst" PATH="$stub_dir:$PATH" "$sweep" "$@"
}

worktree_dir() { printf '%s/.claude/worktrees/foreman-%s-%s\n' "$fixture" "$1" "$2"; }
scratch_dir()  { printf '%s/foreman-%s-%s\n' "$tmp_root_alpha" "$1" "$2"; }

# --- A. sweep.sh <ticket> removes the worktree AND its paired scratch dir ----
# (sweep.sh:52's guard and :36's guard, both on the normal removal path)

wt_a="$(worktree_dir alpha PRA-1)"; mkdir -p "$wt_a"
sc_a="$(scratch_dir alpha PRA-1)"; mkdir -p "$sc_a"

if run_sweep alpha PRA-1 >/tmp/sweep-a.out 2>&1; then
  if [[ ! -d "$wt_a" && ! -d "$sc_a" ]]; then
    ok "sweep.sh PRA-1 removes the worktree and its paired scratch dir"
  else
    bad "sweep.sh PRA-1 left something behind: worktree=$([[ -d "$wt_a" ]] && echo present || echo gone) scratch=$([[ -d "$sc_a" ]] && echo present || echo gone)"
  fi
else
  bad "sweep.sh PRA-1 exited non-zero: $(cat /tmp/sweep-a.out)"
fi

# --- B. --orphans removes an orphaned worktree for its own instance ---------
# (sweep.sh:159's loop glob)

wt_b="$(worktree_dir alpha PRA-9)"; mkdir -p "$wt_b"
if run_sweep alpha --orphans >/tmp/sweep-b.out 2>&1; then
  if [[ ! -d "$wt_b" ]]; then
    ok "--orphans reaps an orphaned worktree for its own instance"
  else
    bad "--orphans left an orphaned worktree behind: $wt_b"
  fi
else
  bad "--orphans exited non-zero: $(cat /tmp/sweep-b.out)"
fi

# --- C. the reviewer's case: --orphans on a SHARED repo leaves the other ----
# --- instance's worktree alone, and that instance can still sweep its own ---

wt_c_alpha="$(worktree_dir alpha PRA-2)"; mkdir -p "$wt_c_alpha"
wt_c_beta="$(worktree_dir beta PRA-2)"; mkdir -p "$wt_c_beta"

if run_sweep alpha --orphans >/tmp/sweep-c1.out 2>&1; then
  if [[ ! -d "$wt_c_alpha" && -d "$wt_c_beta" ]]; then
    ok "alpha's --orphans reaps its own worktree and leaves beta's untouched, on the SAME repo"
  else
    bad "cross-instance isolation broke: alpha's worktree $([[ -d "$wt_c_alpha" ]] && echo survived || echo gone), beta's worktree $([[ -d "$wt_c_beta" ]] && echo survived || echo gone)"
  fi
else
  bad "alpha's --orphans exited non-zero: $(cat /tmp/sweep-c1.out)"
fi

if run_sweep beta --orphans >/tmp/sweep-c2.out 2>&1; then
  if [[ ! -d "$wt_c_beta" ]]; then
    ok "beta can still sweep its own worktree afterward"
  else
    bad "beta's --orphans left its own worktree behind: $wt_c_beta"
  fi
else
  bad "beta's --orphans exited non-zero: $(cat /tmp/sweep-c2.out)"
fi

# --- D. --orphans reaps a scratch dir whose worktree is already gone --------
# (sweep.sh:169's loop glob)

sc_d="$(scratch_dir alpha PRA-3)"; mkdir -p "$sc_d"
if run_sweep alpha --orphans >/tmp/sweep-d.out 2>&1; then
  if [[ ! -d "$sc_d" ]]; then
    ok "--orphans reaps a scratch dir whose worktree is already gone"
  else
    bad "--orphans left an orphaned scratch dir behind: $sc_d"
  fi
else
  bad "--orphans exited non-zero: $(cat /tmp/sweep-d.out)"
fi

# --- E. sweep.sh <ticket> also removes extra review-slot worktrees ----------
# (sweep.sh:181's glob)

wt_e_primary="$(worktree_dir alpha PRA-4)"; mkdir -p "$wt_e_primary"
wt_e_review="$fixture/.claude/worktrees/foreman-alpha-PRA-4-review-1a"; mkdir -p "$wt_e_review"
if run_sweep alpha PRA-4 >/tmp/sweep-e.out 2>&1; then
  if [[ ! -d "$wt_e_primary" && ! -d "$wt_e_review" ]]; then
    ok "sweep.sh PRA-4 removes the primary worktree and its review-slot worktree"
  else
    bad "sweep.sh PRA-4 left something behind: primary=$([[ -d "$wt_e_primary" ]] && echo present || echo gone) review=$([[ -d "$wt_e_review" ]] && echo present || echo gone)"
  fi
else
  bad "sweep.sh PRA-4 exited non-zero: $(cat /tmp/sweep-e.out)"
fi

rm -f /tmp/sweep-a.out /tmp/sweep-b.out /tmp/sweep-c1.out /tmp/sweep-c2.out /tmp/sweep-d.out /tmp/sweep-e.out

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: sweep.sh's worktree/scratch guards and globs are instance-scoped"
else
  echo "FAILED"
fi
exit "$fail"
