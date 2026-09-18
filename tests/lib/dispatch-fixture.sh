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

# The fallback knobs, same shape and cleared/passed through the same way, for
# the same reason: config.sh's pair loader uses `-`, not `:-`, so an operator's
# shell can answer any of them before installation.py emits this harness's
# default the way PLAN_MODEL always could. test-dispatch-spawns-on-the-fallback-tier.sh
# sets PLAN_FLOOR after dispatch_fixture_setup, the same hole the model knobs
# leave open on purpose.
_DISPATCH_FALLBACK_KNOBS="FALLBACK_TIERS FALLBACK_COOLDOWN_MINUTES PLAN_FLOOR BUILD_FLOOR REVIEW_FLOOR"

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
#
# `claude` is deliberately absent. Every `claude` a dispatch runs under this
# fixture is the stub written below, a bash script that exits 0 on any argv --
# so probing it measures bash a second time, and the real binary never.
_DISPATCH_PROGRAMS="bash git python3"

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
  for knob in $_DISPATCH_MODEL_KNOBS $_DISPATCH_FALLBACK_KNOBS; do
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
  # config.sh reads this installation's declaration before anything else, and
  # reads it from THIS root's bin/ -- so a shim without it refuses at the first
  # line of config.sh, in every test that drives a dispatch.
  ln -s "$repo_root/bin/installation.py" "$shim_root/bin/installation.py"
  # config.sh sources its pair reader from THIS root's bin/ on its first line.
  ln -s "$repo_root/bin/load-pairs.sh" "$shim_root/bin/load-pairs.sh"
  ln -s "$repo_root/bin/tmp-dir.sh" "$shim_root/bin/tmp-dir.sh"
  local shim="$shim_root/skills/board"
  ln -s "$board_dir/config.sh" "$shim/config.sh"
  ln -s "$board_dir/dispatch.sh" "$shim/dispatch.sh"
  ln -s "$board_dir/withlock.py" "$shim/withlock.py"
  # dispatch.sh refuses when it cannot count the machine's slots, and the
  # count is reconcile.py's. A shim without it used to switch the ceiling gate
  # off in silence; now it dies at the gate before any spawn, which every test
  # on this fixture reads as "never reached claude --bg".
  ln -s "$board_dir/reconcile.py" "$shim/reconcile.py"
  # dispatch.sh asks this for the model a fresh spawn actually runs on. A shim
  # without it does not disable fallback -- dispatch.sh's own "a broken helper
  # must not stop all work" rule falls it back to the first-choice model and
  # warns on stderr -- so a fixture missing this symlink would still look
  # green while proving nothing about the fallback path at all.
  ln -s "$board_dir/fallback.py" "$shim/fallback.py"
  # The WHOLE directory, as one symlink. config.sh checks that
  # skills/board/harness/$HARNESS.sh under this root is executable and refuses
  # there rather than at the spawn, so the adapter this installation selects has
  # to exist here -- and linking the directory means an adapter added for a
  # fourth harness needs no second edit in this fixture.
  ln -s "$board_dir/harness" "$shim/harness"
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
  # The repository the git probe reads. A dispatch's git work happens inside a
  # repository, and a probe that opens none proves nothing about it.
  _DISPATCH_TARGET="$target"

  DISPATCH_HOME="$work_dir/home"
  fixture_add_instance "$DISPATCH_HOME" demo "$target"

  DISPATCH_ARGV_LOG="$work_dir/argv.log"
  DISPATCH_SUBAGENT_MODEL_LOG="$work_dir/subagent-model.log"
  _DISPATCH_AGENT_NAME_LOG="$work_dir/agent-name.log"
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
  #
  # `agents` ANSWERS FOR THE NAME IT WAS JUST GIVEN. The adapter spawns with
  # `--bg` and then asks the registry for the session id of that name, so a stub
  # that always printed `[]` made every spawn die at "it never registered" --
  # after the argv this fixture captures, which is why the old one got away with
  # it. It no longer does: dispatch.sh treats the adapter's non-zero exit as its
  # own, so the dispatch would now die before writing the card's spawn entry.
  # The `--name` is recorded and only ever overwritten by a later `--name`, so a
  # resume (`--bg --resume`, which carries none) still finds the live agent.
  cat > "$_DISPATCH_STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$@" >"$DISPATCH_ARGV_LOG"
  printf '%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}" >"$DISPATCH_SUBAGENT_MODEL_LOG"
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--name" && \$# -ge 2 ]]; then printf '%s\n' "\$2" >"$_DISPATCH_AGENT_NAME_LOG"; fi
    shift
  done
  echo "stub-session-\$\$"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  name=""
  if [[ -s "$_DISPATCH_AGENT_NAME_LOG" ]]; then name="\$(cat "$_DISPATCH_AGENT_NAME_LOG")"; fi
  if [[ -z "\$name" ]]; then
    echo '[]'
    exit 0
  fi
  printf '[{"name":"%s","id":"stub-agent","sessionId":"stub-session","pid":%s,"state":"working","startedAt":1,"cwd":"%s","status":"running"}]\n' \\
    "\$name" "\$\$" "\$PWD"
  exit 0
