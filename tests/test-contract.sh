#!/usr/bin/env bash
# The contract is data. It is parsed, never sourced, and a contract that tries
# to be shell is inert rather than clever.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}
read_key() { # file key
  "$root/bin/contract.py" "$1" | python3 -c '
import sys
v = sys.stdin.buffer.read().split(b"\0")
d = dict(zip(v[::2], v[1::2]))
sys.stdout.write(d.get(sys.argv[1].encode(), b"<missing>").decode())
' "$2"
}

cat >"$work/full.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests", "Lint"]
ci_workflow = "CI"
[deploy]
workflow = "deploy.yml"
step = "Deploy and verify"
[risk]
paths = ["migrations/"]
[test]
command = "make test"
[bootstrap]
command = "uv sync"
[docs]
required = ["ENGINEERING.md"]
[limits]
max_concurrent = 2
TOML

check "required checks are pipe-joined" "Tests|Lint" "$(read_key "$work/full.toml" REQUIRED_CHECKS)"
check "risk paths are space-joined"     "migrations/" "$(read_key "$work/full.toml" HIGH_RISK_PATHS)"
check "test command"                    "make test" "$(read_key "$work/full.toml" TEST_COMMAND)"
check "limits are upper-cased"          "2" "$(read_key "$work/full.toml" MAX_CONCURRENT)"
check "unset limit falls back"          "2" "$(read_key "$work/full.toml" MAX_REVIEW_ROUNDS)"

# A target with no deployment. `deploy` absent means merged is done, and the
# keys must still be EMITTED empty -- a consumer detects failure by counting
# fields, so an omitted key reads as a config that would not load.
cat >"$work/nodeploy.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
check "absent deploy workflow is empty, not missing" "" "$(read_key "$work/nodeploy.toml" DEPLOY_WORKFLOW)"
check "absent deploy step is empty, not missing"     "" "$(read_key "$work/nodeploy.toml" DEPLOY_STEP)"

# An explicitly empty risk list means NOTHING is high risk. It must not fall
# back to a default -- the same distinction `HIGH_RISK_PATHS` uses `-` for.
cat >"$work/norisk.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[risk]
paths = []
[test]
command = "make test"
TOML
check "empty risk list stays empty" "" "$(read_key "$work/norisk.toml" HIGH_RISK_PATHS)"

# A missing REQUIRED key names itself. Merging with no required checks would
# merge a diff nothing tested.
cat >"$work/bad.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
ci_workflow = "CI"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/bad.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL missing checks.required must fail\n'; fail=1
else
  case "$err" in *checks.required*) printf 'ok   missing key names itself\n' ;;
    *) printf 'FAIL error did not name checks.required: %s\n' "$err"; fail=1 ;; esac
fi

# The contract is DATA. Shell in a value is a string.
cat >"$work/evil.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "$(touch /tmp/foreman-pwned) `touch /tmp/foreman-pwned2`"
TOML
rm -f /tmp/foreman-pwned /tmp/foreman-pwned2
read_key "$work/evil.toml" TEST_COMMAND >/dev/null
if [[ -e /tmp/foreman-pwned || -e /tmp/foreman-pwned2 ]]; then
  printf 'FAIL loading a contract executed shell from it\n'; fail=1
else
  printf 'ok   contract values are inert\n'
fi

exit "$fail"
