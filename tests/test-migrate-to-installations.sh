#!/usr/bin/env bash
# Claim: "Migration" in
# docs/specs/2026-09-14-installations-per-harness-design.md, `boardctl
# migrate`'s second step. A pre-installations home holds install/,
# boards.toml and instances/ directly under $FOREMAN_HOME. `migrate` moves
# all three under $FOREMAN_HOME/claude/ and writes installation.toml there
# with harness claude and default true -- exactly the record
# bin/installation.py already made up for such a home, so migrate writes
# what the home already reported. A second run is a no-op that says so. A
# live foreman/ agent in the Claude registry blocks the move entirely,
# because the agent's name gains an installation segment it does not carry
# yet, and a home that moved out from under it would make it invisible.
#
# The step before it must never stand in the way: a home that already ran the
# old first step keeps its boards.toml AND its instances/*/instance.env files,
# and both leftovers are what the first step's own instruction leaves behind.
# It reports itself a no-op there, so the move below is still reachable.
#
# Every real script here runs FOR REAL: this builds a farm at a temporary
# HOME that copies this repository's bin/ and skills/ so bin/boardctl,
# bin/installation.py and skills/board/harness/claude.sh are the actual
# files, not a rewritten stand-in. The only stub is `claude` itself, on
# PATH, answering `agents --json --all` -- the one external boundary
# `skills/board/harness/claude.sh` crosses.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
# -P: macOS's /tmp is a symlink to /private/tmp, and installation.py resolves
# a clone's path with os.path.realpath. Comparing against the un-resolved
# mktemp path would fail every check below for a reason that has nothing to
# do with the code under test.
work_dir="$(cd -- "$work_dir" && pwd -P)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
fail_hard() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# stub_claude_dir <dir> <agents-json> -- a PATH directory holding a `claude`
# that answers `agents --json --all` with <agents-json> and refuses any other
# invocation this test never needs. skills/board/harness/claude.sh is the
# only caller migrate reaches for, and it calls exactly this one subcommand.
stub_claude_dir() {
  local dir="$1" agents_json="$2"
  mkdir -p "$dir"
  cat > "$dir/claude" <<EOF
#!/usr/bin/env bash
case "\$1" in
  agents)
    cat <<'JSON'
$agents_json
JSON
    ;;
  *)
    echo "stub claude: unsupported invocation: \$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/claude"
}

# make_farm <op_dir> -- builds a pre-installations layout at
# <op_dir>/.foreman: install/ is a real copy of this repository's bin/ and
# skills/ (a symlink farm would work too; a copy is simpler and just as
# real, since neither directory is written to by anything this test runs),
# plus boards.toml and one board's runtime directory. Returns the new
# FOREMAN_HOME via the global `farm_home`.
make_farm() {
  local op_dir="$1"
  farm_home="$op_dir/.foreman"
  local install="$farm_home/install"
  mkdir -p "$install"
  cp -R "$repo_root/bin" "$install/bin"
  cp -R "$repo_root/skills" "$install/skills"

  local target; target="$(mktemp -d "$work_dir/target.XXXXXX")"
  fixture_board_toml "$target"
  cat > "$farm_home/boards.toml" <<TOML
[boards.demo]
repo = "$target"
TOML
  mkdir -p "$farm_home/instances/demo/cards"
  printf 'a card\n' > "$farm_home/instances/demo/cards/PRA-1.json"
}

# run_migrate <op_dir> <stub_dir> -- boardctl migrate, from the farm's own
# moved-in clone, with the stub claude first on PATH and FOREMAN_HOME unset
# so identity comes from the clone's path, the way install.sh and boardctl
# document it must.
run_migrate() {
  local op_dir="$1" stub_dir="$2"
  env -u FOREMAN_HOME PATH="$stub_dir:$PATH" \
    "$op_dir/.foreman/install/bin/boardctl" migrate
}

empty_registry='[]'
live_registry='[{"name":"foreman/tick","id":"a1","sessionId":"s1","pid":1,"state":"working","startedAt":1,"cwd":"/tmp","status":"ok"}]'

