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
# LEGACY-SHAPED ON PURPOSE: no installation.toml anywhere, so <home>/.foreman is
# both the machine root and the installation home. bin/installation.py reads
# such a home as a lone Claude installation -- name `claude`, harness `claude`,
# default, no siblings -- which is exactly the layout every machine had before
# installations existed. An un-migrated home is a supported layout, and every
# test that calls this helper is what proves it still works. A test that wants
# the new layout builds it with fixture_add_installation instead.
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
  # Do NOT default repo_dir to "$home" inside this same `local` statement.
  # bash 3.2 tolerates referring to a name being declared alongside it; bash 5
  # under `set -u` calls it unbound and kills the test with no assertion having
  # run. macOS ships 3.2 and CI runs 5, so the suite was green locally and dead
  # in CI, in three tests, with no FAIL line to point at.
  local home="$1" name="$2" repo_dir="${3:-}"
  [[ -n "$repo_dir" ]] || repo_dir="$home"
  local fh="$home/.foreman"
  fixture_add_board_in "$fh" "$name" "$repo_dir"
  fixture_linear_key "$fh"
}

# Kept so a caller written against the old name still works while the tests that
# use it are updated. It is the same fixture; only the layout underneath moved.
fixture_add_instance() { fixture_add_board "$@"; }

# fixture_add_board_in <foreman_home> <name> <repo_dir>
# The same board declaration, written into a FOREMAN_HOME the caller names --
# which under the new layout is <root>/<installation>, not the root itself.
#
# <repo_dir> is required here and optional in fixture_add_board, because the
# legacy helper's default is the caller's HOME and an installation home has no
# such obvious stand-in. A helper that guessed one would hand boards.py a path
# that is not a directory, and boards.py refuses that -- correctly, and with an
# error about the target repository rather than about the fixture.
fixture_add_board_in() {
  local fh="$1" name="$2" repo_dir="$3"
  mkdir -p "$fh/instances/$name"
  # APPENDS, for the reason fixture_add_board's header gives.
  printf '[boards.%s]\nrepo = "%s"\n' "$name" "$repo_dir" >> "$fh/boards.toml"
}

# fixture_linear_key <dir>
# One credential per workspace, at the machine root. It used to be copied into
# every instance directory.
fixture_linear_key() {
  local dir="$1"
  mkdir -p "$dir"
  [[ -f "$dir/linear.key" ]] || printf 'fixture-key\n' > "$dir/linear.key"
  chmod 600 "$dir/linear.key"
}

# fixture_add_installation <home> <name> <harness> [--default]
# Creates the installation <name> under the machine root <home>/.foreman, on
# <harness>, and prints nothing. Its FOREMAN_HOME is <home>/.foreman/<name>, and
# that is where its boards go -- declare them with fixture_add_board_in.
#
# installation.toml is written through bin/installation.py --write and never by
# hand. The writer refuses a harness it has no adapter for, a name that breaks
# the name rule, and a second sibling claiming `default = true`; a fixture that
# emitted the TOML itself would build roots no loader accepts, and the test
# driving them would fail somewhere further down naming something else.
#
# Codex and OpenCode have no default models, so a placeholder is passed for all
# four stages. It is deliberately not a real model name: no test asserts on it,
# and a plausible one invites a reader to believe the fixture spends it.
fixture_add_installation() {
  local home="$1" name="$2" harness="$3" default_flag="${4:-}"
  local root="$home/.foreman"
  local install_home="$root/$name"
  local repo_root models=()
  repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  mkdir -p "$install_home"
  fixture_linear_key "$root"
  if [[ "$harness" != claude ]]; then
    models=(--model-tick stub-model --model-plan stub-model
            --model-build stub-model --model-review stub-model)
  fi
  # bash 3.2 + `set -u`: "${arr[@]}" on an EMPTY array is an unbound-variable
  # error, not an empty expansion.
  "$repo_root/bin/installation.py" --write --home "$install_home" \
    --harness "$harness" ${default_flag:+"$default_flag"} \
    ${models[@]+"${models[@]}"}
}