fi
exit 0
STUB
  chmod +x "$_DISPATCH_STUB_BIN/claude"

  DISPATCH_PROMPT="$work_dir/prompt.md"
  echo "do the thing" > "$DISPATCH_PROMPT"

  # Nothing is probed here. dispatch_fixture_run derives the toolchain when it
  # is about to need it, so a toolchain variable exported AFTER this call is
  # honoured exactly like one exported before it.
  _DISPATCH_TOOLCHAIN=""
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
# Failure is swallowed on purpose: a dispatch has work after the spawn that no
# caller of this fixture asserts on, and a test that fails should fail on its
# own assertion rather than on this helper's exit status.
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
# file, so the knob class cannot be listed, while this fixture's own four
# base names can.
#
# FOREMAN_HOME is now one of those four, SET BY THIS FIXTURE and still blocked
# from the operator's shell. config.sh no longer defaults it to $HOME/.foreman:
# it asks bin/installation.py, which derives the home as the parent of the
# install root. The install root here is the shim under $work_dir, so the
# derived home would be $work_dir -- which holds no boards.toml, and every
# dispatch would die at the board load. An explicit FOREMAN_HOME is what that
# derivation is designed to yield to, and it is how the whole suite points at a
# temporary directory instead of the operator's own installation.
#
# The dispatch's own output goes to $DISPATCH_RUN_LOG rather than /dev/null.
# A dispatch that dies before the spawn tells a test only "never reached
# `claude --bg`", which names nothing; the log is where the reason is, and
# dispatch_fixture_show_run_log is how a test prints it.
dispatch_fixture_run() {
  : >"$DISPATCH_ARGV_LOG"
  : >"$DISPATCH_SUBAGENT_MODEL_LOG"
  # Truncated with the other two. A name left over from the previous dispatch
  # would let the stubbed registry answer for an agent this one never spawned.
  : >"$_DISPATCH_AGENT_NAME_LOG"
  # The one hole: a model or fallback knob a test set deliberately after
  # dispatch_fixture_setup cleared the operator's. `+` and not `:-`, because
  # `PLAN_MODEL=` empty is itself a value under test and must reach the CLI as
  # an empty `--model`, and `PLAN_FLOOR=` empty means "no floor" the same way.
  local models=() knob
  for knob in $_DISPATCH_MODEL_KNOBS $_DISPATCH_FALLBACK_KNOBS; do
    if [[ -n "${!knob+set}" ]]; then models+=("$knob=${!knob}"); fi
  done
  # What the toolchain needs, measured rather than listed here by hand, and
  # re-measured when the answer no longer holds. `+` and not `:-`, to add no
  # name the caller has unset since.
  _dispatch_ensure_toolchain
  local toolchain=() name
  for name in $_DISPATCH_TOOLCHAIN; do
    if [[ -n "${!name+set}" ]]; then toolchain+=("$name=${!name}"); fi
  done
  # bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
  # error, not an empty expansion.
  #
  # The ceilings are raised out of the way. This fixture's board declares
  # MAX_CONCURRENT 1 and its callers dispatch several cards in a row to read
  # their argv, so with the gate real (reconcile.py linked above) the second
  # dispatch would refuse at the ceiling. The gate itself is
  # test-dispatch-holds-the-cap.sh's claim, on its own fixture.
  env -i \
    HOME="$DISPATCH_HOME" \
    FOREMAN_INSTANCE=demo \
    FOREMAN_HOME="$DISPATCH_HOME/.foreman" \
    MAX_CONCURRENT=9 HOST_MAX_CONCURRENT=9 \
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

# Which of the caller's exported names the toolchain cannot work without.
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
# Checked before every dispatch and re-derived when the answer stops holding.
# That is what makes a name exported after dispatch_fixture_setup work: the
# check costs one process per program, and the search below runs only when a
# program fails it.
_dispatch_ensure_toolchain() {
  local program
  for program in $_DISPATCH_PROGRAMS; do
    if ! _dispatch_program_starts "$program" "$_DISPATCH_TOOLCHAIN"; then
      _dispatch_derive_toolchain
      return
    fi
  done
}

_dispatch_derive_toolchain() {
  local candidates="" name program kept head tail trial

  # Every exported name of the caller's shell, except the four this fixture
  # sets itself and the model and fallback knobs. Excluding the knobs is what
  # stops one entering the allowlist through the toolchain half; excluding the
  # base four keeps the probe from proving that HOME needs HOME.
  for name in $(compgen -e || true); do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case " HOME FOREMAN_INSTANCE FOREMAN_HOME PATH $_DISPATCH_MODEL_KNOBS $_DISPATCH_FALLBACK_KNOBS " in
      *" $name "*) continue ;;
    esac
    candidates="${candidates:+$candidates }$name"
  done

  _DISPATCH_TOOLCHAIN=""
  for program in $_DISPATCH_PROGRAMS; do
    # It does its work on the base environment alone, so it needs nothing from
    # the caller's shell.
    if _dispatch_program_starts "$program" ""; then continue; fi

    if ! _dispatch_program_starts "$program" "$candidates"; then
      # Refuse rather than degrade. Handing the dispatch a toolchain that
      # cannot work buys five tests reporting "never reached `claude --bg`"
      # and naming neither the program nor the reason.
      _dispatch_set_probe_argv "$program"
      printf 'dispatch-fixture: %s does not work under the environment this fixture hands a dispatch.\n' \
        "$program" >&2
      printf '  probe: env -i HOME=%s FOREMAN_INSTANCE=demo FOREMAN_HOME=%s PATH=%s <every exported name> %s\n' \
        "$DISPATCH_HOME" "$DISPATCH_HOME/.foreman" "$_DISPATCH_STUB_BIN:$PATH" \
        "${_DISPATCH_PROBE_ARGV[*]}" >&2
      printf '  %s said:\n' "$program" >&2
      sed 's/^/    /' "$_DISPATCH_PROBE_ERR" >&2
      exit 1
    fi

    # It worked once the caller's names were added, so some of them are
    # load-bearing. Halve to find which, then prove it by removal.
    #
    # Halving is what keeps this affordable on the runner it exists for. There,
    # setup-python's python3 fails the base probe in every test, and a GitHub
    # runner exports around ninety names -- one process each, five times over,
    # for the removal pass alone. Halving reaches a single load-bearing name in
    # about seven probes. It stops when neither half is enough by itself, which
    # means two names in different halves, and the removal pass then finishes
    # the job: what reaches a dispatch is minimal either way.
    kept="$candidates"
    while [[ "$(_dispatch_name_count "$kept")" -gt 1 ]]; do
      head="$(_dispatch_names_half head "$kept")"
      tail="$(_dispatch_names_half tail "$kept")"
      if _dispatch_program_starts "$program" "$head"; then kept="$head"; continue; fi
      if _dispatch_program_starts "$program" "$tail"; then kept="$tail"; continue; fi
      break
    done
    for name in $kept; do
      trial="$(_dispatch_names_without "$name" "$kept")"
      if _dispatch_program_starts "$program" "$trial"; then kept="$trial"; fi
    done

    for name in $kept; do
      case " $_DISPATCH_TOOLCHAIN " in *" $name "*) continue ;; esac
      _DISPATCH_TOOLCHAIN="${_DISPATCH_TOOLCHAIN:+$_DISPATCH_TOOLCHAIN }$name"
    done
  done
}

