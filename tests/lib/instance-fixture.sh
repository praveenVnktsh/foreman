#!/usr/bin/env bash
# A minimal FOREMAN_INSTANCE environment for tests that reach config.sh --
# directly, by sourcing a skill script, or indirectly, through reconcile.py or
# preflight.py shelling out to it at import/load time. Since Task 2/3, none of
# those will run at all without FOREMAN_INSTANCE set and an instance directory
# present under some HOME, and the target REPO's board.toml has to satisfy
# bin/contract.py before anything downstream is reached.
#
# Shared because four tests independently need exactly this scaffolding:
# test-board-deploy-outcomes.sh, test-evidence-reads-are-fresh.sh,
# test-preflight-fetches-only-to-gate.sh and
# test-sweep-reaps-leaked-evidence-refs.sh. None of them are testing the
# instance/contract loaders themselves -- test-config-resolves-instance.sh and
# test-contract.sh already do -- so this exists to stand the loaders up
# quickly and get out of the way of what each test actually asserts.

# fixture_board_toml <dir>
# Writes the smallest board.toml bin/contract.py will accept into
# <dir>/board.toml. Every field here satisfies a REQUIRED key; none of it is
# asserted on by any of this helper's callers, which replace or bypass the
# systems that would otherwise read these values.
fixture_board_toml() {
  local dir="$1"
  cat > "$dir/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "fixture"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[deploy]
workflow = "deploy.yml"
step = "Deploy and verify"
[test]
command = "true"
TOML
}

# fixture_add_board <home> <name> [repo_dir]
# Declares board <name> in <home>/.foreman/boards.toml and creates its runtime
# directory, so config.sh stops refusing to load.
#
# A board used to be a directory holding instance.env. It is now a table in one
# file, and the runtime directory holds only cards/, HALT and the ids cache. A
# fixture that still writes instance.env produces the failure every test in this
# suite hit at once: "boards: no board declarations", from a loader that is
# correct and a fixture that is stale.
#
# APPENDS rather than truncates. Several callers declare two boards to prove
# they stay separated on a shared repository, and a fixture that rewrote the file
# per board would silently leave only the last one.
#
# <repo_dir> is optional for the same reason it always was: an explicit
# environment REPO wins over the declared one, because config.sh reads with `-`
# and not `:-`. A board with no repo_dir gets the caller's own directory, since
# boards.py refuses a repo that is not a directory -- refusing rather than
# degrading, which is what that loader is for.
fixture_add_board() {
  local home="$1" name="$2" repo_dir="${3:-$home}"
  local fh="$home/.foreman"
  mkdir -p "$fh/instances/$name"
  # One credential per workspace, at the foreman root. It used to be copied into
  # every instance directory.
  [[ -f "$fh/linear.key" ]] || printf 'fixture-key\n' > "$fh/linear.key"
  chmod 600 "$fh/linear.key"
  printf '[boards.%s]\nrepo = "%s"\n' "$name" "$repo_dir" >> "$fh/boards.toml"
}

# Kept so a caller written against the old name still works while the tests that
# use it are updated. It is the same fixture; only the layout underneath moved.
fixture_add_instance() { fixture_add_board "$@"; }
