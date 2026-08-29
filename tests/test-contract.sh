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

# Task 6 (decisions §2): MIN_FREE_TMP_MB, MIN_FREE_REPO_MB, PROBE_TMP_MB,
# PROBE_REPO_MB and QUICK_PROBE_MB were added to LIMITS alongside the
# originals above -- but the review round 1 that shipped them only ever
# exercised quick_probe_mb (through test-host-ceiling.sh, indirectly, via
# preflight.py). Setting all five together, distinctly, is what proves each
# one individually reaches config.sh's shell variable of the same name rather
# than one of the five silently aliasing another or falling back to its
# default while the test happened to not notice.
cat >"$work/allprobes.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
min_free_tmp_mb = 111
min_free_repo_mb = 222
probe_tmp_mb = 333
probe_repo_mb = 444
quick_probe_mb = 555
TOML
check "min_free_tmp_mb round-trips"  "111" "$(read_key "$work/allprobes.toml" MIN_FREE_TMP_MB)"
check "min_free_repo_mb round-trips" "222" "$(read_key "$work/allprobes.toml" MIN_FREE_REPO_MB)"
check "probe_tmp_mb round-trips"     "333" "$(read_key "$work/allprobes.toml" PROBE_TMP_MB)"
check "probe_repo_mb round-trips"    "444" "$(read_key "$work/allprobes.toml" PROBE_REPO_MB)"
check "quick_probe_mb round-trips"   "555" "$(read_key "$work/allprobes.toml" QUICK_PROBE_MB)"
# And the contract must still load at all with every one of the five set --
# decisions §2's literal ask ("a test that a contract setting every one of
# the five loads successfully").
"$root/bin/contract.py" "$work/allprobes.toml" >/dev/null ||
  { printf 'FAIL a contract setting all five new limit keys failed to load\n'; fail=1; }
check "unset limits (min_free_tmp_mb etc) still fall back to their own defaults" \
  "128" "$(read_key "$work/full.toml" MIN_FREE_TMP_MB)"

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

# Finding 1: an empty string must not silently satisfy "required". A build
# agent with no test command reports success from having written no code --
# that's the failure `test.command` exists to prevent, and `command = ""`
# must not be a backdoor around it.
cat >"$work/emptyscalar.toml" <<'TOML'
[linear]
team = ""
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/emptyscalar.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL an empty required scalar must be refused\n'; fail=1
else
  case "$err" in *linear.team*) printf 'ok   empty required scalar is refused\n' ;;
    *) printf 'FAIL error did not name linear.team: %s\n' "$err"; fail=1 ;; esac
fi

cat >"$work/emptylistentry.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = [""]
ci_workflow = "CI"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/emptylistentry.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL an empty entry in a required list must be refused\n'; fail=1
else
  case "$err" in *checks.required*) printf 'ok   empty entry in required list is refused\n' ;;
    *) printf 'FAIL error did not name checks.required: %s\n' "$err"; fail=1 ;; esac
fi

# Finding 2: dig() must not conflate "absent" with "wrong type at an
# ancestor". `risk = "high"` is a typo for the `[risk]` table, not a
# statement that nothing is high risk -- it must be refused, not silently
# read as "no risk paths configured".
cat >"$work/wrongtype.toml" <<'TOML'
risk = "high"
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/wrongtype.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL a non-table ancestor (risk = "high") must be refused\n'; fail=1
else
  case "$err" in *risk*) printf 'ok   non-table ancestor is refused, naming it\n' ;;
    *) printf 'FAIL error did not name risk: %s\n' "$err"; fail=1 ;; esac
fi

