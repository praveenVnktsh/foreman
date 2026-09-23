#!/usr/bin/env bash
# Before docs/specs/2026-09-14-installations-per-harness-design.md was unwound,
# a worktree was named `foreman-<installation>-<board>-<ticket>`.
# BOARD_WORKTREE_PREFIX is now `foreman-<board>` (config.sh), so `--orphans`'
# glob cannot match a legacy tree and sweep.sh's path refusal rejects any path
# outside it. Measured 2026-09-22: five such trees, 22G, on a disk that was
# already full, reapable by nothing on the machine.
#
# sweep.sh's `legacy_agent_dir` now recognises the legacy shape under three
# guards, on top of the liveness read every candidate already passes through:
#   ONE  -- an installation segment with no hyphen in it, so a `*` cannot span
#           a board name it does not own;
#   TWO  -- never a path that belongs to a DECLARED board, current-shape,
#           however it parses under the legacy pattern -- the hole the design
#           spec named: "a legacy board named like a scoped sibling
#           installation";
#   THREE (not in the function; it is LIVE_FILE) -- never a non-finished
#           agent's cwd, from anywhere on the machine, whatever its name.
# This file exercises all three, plus the two places the design deliberately
# leaves narrower than `--orphans`: ticket mode grows no legacy glob, and
# `remove_tree` only ever deletes a branch under this board's own prefix, so a
# legacy branch that may still back an open pull request survives.
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

# --- fixture -----------------------------------------------------------------
#
# Board <b> is "codex". Its sibling "opencode" is declared for GUARD TWO: a
# board name is letters, digits and underscore only (config.sh's INSTANCE
# rule), so it can never itself carry the hyphen that would make it look like
# a legacy tree's board segment. What it CAN be is the INSTALLATION segment of
# one -- "foreman-opencode-codex-<ticket>" parses both as codex's own legacy
# tree (installation "opencode", board "codex") and, by simple prefix, as
# opencode's own current-shape tree with an odd ticket. That is the ambiguity
# the design spec names: "a legacy board named like a scoped sibling
# installation".
fixture="$work_dir/target"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
# Test 5 checks out a real branch onto a real worktree, which needs a commit
# to branch from.
git -C "$fixture" commit -q --allow-empty -m "fixture root"
fixture_board_toml "$fixture"

home="$work_dir/home"
fixture_add_board "$home" codex "$fixture"
fixture_add_board "$home" opencode "$fixture"

board_home="$home/.foreman/instances/codex"
tmp_root="$board_home/tmp"

# One stub `claude`, reading whatever this test currently wants `claude agents
# --json --all` to answer. A file rather than a fixed body: cases 2 and 3 need
# a live agent in the registry, and the others need none.
registry_file="$work_dir/registry.json"
printf '[]\n' >"$registry_file"
stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/claude" <<STUB
#!/usr/bin/env bash
cat "$registry_file"
STUB
chmod +x "$stub_dir/claude"

# FOREMAN_HOME is named explicitly, for the reason every other sweep test
# names it: config.sh asks bin/installation.py, which reads the home as the
# parent of this clone, and an explicit home is what that derivation yields to.
run_sweep() { # <sweep-args...>
  HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=codex \
    PATH="$stub_dir:$PATH" "$sweep" "$@"
}

# legacy_wt <installation> <board> <ticket> -- the pre-single-foreman shape.
legacy_wt() { printf '%s/.claude/worktrees/foreman-%s-%s-%s\n' "$fixture" "$1" "$2" "$3"; }

# reset_registry -- no live agent, so every candidate this test plants reads
# as an orphan by liveness alone; only the naming guards are then in play.
reset_registry() { printf '[]\n' >"$registry_file"; }

# --- 1. a legacy tree with no live agent is reaped, scratch dir with it -----

wt1="$(legacy_wt grok codex PRA-501)"
sc1="$tmp_root/$(basename "$wt1")"
mkdir -p "$wt1" "$sc1"
reset_registry
if out1="$(run_sweep --orphans 2>&1)"; then
  if [[ ! -d "$wt1" && ! -d "$sc1" ]]; then
    ok "--orphans reaps a legacy tree with no live agent, and its scratch dir with it"
  else
    bad "legacy tree survived: worktree=$([[ -d "$wt1" ]] && echo present || echo gone) scratch=$([[ -d "$sc1" ]] && echo present || echo gone)"
  fi
else
  bad "--orphans exited non-zero on case 1: $out1"
fi
rm -rf "$wt1" "$sc1"

# --- 2. a legacy tree that IS a live agent's cwd is left alone -------------
#
# The agent's name belongs to no board this fixture declares -- LIVE_FILE
# protects a cwd by liveness alone, never by matching the agent's name to a
# board, so this is already covered by the same read that protects a
# current-shape tree.

wt2="$(legacy_wt grok codex PRA-502)"
mkdir -p "$wt2"
cat >"$registry_file" <<JSON
[{"name": "some-other-tool/PRA-502/build-1", "state": "working", "cwd": "$wt2"}]
JSON
if out2="$(run_sweep --orphans 2>&1)"; then
  if [[ -d "$wt2" ]]; then
    ok "--orphans leaves a legacy tree alone while an unrecognised-name agent still works in it"
  else
    bad "--orphans removed a legacy tree under a live (if unrecognised) agent: $wt2"
  fi
