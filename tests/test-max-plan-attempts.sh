#!/usr/bin/env bash
# MAX_PLAN_ATTEMPTS has a default of 2, an environment override reaches it,
# and PLAN_DIR is gone -- config.sh no longer exports a path for a plan that
# is never pushed to git.
#
# MAX_PLAN_ATTEMPTS counts failed plan ATTEMPTS (the agent dies, times out, or
# never posts a valid plan comment), separate from MAX_PLAN_ROUNDS (an
# operator revising a plan already posted). Sharing MAX_BUILD_ATTEMPTS's
# counter with plan failures would let a card that could not be planned reach
# the build stage with its build budget already spent -- this cap exists so
# that never happens. See skills/board/config.sh for the full reasoning.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi }
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1"; fail=1; }

target="$work/target"; mkdir -p "$target"; git -C "$target" init -q -b main
cat >"$target/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML

home="$work/home"; mkdir -p "$home"
cat >"$home/boards.toml" <<TOML
[boards.demo]
repo = "$target"
TOML

ask() { # VAR [env assignments...]
  local var="$1"; shift
  env FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo "$@" \
    bash -c ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$$var\""
}

check "MAX_PLAN_ATTEMPTS defaults to 2" "2" "$(ask MAX_PLAN_ATTEMPTS)"
check "an override reaches MAX_PLAN_ATTEMPTS" "5" \
  "$(ask MAX_PLAN_ATTEMPTS MAX_PLAN_ATTEMPTS=5)"

# `:-`, not `-`: unlike HIGH_RISK_PATHS or PLAN_MODEL, an explicitly empty
# MAX_PLAN_ATTEMPTS has no "disabled" meaning to reach through -- it is a
# numeric cap like HOST_MAX_CONCURRENT, so an explicit empty override falls
# back to the default rather than passing through as empty.
check "an explicitly empty MAX_PLAN_ATTEMPTS falls back to the default (not -)" \
  "2" "$(ask MAX_PLAN_ATTEMPTS MAX_PLAN_ATTEMPTS=)"

# PLAN_DIR named the path a build agent used to push its plan into, under git.
# No plan is pushed any more -- it is posted to the Linear card instead -- so
# the variable must be gone entirely, not merely empty. A leftover empty
# PLAN_DIR would still read as "config.sh has an opinion about this path" to
# anyone grepping the environment it exports.
plan_dir_value="$(ask PLAN_DIR)"
if [[ -z "$plan_dir_value" ]]; then
  ok "PLAN_DIR is gone (unset, not merely empty)"
else
  not_ok "PLAN_DIR still resolves to a value: $plan_dir_value"
fi
if grep -q 'PLAN_DIR' "$root/skills/board/config.sh"; then
  not_ok "config.sh still mentions PLAN_DIR"
else
  ok "config.sh no longer mentions PLAN_DIR"
fi

exit "$fail"
