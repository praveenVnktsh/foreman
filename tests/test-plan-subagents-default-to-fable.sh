#!/usr/bin/env bash
# Claim: a dispatched agent's SUBAGENTS default to fable, the agent itself does
# not, and an operator can still turn the default off.
#
# This is the FALLBACK half, for a subagent that names no model of its own: an
# Explore or general-purpose agent the build agent spawns outside the graph.
# A graphplan node states its own tier and never falls back here -- an explicit
# per-spawn model outranks CLAUDE_CODE_SUBAGENT_MODEL, which is why the default
# for those nodes lives in skills/graphplan/SKILL.md and is pinned by
# tests/test-graphplan-tiers-default-to-fable.sh. The default travels as
# CLAUDE_CODE_SUBAGENT_MODEL in the environment of the `claude --bg`
# invocation, which is why this test reads the stub's environment and not its
# argv.
#
# Two failures are being pinned apart, and they look identical from outside:
#
#   1. The variable stops being set, and every unstated spawn silently runs on
#      the parent's model again. Nothing errors; the board just gets slower.
#   2. The variable starts covering the agent itself -- `--model` losing
#      BUILD_MODEL -- and the planner that has to read a repository and design
#      the graph is downgraded. Nothing errors there either; the plans just get
#      worse, which no test downstream can attribute back to here.
#
# This asserts on dispatch.sh's own boundary. Whether Claude Code then honours
# the variable is the CLI's contract, not this repository's to re-prove.
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# The same shim the permissions-toggle test builds, for the same reason:
# preflight.py wants an authenticated `gh` this suite may not assume it has,
# and config.sh finds bin/contract.py two directories up from itself.
shim_root="$work_dir/shim-repo"
mkdir -p "$shim_root/bin" "$shim_root/skills/board"
ln -s "$repo_root/bin/contract.py" "$shim_root/bin/contract.py"
ln -s "$repo_root/bin/boards.py" "$shim_root/bin/boards.py"
ln -s "$repo_root/bin/tmp-dir.sh" "$shim_root/bin/tmp-dir.sh"
shim="$shim_root/skills/board"
ln -s "$board_dir/config.sh" "$shim/config.sh"
ln -s "$board_dir/dispatch.sh" "$shim/dispatch.sh"
ln -s "$board_dir/withlock.py" "$shim/withlock.py"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$shim/preflight.py"
chmod +x "$shim/preflight.py"
dispatch="$shim/dispatch.sh"

git_q() {
  git -c user.name="Subagent Model Test" -c user.email="subagent-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

origin="$work_dir/origin.git"
target="$work_dir/target"
git_q init -q --bare "$origin"
git_q init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git_q -C "$target" add -A
git_q -C "$target" commit -q -m Seed
git_q -C "$target" remote add origin "$origin"
git_q -C "$target" push -q origin main

home="$work_dir/home"
fixture_add_instance "$home" demo "$target"

argv_log="$work_dir/argv.log"
env_log="$work_dir/env.log"
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
# `printenv NAME` exits 1 when the variable is unset and prints an empty line
# when it is set and empty. That difference is the whole third assertion, so
# the stub must record which of the two it saw, not collapse both to "".
cat > "$stub_dir/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$*" >"$argv_log"
  if value="\$(printenv CLAUDE_CODE_SUBAGENT_MODEL)"; then
    printf 'set:%s\n' "\$value" >"$env_log"
  else
    printf 'unset\n' >"$env_log"
  fi
  echo "stub-session-\$\$"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  echo '[]'
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/claude"

prompt_file="$work_dir/prompt.md"
echo "build the card" > "$prompt_file"

run_dispatch() { # ticket, then any VAR=value overrides
  local ticket="$1"; shift
  : >"$argv_log"; : >"$env_log"
  env "$@" HOME="$home" FOREMAN_INSTANCE=demo PATH="$stub_dir:$PATH" \
    "$dispatch" --ticket "$ticket" --role build --attempt 1 \
    --prompt-file "$prompt_file" >/dev/null 2>&1 || true
}

check_env() { # description, expected env_log line
  local desc="$1" want="$2" got
  got="$(cat "$env_log" 2>/dev/null || true)"
  if [[ -z "$got" ]]; then
    bad "$desc: dispatch.sh never reached claude --bg"
  elif [[ "$got" == "$want" ]]; then
    ok "$desc"
  else
    bad "$desc: expected '$want', got '$got'"
  fi
}

run_dispatch PRA-1
check_env "an unset SUBAGENT_MODEL defaults a dispatched agent's subagents to fable" "set:fable"

# The planner is not the thing being made cheap. `--model` must still carry
# BUILD_MODEL, or this knob has quietly downgraded the agent that designs the
# graph as well as the agents that build it.
argv="$(cat "$argv_log" 2>/dev/null || true)"
if [[ "$argv" == *"--model opus"* ]]; then
  ok "the agent itself still runs on BUILD_MODEL, not on the subagent default"
else
  bad "expected --model opus for the build agent, got: $argv"
fi

run_dispatch PRA-2 SUBAGENT_MODEL=sonnet
check_env "an operator's SUBAGENT_MODEL is what the subagents get" "set:sonnet"

# Empty means inherit the parent, and it must survive as empty. `:-` in
# config.sh would reinstate fable here and leave an operator with no way to
# turn the default off -- the bug AGENT_SKIP_PERMISSIONS shipped with.
run_dispatch PRA-3 SUBAGENT_MODEL=
check_env "an explicitly empty SUBAGENT_MODEL reaches the CLI as empty, which it reads as inherit" "set:"

[[ "$fail" -eq 0 ]] && printf 'PASS: plan subagents default to fable, the planner does not\n'
exit "$fail"
