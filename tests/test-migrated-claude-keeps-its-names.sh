#!/usr/bin/env bash
# Claim: "The legacy installation keeps the old names" in
# docs/specs/2026-09-14-installations-per-harness-design.md.
#
# A Claude home installed before installations existed has open pull requests
# on branches foreman/<board>/<ticket>. skills/board/reconcile.py finds a
# card's pull request with `gh pr list --head <branch>`, so the moment that
# machine's names gained the installation segment every in-flight card would
# read "no agent, no PR", and the board would dispatch a fresh build on top of
# an open pull request. So the home with no installation.toml, and the home
# `boardctl migrate` writes with `names = "legacy"`, keep the old shapes. Every
# installation created afterwards is scoped.
#
# The missing segment reopens the hole it closed, so this file also proves the
# legacy installation and a scoped sibling on one repository stay apart --
# sweep, watch and names -- and that bin/installation.py refuses the two roots
# where they cannot: two legacy installations, and a legacy board named like a
# scoped sibling.
#
# The only stubs are the external CLIs: `claude` for the agent registry and
# `gh` for the pull request lookup. FOREMAN_HOME points at a temp directory
# throughout. Nothing here may read or write the real ~/.foreman.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"
inst="$repo_root/bin/installation.py"

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
refuses() { # claim, needle, args...
  local claim="$1" needle="$2" err; shift 2
  if err="$("$inst" "$@" 2>&1 >/dev/null)"; then
    bad "$claim -- it loaded instead"; return 0
  fi
  case "$err" in
    *"$needle"*) ok "$claim" ;;
    *) bad "$claim: error did not name '$needle': $err" ;;
  esac
}

# --- fixture: one shared repository -----------------------------------------
repo="$work_dir/target"
mkdir -p "$repo"
git -C "$repo" init -q -b main
fixture_board_toml "$repo"

# An un-migrated home: boards.toml directly under .foreman, no installation.toml.
unmigrated_root="$work_dir/unmigrated"
fixture_add_board "$unmigrated_root" demo "$repo"
unmigrated_home="$unmigrated_root/.foreman"

# A migrated machine: `claude` is legacy and the default, as `boardctl migrate`
# writes it, and `codex` is a scoped sibling created afterwards. Harness claude
# on both, because the claim is about names and one registry stub serves both.
root="$work_dir/root"
FIXTURE_LEGACY_NAMES=1 fixture_add_installation "$root" claude claude --default
fixture_add_installation "$root" codex claude
legacy_home="$root/.foreman/claude"
scoped_home="$root/.foreman/codex"
fixture_add_board_in "$legacy_home" demo "$repo"
fixture_add_board_in "$scoped_home" demo "$repo"

# --- stubs: `claude agents` answers FIXTURE_AGENTS_JSON or "[]"; `gh` records
# its argv and answers "[]", which reconcile.py reads as "no pull request".
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
fi
exit 0
STUB
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV_LOG"
printf '[]\n'
STUB
chmod +x "$stub_dir/claude" "$stub_dir/gh"

# ask <foreman_home> <shell expression> -- evaluates it after sourcing config.sh.
# LEGACY_NAMES is cleared here and set on purpose only in the case that tests it.
ask() {
  env -u LEGACY_NAMES HOME="$work_dir" FOREMAN_HOME="$1" FOREMAN_INSTANCE=demo \
    PATH="$stub_dir:$PATH" bash -c ". '$board_dir/config.sh' >/dev/null; $2"
}

# head_asked <foreman_home> -- the --head value reconcile.py's pr_for hands gh.
head_asked() {
  local log="$work_dir/gh-$RANDOM.log"
  : > "$log"
  env -u LEGACY_NAMES HOME="$work_dir" FOREMAN_HOME="$1" FOREMAN_INSTANCE=demo \
    PATH="$stub_dir:$PATH" GH_ARGV_LOG="$log" python3 - "$board_dir" <<'PY' >/dev/null
import sys
sys.path.insert(0, sys.argv[1])
import reconcile
reconcile.pr_for("PRA-7")
PY
  sed -n 's/.*pr list --head \([^ ]*\).*/\1/p' "$log"
}

