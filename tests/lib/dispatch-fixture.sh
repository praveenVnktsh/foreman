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

# The model knobs, written ONCE. dispatch_fixture_setup clears these three from
# the caller's shell and dispatch_fixture_run passes the same three back
# through, so a second copy of the list would drift the day a fourth stage
# arrives -- a knob cleared at setup and never passed through reaches no
# dispatch, and a knob passed through but never cleared carries the operator's
# value into every test.
_DISPATCH_MODEL_KNOBS="PLAN_MODEL BUILD_MODEL REVIEW_MODEL"

# The programs dispatch.sh runs. Read dispatch.sh and check this list rather
# than trusting it; each name says where it is run:
#   bash    -- the `bash -c` block withlock.py wraps to cut the worktree, and a
#              build role's BOOTSTRAP_COMMAND.
#   git     -- inside that block: fetch, worktree remove, worktree prune,
#              worktree add.
#   python3 -- preflight.py, reconcile.py --host-slots and --may-dispatch,
#              withlock.py, the two inline `python3 -c` slot readers,
#              lookup_session, and config.sh's bin/boards.py and
#              bin/contract.py.
#   claude  -- `claude agents` in lookup_session, and the `claude --bg` spawn
#              this whole fixture exists to capture.
_DISPATCH_PROGRAMS="bash git python3 claude"

# dispatch_fixture_setup <work_dir> <repo_root>
#
# Sets DISPATCH (the shim's dispatch.sh), DISPATCH_ARGV_LOG (the last
# `claude --bg` argv), DISPATCH_RUN_LOG (that dispatch's own output),
# DISPATCH_SEED_SHA (a real commit on origin, for a reviewer's --ref),
# DISPATCH_PROMPT and DISPATCH_CLEARED_KNOBS (the model knobs it took out of
# the caller's shell).
dispatch_fixture_setup() {
  local work_dir="$1" repo_root="$2"
  local board_dir="$repo_root/skills/board"

  # Clear the operator's model overrides, so that a model variable being SET
  # when dispatch_fixture_run reads it means a test set it on purpose.
  #
  # dispatch_fixture_run passes these three through and blocks everything else
  # (see the allowlist there). They are passed through because a test asserts
  # on them: test-the-plan-stage-dispatches-on-fable.sh exports PLAN_MODEL
  # after this call and requires it to reach `claude --bg --model`. That hole
  # is only safe if the operator's own value is already gone, which is what
  # this loop does. An operator with PLAN_MODEL exported in their shell saw
  # both model tests go red on a correctly configured machine: config.sh's
  # `${PLAN_MODEL-fable}` never fired, because the ambient export had already
  # answered it.
  #
  # The clearing is ANNOUNCED. Erasing it silently sends the operator hunting
  # for the value they set: the suite honours the same line typed after this
  # call and drops it when typed before, which reads as the fixture ignoring
  # them at random.
  local knob
  DISPATCH_CLEARED_KNOBS=""
  for knob in $_DISPATCH_MODEL_KNOBS; do
    if [[ -n "${!knob+set}" ]]; then
      DISPATCH_CLEARED_KNOBS="${DISPATCH_CLEARED_KNOBS:+$DISPATCH_CLEARED_KNOBS }$knob"
      unset "$knob"
    fi
  done
  if [[ -n "$DISPATCH_CLEARED_KNOBS" ]]; then
    printf 'dispatch-fixture: cleared from your shell so the dispatches under test decide their own model: %s\n' \
      "$DISPATCH_CLEARED_KNOBS" >&2
  fi

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
  DISPATCH_RUN_LOG="$work_dir/dispatch.log"
  _DISPATCH_PROBE_ERR="$work_dir/probe.err"
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

  # Last, because the probe runs the stub `claude` on the stub PATH and under
  # $DISPATCH_HOME -- the environment the dispatches are about to get.
  _dispatch_derive_toolchain
}