# Does <program> do a dispatch's work under `env -i` plus this fixture's three
# base names and the extras named in <names>?
#
# REAL WORK, never `--version`. CPython answers `--version` from its launcher
# before it imports anything: measured 2026-09-10, `env -i PATH=/usr/bin:/bin
# PYTHONHOME=/nonexistent python3 --version` prints a version and exits 0 while
# the same environment running `python3 -c 'import json'` dies at
# `init_fs_encoding`. A version-only probe records the interpreter dispatch.sh
# leans on hardest as needing nothing at all, strips the name it needed, and
# the dispatch dies at the contract load -- which is the silent failure this
# derivation exists to remove, reintroduced by the thing that removes it.
_dispatch_program_starts() { # <program> <names, space separated>
  local program="$1" names="$2"
  local extra=() name
  for name in $names; do
    if [[ -n "${!name+set}" ]]; then extra+=("$name=${!name}"); fi
  done
  _dispatch_set_probe_argv "$program"
  env -i \
    HOME="$DISPATCH_HOME" \
    FOREMAN_INSTANCE=demo \
    FOREMAN_HOME="$DISPATCH_HOME/.foreman" \
    PATH="$_DISPATCH_STUB_BIN:$PATH" \
    ${extra[@]+"${extra[@]}"} \
    "${_DISPATCH_PROBE_ARGV[@]}" >/dev/null 2>"$_DISPATCH_PROBE_ERR"
}