# Finding 3: unknown-key rejection must be symmetric. `[limits]` already
# rejects a typo'd key; the identical mistake under any other table
# (here `[bootstrap]`) must not be silently swallowed to the empty default.
cat >"$work/unknownkey.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[bootstrap]
commnad = "uv sync"
TOML
if err="$("$root/bin/contract.py" "$work/unknownkey.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL a typo'"'"'d key under [bootstrap] must be refused\n'; fail=1
else
  case "$err" in *commnad*) printf 'ok   unknown key under a non-limits table is refused\n' ;;
    *) printf 'FAIL error did not name commnad: %s\n' "$err"; fail=1 ;; esac
fi

# Finding 3, other half: an unknown table at the top level must be refused
# too, not just an unknown key inside a known one.
cat >"$work/unknowntable.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[bogus]
x = 1
TOML
if err="$("$root/bin/contract.py" "$work/unknowntable.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL an unknown top-level table must be refused\n'; fail=1
else
  case "$err" in *bogus*) printf 'ok   unknown top-level table is refused\n' ;;
    *) printf 'FAIL error did not name bogus: %s\n' "$err"; fail=1 ;; esac
fi

# Finding 4: a value containing an embedded NUL desynchronizes the
# NUL-separated wire format -- valid TOML can produce one via a \u0000
# escape. A NUL cannot survive as a shell value anyway (C strings terminate
# at it), so the loader refuses the contract outright rather than emitting a
# stream a consumer would misparse.
cat >"$work/nulvalue.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make\u0000test"
TOML
if err="$("$root/bin/contract.py" "$work/nulvalue.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL a value containing an embedded NUL must be refused\n'; fail=1
else
  case "$err" in *NUL*) printf 'ok   embedded NUL byte in a value is refused\n' ;;
    *) printf 'FAIL error did not mention NUL: %s\n' "$err"; fail=1 ;; esac
fi

# A target cannot disarm the adversarial review gate with a zero. Before this,
# the only bound on any [limits] entry was `value < 0`, so
# `reviewers_per_round = 0` and `max_review_rounds = 0` loaded cleanly --
# SKILL.md then dispatches zero reviewers and merges on "no blocking
# findings". Both must now be refused outright.
cat >"$work/zero_reviewers.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
reviewers_per_round = 0
TOML
if err="$("$root/bin/contract.py" "$work/zero_reviewers.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL reviewers_per_round = 0 must be refused (it disarms the review gate)\n'; fail=1
else
  case "$err" in *reviewers_per_round*) printf 'ok   reviewers_per_round = 0 is refused\n' ;;
    *) printf 'FAIL error did not name reviewers_per_round: %s\n' "$err"; fail=1 ;; esac
fi

cat >"$work/zero_rounds.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_review_rounds = 0
TOML
if err="$("$root/bin/contract.py" "$work/zero_rounds.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL max_review_rounds = 0 must be refused (it disarms the review gate)\n'; fail=1
else
  case "$err" in *max_review_rounds*) printf 'ok   max_review_rounds = 0 is refused\n' ;;
    *) printf 'FAIL error did not name max_review_rounds: %s\n' "$err"; fail=1 ;; esac
fi

# The floor is scoped to the two review-gate limits, not every limit. Zero is
# still a legitimate value for MAX_CONCURRENT (starves dispatch, merges
# nothing unreviewed) and every other [limits] entry.
cat >"$work/zero_concurrent.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_concurrent = 0
TOML
check "max_concurrent = 0 still loads (not a review-gate limit)" \
  "0" "$(read_key "$work/zero_concurrent.toml" MAX_CONCURRENT)"

# A negative value is refused for a review-gate limit too, with the
# gate-specific message rather than the generic "non-negative integer" one.
cat >"$work/negative_rounds.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_review_rounds = -1
TOML
if err="$("$root/bin/contract.py" "$work/negative_rounds.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL max_review_rounds = -1 must be refused\n'; fail=1
else
  case "$err" in *max_review_rounds*) printf 'ok   max_review_rounds = -1 is refused\n' ;;
    *) printf 'FAIL error did not name max_review_rounds: %s\n' "$err"; fail=1 ;; esac
fi

exit "$fail"
