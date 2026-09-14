#!/usr/bin/env bash
# What the board concludes when the deploy, `main` or the agent registry answers
# badly. Every case here is a defect that shipped.
#
# The board decides what reaches production, and the three things it reads —
# `gh`, `git`, `claude agents` — each have an answer that means "I could not
# tell". Folding one of those into an ordinary answer is this subsystem's
# characteristic failure, and it always fails in the direction of doing
# something: a failed deploy reported as satisfied moved a card to `Done`, an
# unreadable diff read as `risk: low` merged a migration, an unreadable registry
# read as "no agents" started a second board.
#
# So these are all one assertion, stated eleven ways: an answer the board could
# not read is never the same as an answer it read.
#
# Everything the board reasons over is stubbed rather than reached, because the
# subject is the reasoning. `lib/board-outcome-cases.py` replaces `reconcile.run`
# and `reconcile.run_json` outright; the `supervise.sh` case below puts a fake
# `claude` on PATH, which is the only way to exercise a decision that lives in a
# shell script's inline python.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# `reconcile` (imported by both board-outcome-cases.py and waitfor.py) shells
# out to config.sh at import time, which since Task 2/3 requires a
# FOREMAN_INSTANCE and an instance declaring a REPO whose board.toml loads.
# Nothing below reads REPO or the contract's values -- every gh/git call is
# stubbed -- so one fixture target and one instance, reused everywhere in this
# file, is enough.
fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

# FOREMAN_HOME is named explicitly here and in every run below. config.sh no
# longer derives it from $HOME: it asks bin/installation.py, which reads the
# home as the parent of the install root -- this repository's own parent, whose
# boards.toml is not a fixture's. An explicit home is what that derivation
# yields to, and it is how this file stays pointed at its temporary directory.
echo "==> what the board concludes from gh, without asking gh"
HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
  python3 "$here/lib/board-outcome-cases.py" \
  || fail "board-outcome-cases.py"

# --- waitfor's exit codes at the command line --------------------------------
#
# Exit 2 is argparse's own code for a usage error, and both of these paths print
# NOTHING on stdout. That is why settled-and-unsatisfied is 3: a tick that read
# 2 as "the deploy failed" would report a broken production, with a run URL from
# a verdict that was never printed, on nothing worse than a typo.

waitfor="$repo_root/skills/board/waitfor.py"
ask_waitfor() {
  HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo "$waitfor" "$@"
}

echo "==> an empty --sha is a bad invocation, not a settled outcome"
status=0
out="$(ask_waitfor deploy --sha "" 2>/dev/null)" || status=$?
[[ "$status" -eq 2 ]] || fail "empty --sha: expected exit 2, got $status"
[[ -z "$out" ]] || fail "empty --sha printed a verdict: $out"

echo "==> so is a missing --sha"
status=0
out="$(ask_waitfor deploy --timeout 5 2>/dev/null)" || status=$?
[[ "$status" -eq 2 ]] || fail "missing --sha: expected exit 2, got $status"
[[ -z "$out" ]] || fail "missing --sha printed a verdict: $out"

# --- supervise.sh and a registry that is not a list --------------------------
#
# `reconcile.load_agents()` refuses anything that is not a list; the inline
# python in supervise.sh only caught a JSON parse error. A future
# `{"agents": [...]}` wrapper parses fine, `for a in agents` iterates its keys,
# nothing matches, and it prints "{}" — which supervise.sh cannot tell from "no
# tick agent exists" and answers by starting a second loop agent beside a
# healthy one. Two ticks dispatching into the same slots is the worst outcome
# that script can produce, and it says so in its own comments.

# The stub goes in a HOME of its own, not merely on PATH: supervise.sh prepends
# `$HOME/.local/bin` to PATH itself — cron gives it neither — so a stub anywhere
# else loses to the real `claude`, and the test reads the live board's registry
# instead of the one it wrote. It did, and reported the running tick agent.
stub_claude() {
  local body="$1" home="$work_dir/home-$2"
  mkdir -p "$home/.local/bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "agents" ]]; then'
    printf '  cat <<%s\n%s\n%s\n' "JSON" "$body" "JSON"
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } >"$home/.local/bin/claude"
  chmod +x "$home/.local/bin/claude"
  # supervise.sh sources config.sh too, so this HOME needs the same instance
  # scaffolding as the python cases above -- reusing the same fixture target,
  # since supervise.sh's config.sh load doesn't care what REPO points to
  # either (DRY RUN never reaches it beyond the log line).
  fixture_add_instance "$home" demo "$fixture_repo"
  echo "$home"
}

supervise() {
  # DRY RUN so a misjudgement prints instead of spawning a real agent, and a
  # BOARD_HOME of its own so a lock file never lands in the real one.
  HOME="$1" FOREMAN_HOME="$1/.foreman" FOREMAN_INSTANCE=demo BOARD_DRY_RUN=1 \
    BOARD_HOME="$work_dir/board-home" \
    "$repo_root/skills/board/supervise.sh" 2>&1 || true
}

echo "==> a registry that is a JSON object is unreadable, not empty"
out="$(supervise "$(stub_claude '{"agents": []}' object)")"
grep -q "could not read the agent registry" <<<"$out" \
  || fail "an object registry was not reported as unreadable: $out"
grep -q "would start" <<<"$out" \
  && fail "supervise.sh started a second loop agent from an object registry: $out"

echo "==> a registry that is a list with no board agent does start one"
out="$(supervise "$(stub_claude '[]' empty)")"
grep -q "would start" <<<"$out" \
  || fail "supervise.sh did not start the tick agent when there is genuinely none: $out"

echo "==> a registry that is not JSON at all is still unreadable"
out="$(supervise "$(stub_claude 'not json' garbage)")"
grep -q "could not read the agent registry" <<<"$out" \
  || fail "unparseable registry was not reported as unreadable: $out"

echo "PASS"