# dispatch_fixture_show_run_log
# Prints the dispatch's own output to stderr, headed by its path. A caller's
# failure message says only "the dispatch never reached `claude --bg`", which
# names nothing; the reason is in this log, and the header and footer are what
# keep the two apart in one terminal. Safe on an empty or absent log: a
# dispatch that died before it wrote anything is itself the evidence.
dispatch_fixture_show_run_log() {
  printf -- '----- dispatch output: %s -----\n' "$DISPATCH_RUN_LOG" >&2
  if [[ -s "$DISPATCH_RUN_LOG" ]]; then
    cat "$DISPATCH_RUN_LOG" >&2
  elif [[ -e "$DISPATCH_RUN_LOG" ]]; then
    printf '(the dispatch wrote nothing)\n' >&2
  else
    printf '(no log at that path; the dispatch never ran)\n' >&2
  fi
  printf -- '----- end of dispatch output -----\n' >&2
}

# dispatch_fixture_run <dispatch.sh args...>
# Runs one dispatch and leaves its `claude --bg` argv in $DISPATCH_ARGV_LOG.
# Failure is swallowed on purpose: the stubbed `claude agents` reports no
# agents, so every dispatch dies at "never registered" AFTER the spawn this
# fixture exists to capture.
#
# The dispatch is given an ALLOWLIST of an environment -- `env -i` plus the
# names below -- and not the caller's. Nearly every value in config.sh is
# `${NAME:-default}`, so the operator's shell can answer any of them before
# config.sh asks, and the test then fails on a correctly configured machine
# with nothing in the diff under review to blame. Named per incident, that is
# one fix per variable someone happens to export: PLAN_MODEL was the first
# (PRA-276), and CLAUDE_CODE_SUBAGENT_MODEL, REPO, FOREMAN_HOME,
# BOARD_DRY_RUN, FOREMAN_TMP_ROOT and BOARD_HOME each reproduce it. An
# allowlist closes the class, and makes each remaining hole a decision. It
# stays an allowlist: config.sh honours the environment for every key
# bin/boards.py and bin/contract.py emit as well as the ones written in the
# file, so the knob class cannot be listed, while this fixture's own three
# base names can.
#
# The dispatch's own output goes to $DISPATCH_RUN_LOG rather than /dev/null.
# A dispatch that dies before the spawn tells a test only "never reached
# `claude --bg`", which names nothing; the log is where the reason is, and
# dispatch_fixture_show_run_log is how a test prints it.
dispatch_fixture_run() {
  : >"$DISPATCH_ARGV_LOG"
  : >"$DISPATCH_SUBAGENT_MODEL_LOG"
  # The one hole: a model a test set deliberately after dispatch_fixture_setup
  # cleared the operator's. `+` and not `:-`, because `PLAN_MODEL=` empty is
  # itself a value under test and must reach the CLI as an empty `--model`.
  local models=() knob
  for knob in $_DISPATCH_MODEL_KNOBS; do
    if [[ -n "${!knob+set}" ]]; then models+=("$knob=${!knob}"); fi
  done
  # What the toolchain needed, measured by _dispatch_derive_toolchain during
  # setup rather than listed here by hand. `+` and not `:-`, to add no name
  # the caller has unset since.
  local toolchain=() name
  for name in $_DISPATCH_TOOLCHAIN; do
    if [[ -n "${!name+set}" ]]; then toolchain+=("$name=${!name}"); fi
  done
  # bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
  # error, not an empty expansion.
  env -i \
    HOME="$DISPATCH_HOME" \
    FOREMAN_INSTANCE=demo \
    PATH="$_DISPATCH_STUB_BIN:$PATH" \
    ${toolchain[@]+"${toolchain[@]}"} \
    ${models[@]+"${models[@]}"} \
    "$DISPATCH" "$@" --prompt-file "$DISPATCH_PROMPT" >"$DISPATCH_RUN_LOG" 2>&1 || true
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

# Which of the caller's exported names the toolchain cannot start without.
#
# Derived by RUNNING each program dispatch.sh runs, because the toolchain is a
# class and not a list. CI's `actions/setup-python` puts a `python3` on PATH
# that dies with `error while loading shared libraries: libpython3.12.so.1.0`
# when LD_LIBRARY_PATH is stripped: every dispatch died at its first python3
# call -- the contract load -- and all five tests driving this fixture reported
# only "the dispatch never reached `claude --bg`". LD_LIBRARY_PATH was then
# allowlisted by name, which covers that one runner and not the next one, whose
# interpreter reads a different name.
#
# Cost on a healthy machine: four `--version` calls, and nothing else. The
# name-by-name search runs only for a program that refuses to start.
#
# This runs ONCE, at the end of setup, and every dispatch reuses the answer. A
# toolchain variable therefore has to be exported BEFORE dispatch_fixture_setup
# -- which is the shape a runner exports it in anyway, beside the PATH it
# belongs to.
_dispatch_derive_toolchain() {
  local candidates="" name program kept trial

  # Every exported name of the caller's shell, except the three this fixture
  # sets itself and the model knobs. Excluding the knobs is what stops one
  # entering the allowlist through the toolchain half; excluding the base
  # three keeps the probe from proving that HOME needs HOME.
  for name in $(compgen -e || true); do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case " HOME FOREMAN_INSTANCE PATH $_DISPATCH_MODEL_KNOBS " in
      *" $name "*) continue ;;
    esac
    candidates="${candidates:+$candidates }$name"
  done

  _DISPATCH_TOOLCHAIN=""
  for program in $_DISPATCH_PROGRAMS; do
    # It starts on the base environment alone, so it needs nothing from the
    # caller's shell.
    if _dispatch_program_starts "$program" ""; then continue; fi

    if ! _dispatch_program_starts "$program" "$candidates"; then
      # Refuse rather than degrade. Handing the dispatch an interpreter that
      # cannot start buys five tests reporting "never reached `claude --bg`"
      # and naming neither the program nor the reason.
      printf 'dispatch-fixture: %s does not start under the environment this fixture hands a dispatch.\n' \
        "$program" >&2
      printf '  probe: env -i HOME=%s FOREMAN_INSTANCE=demo PATH=%s <every exported name> %s --version\n' \
        "$DISPATCH_HOME" "$_DISPATCH_STUB_BIN:$PATH" "$program" >&2
      printf '  %s said:\n' "$program" >&2
      sed 's/^/    /' "$_DISPATCH_PROBE_ERR" >&2
      exit 1
    fi

    # It started with the caller's names added, so one of them is load-bearing.
    # Take them away one at a time and keep only the ones whose removal breaks
    # the start again.
    kept="$candidates"
    for name in $candidates; do
      trial="$(_dispatch_names_without "$name" "$kept")"
      if _dispatch_program_starts "$program" "$trial"; then kept="$trial"; fi
    done
    for name in $kept; do
      case " $_DISPATCH_TOOLCHAIN " in *" $name "*) continue ;; esac
      _DISPATCH_TOOLCHAIN="${_DISPATCH_TOOLCHAIN:+$_DISPATCH_TOOLCHAIN }$name"
    done
  done
}

# Does <program> start under `env -i` plus this fixture's three base names and
# the extras named in <names>? `--version` is enough: a program that answers it
# has already loaded its interpreter and every library it links.
_dispatch_program_starts() { # <program> <names, space separated>
  local program="$1" names="$2"
  local extra=() name
  for name in $names; do
    if [[ -n "${!name+set}" ]]; then extra+=("$name=${!name}"); fi
  done
  env -i \
    HOME="$DISPATCH_HOME" \
    FOREMAN_INSTANCE=demo \
    PATH="$_DISPATCH_STUB_BIN:$PATH" \
    ${extra[@]+"${extra[@]}"} \
    "$program" --version >/dev/null 2>"$_DISPATCH_PROBE_ERR"
}

_dispatch_names_without() { # <name to drop> <names, space separated>
  local drop="$1" name out=""
  for name in $2; do
    if [[ "$name" != "$drop" ]]; then out="${out:+$out }$name"; fi
  done
  printf '%s' "$out"
}

_dispatch_git() {
  git -c user.name="Dispatch Test" -c user.email="dispatch-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}
