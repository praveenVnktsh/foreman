#!/usr/bin/env bash
# `claude agents` is ONE flat registry keyed by name, shared by every instance
# on the machine. reconcile.py finds a card's agents by name prefix and
# watch-agents.py by regex, so two instances that share a prefix reap each
# other's agents -- and the ticket keys collide too, since a team key is three
# letters and two unrelated projects may both use PRA.
#
# The names below are what keeps them apart. Assert on the SEPARATION, not just
# the format: a test that only checks one instance's names passes on a regex
# that matches both. Every case here compares alpha's output against beta's.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
skill="$root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi }
check_ne() { if [[ "$2" != "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  alpha and beta produced the SAME value: %q\n' "$1" "$2"; fail=1; fi }

# Two instances, over two throwaway target repos -- the same scaffolding
# test-config-resolves-instance.sh uses, doubled.
home="$work/home"
for inst in alpha beta; do
  target="$work/target-$inst"; mkdir -p "$target"; git -C "$target" init -q -b main
  fixture_board_toml "$target"
  fixture_add_instance "$home" "$inst" "$target"
done

# ask_fn <instance> <function> <args...> -- calls a config.sh function and
# prints what it prints.
ask_fn() {
  local inst="$1" fn="$2"; shift 2
  env HOME="$home" FOREMAN_INSTANCE="$inst" \
    bash -c ". '$skill/config.sh' >/dev/null; \"\$1\" \"\${@:2}\"" _ "$fn" "$@"
}
# ask_var <instance> <VAR> [env assignments...] -- prints a config.sh variable.
ask_var() {
  local inst="$1" var="$2"; shift 2
  env HOME="$home" FOREMAN_INSTANCE="$inst" "$@" \
    bash -c ". '$skill/config.sh' >/dev/null; printf '%s' \"\$$var\""
}

build_agent_alpha="$(ask_fn alpha agent_name PRA-1 build 1)"
build_agent_beta="$(ask_fn beta agent_name PRA-1 build 1)"
tick_alpha="$(ask_var alpha TICK_AGENT_NAME)"
tick_beta="$(ask_var beta TICK_AGENT_NAME)"
worktree_alpha="$(ask_fn alpha worktree_path PRA-1)"
worktree_beta="$(ask_fn beta worktree_path PRA-1)"
branch_alpha="$(ask_fn alpha branch_name PRA-1)"
branch_beta="$(ask_fn beta branch_name PRA-1)"
evref_alpha="$(ask_fn alpha evidence_ref 12345)"
evref_beta="$(ask_fn beta evidence_ref 12345)"

check "alpha build agent has the expected shape" "foreman/alpha/PRA-1/build-1" "$build_agent_alpha"
check "beta build agent has the expected shape"  "foreman/beta/PRA-1/build-1"  "$build_agent_beta"
check "alpha tick has the expected shape" "foreman/alpha/tick" "$tick_alpha"
check "beta tick has the expected shape"  "foreman/beta/tick"  "$tick_beta"
check "alpha branch has the expected shape" "foreman/alpha/PRA-1" "$branch_alpha"
check "alpha evidence ref has the expected shape" "refs/foreman/alpha/evidence/12345" "$evref_alpha"

check_ne "alpha and beta build agents differ" "$build_agent_alpha" "$build_agent_beta"
check_ne "alpha and beta ticks differ"        "$tick_alpha"        "$tick_beta"
check_ne "alpha and beta worktrees differ"    "$worktree_alpha"    "$worktree_beta"
check_ne "alpha and beta branches differ"     "$branch_alpha"      "$branch_beta"
check_ne "alpha and beta evidence refs differ" "$evref_alpha"      "$evref_beta"

# The worktree/branch/evidence-ref checks above differ partly because alpha and
# beta point at DIFFERENT target repos -- that would be true even without an
# instance segment in the name. Force the same REPO for both asks (env wins
# over instance.env in config.sh) so the separation is provably coming from
# INSTANCE, not merely from REPO happening to differ.
shared="$work/target-alpha"
ask_fn_with_repo() { # instance repo
  local inst="$1" repo="$2"
  env HOME="$home" FOREMAN_INSTANCE="$inst" REPO="$repo" \
    bash -c ". '$skill/config.sh' >/dev/null; worktree_path PRA-1"
}
worktree_alpha_shared="$(ask_fn_with_repo alpha "$shared")"
worktree_beta_shared="$(ask_fn_with_repo beta "$shared")"
check_ne "worktrees differ by instance even under the SAME repo" \
  "$worktree_alpha_shared" "$worktree_beta_shared"

# --- the tick must never match the dispatched-agent regex, and the regex must
# --- filter on the captured instance, not just parse it. Exercised against the
# --- REAL watch-agents.py source (up to its first function), not a
# --- reimplementation of its regex, so this fails if the shipped file diverges.
watch_src="$skill/watch-agents.py"
run_watch_probe() {
  local inst="$1"
  env HOME="$home" FOREMAN_INSTANCE="$inst" python3 - "$watch_src" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
ns = {"__file__": path}
exec(src.split("\ndef poll")[0], ns)
_dispatched = ns["_dispatched"]
cases = [
    "foreman/alpha/PRA-1/build-1",
    "foreman/beta/PRA-1/build-1",
    "foreman/alpha/tick",
    "foreman/beta/tick",
    "foreman/alpha/PRA-1/review-2a",
]
print("|".join("1" if _dispatched(c) is not None else "0" for c in cases))
PY
}

watch_as_alpha="$(run_watch_probe alpha)"
watch_as_beta="$(run_watch_probe beta)"

check "watching as alpha: alpha's build agent matches"      "1" "${watch_as_alpha%%|*}"
rest="${watch_as_alpha#*|}"
check "watching as alpha: beta's build agent is filtered out" "0" "${rest%%|*}"
rest="${rest#*|}"
check "watching as alpha: alpha's own tick never matches"     "0" "${rest%%|*}"
rest="${rest#*|}"
check "watching as alpha: beta's tick never matches"          "0" "${rest%%|*}"
rest="${rest#*|}"
check "watching as alpha: alpha's review agent matches"       "1" "${rest%%|*}"

check_ne "the same agent list produces DIFFERENT matches for alpha vs. beta" \
  "$watch_as_alpha" "$watch_as_beta"

# --- reconcile.py's prefix must exclude another instance's agents, and must
# --- exclude PRA-10 when asked for PRA-1 -- the trailing slash is what makes
# --- that second case work, and it is easy to drop by accident.
run_reconcile_probe() {
  # agents (as a |-joined list of names), ticket -> |-joined matched names
  local inst="$1" agents="$2" ticket="$3"
  env HOME="$home" FOREMAN_INSTANCE="$inst" python3 - "$skill" "$agents" "$ticket" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import reconcile
agents = [{"name": n} for n in sys.argv[2].split("|") if n]
mine = reconcile.agents_for(agents, sys.argv[3])
print("|".join(sorted(a["name"] for a in mine)))
PY
}

cross_instance="$(run_reconcile_probe alpha \
  "foreman/alpha/PRA-1/build-1|foreman/beta/PRA-1/build-1" PRA-1)"
check "reconcile's prefix for alpha excludes beta's agents" \
  "foreman/alpha/PRA-1/build-1" "$cross_instance"

prefix_substring="$(run_reconcile_probe alpha \
  "foreman/alpha/PRA-1/build-1|foreman/alpha/PRA-10/build-1|foreman/alpha/PRA-11/build-1" PRA-1)"
check "reconcile's prefix for PRA-1 excludes PRA-10 and PRA-11 (prefix, not substring)" \
  "foreman/alpha/PRA-1/build-1" "$prefix_substring"

exit "$fail"