# =============================================================================
# A. an un-migrated home and a names = "legacy" installation keep every shape
# =============================================================================
for pair in "un-migrated home:$unmigrated_home" "legacy installation:$legacy_home"; do
  what="${pair%%:*}"; home="${pair#*:}"
  check "$what: a build agent is foreman/<board>/<ticket>/build-1" \
    "foreman/demo/PRA-7/build-1" "$(ask "$home" 'agent_name PRA-7 build 1')"
  check "$what: the worktree is foreman-<board>-<ticket>" \
    "$repo/.claude/worktrees/foreman-demo-PRA-7" "$(ask "$home" 'worktree_path PRA-7')"
  check "$what: the branch is foreman/<board>/<ticket>" \
    "foreman/demo/PRA-7" "$(ask "$home" 'branch_name PRA-7')"
  check "$what: the evidence ref is refs/foreman/<board>/evidence/<n>" \
    "refs/foreman/demo/evidence/12345" "$(ask "$home" 'evidence_ref 12345')"
  check "$what: the tick is foreman/tick" \
    "foreman/tick" "$(ask "$home" 'printf %s "$TICK_AGENT_NAME"')"
  check "$what: reconcile.py asks gh for the pull request on foreman/<board>/<ticket>" \
    "foreman/demo/PRA-7" "$(head_asked "$home")"
done

# =============================================================================
# B. the scoped sibling on the same repository keeps the installation segment
# =============================================================================
check "scoped sibling: a build agent is foreman/<installation>/<board>/<ticket>/build-1" \
  "foreman/codex/demo/PRA-7/build-1" "$(ask "$scoped_home" 'agent_name PRA-7 build 1')"
check "scoped sibling: the worktree is foreman-<installation>-<board>-<ticket>" \
  "$repo/.claude/worktrees/foreman-codex-demo-PRA-7" "$(ask "$scoped_home" 'worktree_path PRA-7')"
check "scoped sibling: the tick is foreman/<installation>/tick" \
  "foreman/codex/tick" "$(ask "$scoped_home" 'printf %s "$TICK_AGENT_NAME"')"
check "scoped sibling: reconcile.py asks gh for foreman/<installation>/<board>/<ticket>" \
  "foreman/codex/demo/PRA-7" "$(head_asked "$scoped_home")"

# =============================================================================
# C. an exported LEGACY_NAMES=1 does not give a scoped installation the legacy
#    shapes -- it would reap the legacy sibling's worktrees
# =============================================================================
exported="$(env LEGACY_NAMES=1 HOME="$work_dir" FOREMAN_HOME="$scoped_home" FOREMAN_INSTANCE=demo \
  bash -c ". '$board_dir/config.sh' >/dev/null; branch_name PRA-7; worktree_path PRA-7")"
check "an exported LEGACY_NAMES=1 does not give a scoped installation the legacy shapes" \
  "foreman/codex/demo/PRA-7"$'\n'"$repo/.claude/worktrees/foreman-codex-demo-PRA-7" "$exported"

# =============================================================================
# D. each installation's sweep --orphans reaps only its own worktree
# =============================================================================
legacy_wt="$repo/.claude/worktrees/foreman-demo-PRA-2"
scoped_wt="$repo/.claude/worktrees/foreman-codex-demo-PRA-2"

# sweep_orphans <foreman_home> -- the real sweep.sh, registry answering "[]".
sweep_orphans() {
  env -u LEGACY_NAMES HOME="$work_dir" FOREMAN_HOME="$1" FOREMAN_INSTANCE=demo \
    PATH="$stub_dir:$PATH" "$board_dir/sweep.sh" --orphans >"$work_dir/sweep.out" 2>&1
}

mkdir -p "$legacy_wt" "$scoped_wt"
if sweep_orphans "$legacy_home"; then
  if [[ ! -d "$legacy_wt" && -d "$scoped_wt" ]]; then
    ok "the legacy installation's --orphans never reaps the scoped sibling's worktree"
  else
    bad "the legacy installation's --orphans got the wrong worktree: legacy $([[ -d "$legacy_wt" ]] && echo survived || echo gone), scoped $([[ -d "$scoped_wt" ]] && echo survived || echo gone)"
  fi
else
  bad "the legacy installation's --orphans exited non-zero: $(cat "$work_dir/sweep.out")"
fi

