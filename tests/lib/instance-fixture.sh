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

# fixture_add_instance <home> <name> [repo_dir]
# Ensures <home>/.foreman/instances/<name>/ exists, so config.sh stops
# refusing to load. When <repo_dir> is given, writes instance.env declaring
# REPO=<repo_dir> -- omit it when every caller overrides REPO itself, since an
# explicit environment REPO always wins over instance.env (config.sh reads
# instance.env with `-`, not `:-`, for exactly that reason).
fixture_add_instance() {
  local home="$1" name="$2" repo_dir="${3:-}"
  local inst="$home/.foreman/instances/$name"
  mkdir -p "$inst"
  [[ -z "$repo_dir" ]] || printf 'REPO=%s\n' "$repo_dir" > "$inst/instance.env"
}