# What each probed program is asked to do: the smallest piece of a dispatch's
# own work that an environment variable can break. A table, so a program added
# to _DISPATCH_PROGRAMS without one refuses here instead of being measured by
# something that proves nothing about it.
_dispatch_set_probe_argv() { # <program>
  case "$1" in
    # The `bash -c` block withlock.py wraps around the worktree commands.
    bash) _DISPATCH_PROBE_ARGV=(bash -c :) ;;
    # Reading a repository, which is the whole of what a dispatch's git does.
    # `git --version` opens none, and answers on a git that cannot.
    git) _DISPATCH_PROBE_ARGV=(git -C "$_DISPATCH_TARGET" worktree list) ;;
    # The imports config.sh's loaders and dispatch.sh's slot readers make.
    # tomllib is bin/contract.py's, and the 3.11 floor this repository builds on.
    python3) _DISPATCH_PROBE_ARGV=(python3 -c 'import json, pathlib, sys, tomllib') ;;
    *)
      printf 'dispatch-fixture: no probe for %s; give it one beside the others\n' "$1" >&2
      exit 1
      ;;
  esac
}

_dispatch_name_count() { # <names, space separated>
  local name count=0
  for name in $1; do count=$((count + 1)); done
  printf '%s' "$count"
}

_dispatch_names_half() { # <head|tail> <names, space separated>
  local which="$1" names="$2" half i=0 out="" name
  half=$(( $(_dispatch_name_count "$names") / 2 ))
  for name in $names; do
    i=$((i + 1))
    if [[ "$which" == head && "$i" -le "$half" ]] ||
       [[ "$which" == tail && "$i" -gt "$half" ]]; then
      out="${out:+$out }$name"
    fi
  done
  printf '%s' "$out"
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