# =============================================================================
# Case: migrate moves install, boards.toml and instances under
# $FOREMAN_HOME/claude/, and writes installation.toml there (harness claude,
# default true)
# =============================================================================
op1="$(mktemp -d "$work_dir/op1.XXXXXX")"
make_farm "$op1"
stub1="$(mktemp -d "$work_dir/stub1.XXXXXX")"
stub_claude_dir "$stub1" "$empty_registry"

if out1="$(run_migrate "$op1" "$stub1" 2>"$work_dir/migrate1.err")"; then
  new_home="$op1/.foreman/claude"
  if [[ -d "$new_home/install/bin" ]] \
      && [[ -f "$new_home/boards.toml" ]] \
      && [[ -f "$new_home/instances/demo/cards/PRA-1.json" ]] \
      && [[ ! -e "$op1/.foreman/install" ]] \
      && [[ ! -e "$op1/.foreman/boards.toml" ]] \
      && [[ ! -e "$op1/.foreman/instances" ]] \
      && grep -qx 'harness = "claude"' "$new_home/installation.toml" \
      && grep -qx 'default = true' "$new_home/installation.toml"; then
    ok "migrate moves install, boards.toml and instances under \$FOREMAN_HOME/claude/, writing installation.toml (harness claude, default true)"
  else
    not_ok "migrate moves install, boards.toml and instances under \$FOREMAN_HOME/claude/, writing installation.toml (harness claude, default true): out=$out1 toml=$(cat "$new_home/installation.toml" 2>&1)"
  fi
else
  not_ok "migrate moves install, boards.toml and instances under \$FOREMAN_HOME/claude/, writing installation.toml (harness claude, default true): migrate failed: $(cat "$work_dir/migrate1.err")"
fi

# =============================================================================
# Case: a second migrate is a no-op that says so
#
# Run from the MOVED clone: the one at $FOREMAN_HOME/install is gone, exactly
# as boardctl's own printed next-step says -- an operator re-runs from the
# new path, not the old one.
# =============================================================================
status=0
out2="$(env -u FOREMAN_HOME PATH="$stub1:$PATH" \
  "$op1/.foreman/claude/install/bin/boardctl" migrate 2>&1)" || status=$?
if [[ $status -eq 0 ]] && [[ "$out2" == *"nothing to migrate"* ]] \
    && [[ -d "$op1/.foreman/claude/install" ]]; then
  ok "a second migrate is a no-op that says so"
else
  not_ok "a second migrate is a no-op that says so: status=$status out=$out2"
fi

# =============================================================================
# Case: a home that already ran the OLD first step still migrates
#
# The first step writes boards.toml and then tells the operator to delete the
# instances/*/instance.env files by hand. A home where those survive is the
# ordinary result of following that instruction later, or never. The first step
# used to die there -- "boards.toml already exists" -- which made every run of
# `boardctl migrate` exit 1 before cmd_migrate reached the second step, so the
# home could never be moved under <root>/claude at all. Measured in a temp farm
# on 2026-09-14.
# =============================================================================
op4="$(mktemp -d "$work_dir/op4.XXXXXX")"
make_farm "$op4"
leftover_repo="$(mktemp -d "$work_dir/leftover.XXXXXX")"
fixture_board_toml "$leftover_repo"
mkdir -p "$op4/.foreman/instances/demo"
printf 'REPO=%s\n' "$leftover_repo" > "$op4/.foreman/instances/demo/instance.env"

status=0
run_migrate "$op4" "$stub1" >"$work_dir/migrate4.out" 2>"$work_dir/migrate4.err" || status=$?
new_home4="$op4/.foreman/claude"
if [[ $status -eq 0 ]] \
    && [[ -d "$new_home4/install/bin" ]] \
    && [[ -f "$new_home4/boards.toml" ]] \
    && [[ -f "$new_home4/instances/demo/instance.env" ]] \
    && [[ -f "$new_home4/installation.toml" ]] \
    && [[ ! -e "$op4/.foreman/install" ]]; then
  ok "a farm whose boards.toml and instance.env leftovers both survive still migrates under <root>/claude"
