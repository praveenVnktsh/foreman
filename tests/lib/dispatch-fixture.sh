#!/usr/bin/env bash
# Stand up the smallest environment in which `dispatch.sh` will actually reach
# `claude --bg`, and capture the argv it would have spawned.
#
# Shared because two tests need exactly this and assert different things about
# the same command line: test-the-plan-stage-dispatches-on-fable.sh and
# test-build-and-review-run-on-opus.sh. Duplicating ninety lines of git origin,
# board declaration and stub PATH into both is how the two copies drift until
# one of them stops testing the path it claims to.
#
# It stubs at the external boundary and nothing inside it. `claude` is stubbed
# because spawning a real agent is not what any caller is asserting, and
# `preflight.py` because it wants an authenticated `gh` this suite may not
# assume. Everything else -- config.sh, the contract loader, the worktree
# creation, the real dispatch.sh -- runs for real, which is what makes the
# captured argv evidence about production rather than about the fixture.

# shellcheck source=instance-fixture.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/instance-fixture.sh"

# dispatch_fixture_setup <work_dir> <repo_root>
#
# Sets DISPATCH (the shim's dispatch.sh), DISPATCH_ARGV_LOG (the last
# `claude --bg` argv), DISPATCH_SEED_SHA (a real commit on origin, for a
# reviewer's --ref) and DISPATCH_PROMPT.
dispatch_fixture_setup() {
  local work_dir="$1" repo_root="$2"
  local board_dir="$repo_root/skills/board"

  # A shim skill dir, identical to the real one except preflight.py. Same
  # two-level shape config.sh's contract loader depends on (skills/board/ next
  # to bin/), the same technique test-agent-skip-permissions-toggle.sh and
  # test-brief-uses-the-contract.sh use for the same reason.
  local shim_root="$work_dir/shim-repo"
  mkdir -p "$shim_root/bin" "$shim_root/skills/board"
  ln -s "$repo_root/bin/contract.py" "$shim_root/bin/contract.py"
  ln -s "$repo_root/bin/boards.py" "$shim_root/bin/boards.py"
  ln -s "$repo_root/bin/tmp-dir.sh" "$shim_root/bin/tmp-dir.sh"
  local shim="$shim_root/skills/board"
  ln -s "$board_dir/config.sh" "$shim/config.sh"
  ln -s "$board_dir/dispatch.sh" "$shim/dispatch.sh"
  ln -s "$board_dir/withlock.py" "$shim/withlock.py"
  cat > "$shim/preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
  chmod +x "$shim/preflight.py"
  DISPATCH="$shim/dispatch.sh"

  local origin="$work_dir/origin.git"
  local target="$work_dir/target"
  _dispatch_git init -q --bare "$origin"
  _dispatch_git init -q -b main "$target"
  fixture_board_toml "$target"
  echo seed > "$target/seed.txt"
  _dispatch_git -C "$target" add -A
  _dispatch_git -C "$target" commit -q -m Seed
  _dispatch_git -C "$target" remote add origin "$origin"
  _dispatch_git -C "$target" push -q origin main
  DISPATCH_SEED_SHA="$(_dispatch_git -C "$target" rev-parse HEAD)"

  DISPATCH_HOME="$work_dir/home"
  fixture_add_instance "$DISPATCH_HOME" demo "$target"

  DISPATCH_ARGV_LOG="$work_dir/argv.log"
  DISPATCH_SUBAGENT_MODEL_LOG="$work_dir/subagent-model.log"
  _DISPATCH_STUB_BIN="$work_dir/bin"
  mkdir -p "$_DISPATCH_STUB_BIN"
  # One argument per line, so an EMPTY argument is still one token. `"$*"`
  # joins on spaces and an empty `--model ""` disappears into the gap, which
  # is the one value the `-` vs `:-` distinction in config.sh exists to carry.
  #
  # The environment the agent is spawned with is logged too, because "no
  # fallback pushes a build subagent to fable" is a claim about an exported
  # variable and not about argv.
  cat > "$_DISPATCH_STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$@" >"$DISPATCH_ARGV_LOG"
  printf '%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}" >"$DISPATCH_SUBAGENT_MODEL_LOG"
  echo "stub-session-\$\$"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  echo '[]'
  exit 0
fi
exit 0
STUB
  chmod +x "$_DISPATCH_STUB_BIN/claude"

  DISPATCH_PROMPT="$work_dir/prompt.md"
  echo "do the thing" > "$DISPATCH_PROMPT"
}

# dispatch_fixture_run <dispatch.sh args...>
# Runs one dispatch and leaves its `claude --bg` argv in $DISPATCH_ARGV_LOG.
# Failure is swallowed on purpose: the stubbed `claude agents` reports no
# agents, so every dispatch dies at "never registered" AFTER the spawn this
# fixture exists to capture.
dispatch_fixture_run() {
  : >"$DISPATCH_ARGV_LOG"
  : >"$DISPATCH_SUBAGENT_MODEL_LOG"
  env HOME="$DISPATCH_HOME" FOREMAN_INSTANCE=demo \
    PATH="$_DISPATCH_STUB_BIN:$PATH" \
    "$DISPATCH" "$@" --prompt-file "$DISPATCH_PROMPT" >/dev/null 2>&1 || true
}

# dispatch_fixture_model — the value `--model` was given in the captured argv,
# or nothing at all when the dispatch never reached `claude --bg`.
dispatch_fixture_model() {
  python3 - "$DISPATCH_ARGV_LOG" <<'PY'
import sys

argv = open(sys.argv[1]).read().split("\n")[:-1]
if "--model" not in argv:
    sys.exit(0)
i = argv.index("--model")
if i + 1 < len(argv):
    # Quoted, so an empty value shows up in a failure message instead of
    # reading as "the assertion printed nothing".
    print(repr(argv[i + 1]))
PY
}

_dispatch_git() {
  git -c user.name="Dispatch Test" -c user.email="dispatch-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}