else
  bad "--orphans exited non-zero on case 2: $out2"
fi
rm -rf "$wt2"

# --- 3. a path that also reads as a DECLARED sibling's own tree is left ----
# --- alone, even though it also passes GUARD ONE as codex's own legacy tree -
#
# `foreman-opencode-codex-PRA-503` is a perfectly valid legacy tree for codex
# (installation "opencode", board "codex", GUARD ONE passes) -- and, read the
# other way, it is ALSO exactly `foreman-opencode-*`: opencode's own
# current-shape worktree, for a ticket that happens to be "codex-PRA-503".
# Nothing in the name settles which reading is right, and codex's sweep must
# not guess: it leaves it for the board it might belong to.
wt3="$(legacy_wt opencode codex PRA-503)"
mkdir -p "$wt3"
reset_registry
if out3="$(run_sweep --orphans 2>&1)"; then
  if [[ -d "$wt3" ]]; then
    ok "codex's --orphans leaves alone a path that also reads as declared board opencode's own tree"
  else
    bad "codex's --orphans reaped a path belonging to a declared sibling board: $wt3"
  fi
else
  bad "--orphans exited non-zero on case 3: $out3"
fi
rm -rf "$wt3"

# --- 4. an installation segment with a hyphen is left alone -----------------
#
# GUARD ONE: the installation segment must be one hyphen-free token, so a `*`
# cannot span a board name it does not own. INSTANCE itself can never contain a
# hyphen (config.sh refuses that), so this is the only way a candidate can
# carry one, and it must not silently match anyway.
wt4="$(legacy_wt a-b codex PRA-504)"
mkdir -p "$wt4"
reset_registry
if out4="$(run_sweep --orphans 2>&1)"; then
  if [[ -d "$wt4" ]]; then
    ok "--orphans leaves a legacy tree alone when its installation segment contains a hyphen"
  else
    bad "--orphans reaped a tree whose installation segment had a hyphen: $wt4"
  fi
else
  bad "--orphans exited non-zero on case 4: $out4"
fi
rm -rf "$wt4"

# --- 5. the legacy tree goes; its branch does not --------------------------
#
# remove_tree deletes a local branch only under $BOARD_NAME_PREFIX
# (foreman/codex/*). A legacy branch is foreman/<installation>/<board>/*,
# outside that prefix, and may still back an open pull request -- the reason
# it was kept when the installation segment was introduced. A bare `mkdir -p`
# worktree (as in cases 1-4) has no real HEAD for `git rev-parse` to name, so
# this case needs a REAL worktree on a REAL branch to exercise the guard at
# all.
wt5="$(legacy_wt grok codex PRA-505)"
branch5="foreman/grok/codex/PRA-505"
git -C "$fixture" worktree add -q -b "$branch5" "$wt5" main
reset_registry
if out5="$(run_sweep --orphans 2>&1)"; then
  branch_survives5=0
  git -C "$fixture" show-ref --verify --quiet "refs/heads/$branch5" && branch_survives5=1
  if [[ ! -d "$wt5" && "$branch_survives5" -eq 1 ]]; then
    ok "--orphans removes a legacy worktree but keeps its branch, which may still back a pull request"
  else
    bad "case 5: worktree=$([[ -d "$wt5" ]] && echo present || echo gone) branch=$([[ "$branch_survives5" -eq 1 ]] && echo present || echo gone)"
  fi
else
  bad "--orphans exited non-zero on case 5: $out5"
fi
git -C "$fixture" branch -D "$branch5" 2>/dev/null || true

# --- 6. ticket mode grows no legacy glob: a legacy tree belongs to no card --
# --- this board dispatches, so sweeping a ticket leaves it alone -----------

wt6="$(legacy_wt grok codex PRA-506)"
mkdir -p "$wt6"
reset_registry
if out6="$(run_sweep PRA-506 2>&1)"; then
  if [[ -d "$wt6" ]]; then
    ok "ticket-mode sweep leaves a legacy tree alone; it belongs to no card this board dispatches"
  else
    bad "ticket-mode sweep of PRA-506 reaped an unrelated legacy tree: $wt6"
  fi
else
  bad "sweep.sh PRA-506 exited non-zero: $out6"
fi
rm -rf "$wt6"

# --- 7. BOARD_DRY_RUN names the legacy tree and removes nothing ------------

wt7="$(legacy_wt grok codex PRA-507)"
mkdir -p "$wt7"
reset_registry
if out7="$(HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=codex \
    PATH="$stub_dir:$PATH" BOARD_DRY_RUN=1 "$sweep" --orphans 2>&1)"; then
  if [[ -d "$wt7" ]] && grep -q "$wt7" <<<"$out7" && grep -qi "DRY RUN" <<<"$out7"; then
    ok "BOARD_DRY_RUN names a legacy tree and removes nothing"
  else
    bad "dry run on a legacy tree: present=$([[ -d "$wt7" ]] && echo yes || echo no) output=$out7"
  fi
else
  bad "dry-run --orphans exited non-zero on case 7: $out7"
fi
rm -rf "$wt7"

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: sweep.sh --orphans reaps the pre-single-foreman worktree shape, under its guards"
else
  echo "FAILED"
fi
exit "$fail"