else
  not_ok "a farm whose boards.toml and instance.env leftovers both survive still migrates under <root>/claude: status=$status out=$(cat "$work_dir/migrate4.out") err=$(cat "$work_dir/migrate4.err")"
fi

# The pre-installations watchdog outlives the move: its unit is named plain
# `foreman`, the new one `foreman-claude`, so installing the new one leaves
# both enabled and the old one fails every fire against a path that moved.
# migrate cannot disable it, so it must say so.
if grep -qi "foreman.timer\|cron line that runs" "$work_dir/migrate4.out"; then
  ok "migrate names the old watchdog as a step it cannot do itself"
else
  not_ok "migrate names the old watchdog as a step it cannot do itself: $(cat "$work_dir/migrate4.out")"
fi

# =============================================================================
# Case: migrate REFUSES and moves nothing when the registry shows a live
# foreman/ agent
# =============================================================================
op3="$(mktemp -d "$work_dir/op3.XXXXXX")"
make_farm "$op3"
stub3="$(mktemp -d "$work_dir/stub3.XXXXXX")"
stub_claude_dir "$stub3" "$live_registry"

status=0
run_migrate "$op3" "$stub3" >"$work_dir/migrate3.out" 2>"$work_dir/migrate3.err" || status=$?
if [[ $status -ne 0 ]] \
    && grep -qi "foreman/tick" "$work_dir/migrate3.err" \
    && [[ -d "$op3/.foreman/install" ]] \
    && [[ -f "$op3/.foreman/boards.toml" ]] \
    && [[ ! -e "$op3/.foreman/claude" ]]; then
  ok "migrate REFUSES and moves nothing when the registry shows a live foreman/ agent"
else
  not_ok "migrate REFUSES and moves nothing when the registry shows a live foreman/ agent: status=$status err=$(cat "$work_dir/migrate3.err") claude_dir_exists=$([[ -e "$op3/.foreman/claude" ]] && echo yes || echo no)"
fi

# =============================================================================
# Case: after migrating, bin/installation.py run from the moved install
# reports INSTALLATION claude and FOREMAN_ROOT equal to <home>/.foreman
# =============================================================================
pairs="$(mktemp)"
env -u FOREMAN_HOME "$op1/.foreman/claude/install/bin/installation.py" >"$pairs"
installation=""; foreman_root=""
while IFS= read -r -d '' key && IFS= read -r -d '' value; do
  case "$key" in
    INSTALLATION) installation="$value" ;;
    FOREMAN_ROOT) foreman_root="$value" ;;
  esac
done <"$pairs"
rm -f "$pairs"

if [[ "$installation" == "claude" ]] && [[ "$foreman_root" == "$op1/.foreman" ]]; then
  ok "after migrating, bin/installation.py run from the moved install reports INSTALLATION claude and FOREMAN_ROOT \$home/.foreman"
else
  not_ok "after migrating, bin/installation.py run from the moved install reports INSTALLATION claude and FOREMAN_ROOT \$home/.foreman: installation=$installation foreman_root=$foreman_root want_root=$op1/.foreman"
fi

# =============================================================================
# Case: after migrating, the shared Linear key is still the one at the root.
# boards.py used to join the default key against FOREMAN_HOME, which after a
# migrate is <home>/.foreman/claude -- one level below the file migrate
# deliberately leaves behind. config.sh never checks the key exists, so nothing
# refused until resolve-ids.py, on a real machine, after the move.
# =============================================================================
key_file="$(env -u FOREMAN_HOME FOREMAN_HOME="$op1/.foreman/claude" \
  "$op1/.foreman/claude/install/bin/boards.py" demo | tr '\0' '\n' | awk '/^KEY_FILE$/{getline; print}')"
if [[ "$key_file" == "$op1/.foreman/linear.key" ]]; then
  ok "after migrating, boards.py resolves the default key at the machine root, not the installation home"
else
  not_ok "after migrating, boards.py resolves the default key at the machine root, not the installation home: key_file=$key_file want=$op1/.foreman/linear.key"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