mkdir -p "$legacy_wt" "$scoped_wt"
if sweep_orphans "$scoped_home"; then
  if [[ -d "$legacy_wt" && ! -d "$scoped_wt" ]]; then
    ok "the scoped sibling's --orphans never reaps the legacy installation's worktree"
  else
    bad "the scoped sibling's --orphans got the wrong worktree: legacy $([[ -d "$legacy_wt" ]] && echo survived || echo gone), scoped $([[ -d "$scoped_wt" ]] && echo survived || echo gone)"
  fi
else
  bad "the scoped sibling's --orphans exited non-zero: $(cat "$work_dir/sweep.out")"
fi

# =============================================================================
# E. watch-agents.py under each reports only its own agents
# =============================================================================
agents_json="$work_dir/agents.json"
cat > "$agents_json" <<'JSON'
[
  {"name": "foreman/demo/PRA-9/build-1", "id": "l1", "sessionId": "s1",
   "pid": 1, "state": "done", "startedAt": 1, "cwd": "/tmp/l", "status": "done"},
  {"name": "foreman/codex/demo/PRA-9/build-1", "id": "c1", "sessionId": "s2",
   "pid": 2, "state": "done", "startedAt": 1, "cwd": "/tmp/c", "status": "done"},
  {"name": "foreman/tick", "id": "t1", "sessionId": "s3",
   "pid": 3, "state": "done", "startedAt": 1, "cwd": "/tmp/t", "status": "done"}
]
JSON

# poll_as <foreman_home> -- the real watch-agents.py up to main(), whose loop
# never returns, then one poll(): the agents it would report, |-joined.
poll_as() {
  env -u LEGACY_NAMES HOME="$work_dir" FOREMAN_HOME="$1" FOREMAN_INSTANCE=demo \
    PATH="$stub_dir:$PATH" FIXTURE_AGENTS_JSON="$agents_json" \
    python3 - "$board_dir/watch-agents.py" <<'PY'
import sys
path = sys.argv[1]
ns = {"__file__": path}
exec(open(path).read().split("\ndef main")[0], ns)
print("|".join(sorted(ns["poll"]().keys())))
PY
}

check "watch-agents.py under the legacy installation reports only its own agents" \
  "foreman/demo/PRA-9/build-1" "$(poll_as "$legacy_home")"
check "watch-agents.py under the scoped sibling reports only its own agents" \
  "foreman/codex/demo/PRA-9/build-1" "$(poll_as "$scoped_home")"

# =============================================================================
# F. bin/installation.py refuses the roots where legacy names cannot be kept
#    apart, naming what collides
# =============================================================================
toml() { # path, default, names
  cat >"$1" <<TOML
harness = "claude"
default = $2
names = "$3"
TOML
}

two="$work_dir/two-legacy"; mkdir -p "$two/alpha" "$two/beta"
toml "$two/alpha/installation.toml" true legacy
toml "$two/beta/installation.toml" false legacy
refuses "two legacy installations under one root refuse, naming both" \
  "alpha, beta" --home "$two/beta"
refuses "--siblings refuses two legacy installations too" \
  "alpha, beta" --home "$two/alpha" --siblings

# A legacy board named `codex` beside a scoped installation `codex`: the legacy
# sweep would glob foreman-codex-* over the sibling's worktrees.
clash="$work_dir/clash/.foreman"; mkdir -p "$clash/claude" "$clash/codex"
toml "$clash/claude/installation.toml" true legacy
toml "$clash/codex/installation.toml" false scoped
fixture_add_board_in "$clash/claude" codex "$repo"
refuses "a legacy board named like a scoped sibling installation refuses, naming the legacy installation" \
  "legacy installation claude" --home "$clash/codex"
refuses "the same refusal names the scoped installation it collides with" \
  "as the installation codex" --home "$clash/claude"

# A value this loader cannot make sense of is refused, not read as scoped.
odd="$work_dir/odd"; mkdir -p "$odd/solo"
printf 'harness = "claude"\nnames = "old"\n' > "$odd/solo/installation.toml"
refuses "an unknown names value refuses, naming it" "'old'" --home "$odd/solo"
printf 'harness = "claude"\nnames = true\n' > "$odd/solo/installation.toml"
refuses "a names value that is not a string refuses" "must be a string" --home "$odd/solo"

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: the migrated Claude installation keeps its names, and a scoped sibling on the same repository keeps apart from it"
else
  echo "FAILED"
fi
exit "$fail"
