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
selection_step = "Choose the revision to deploy"
fast_track_label = "fast-track"
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
check "unset limit falls back"          "1" "$(read_key "$work/full.toml" MAX_REVIEW_ROUNDS)"
check "reviewers_per_round defaults to 1" "1" "$(read_key "$work/full.toml" REVIEWERS_PER_ROUND)"
check "deploy selection_step loads"     "Choose the revision to deploy" "$(read_key "$work/full.toml" DEPLOY_SELECTION_STEP)"
check "deploy fast_track_label loads"   "fast-track" "$(read_key "$work/full.toml" FAST_TRACK_LABEL)"

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
check "absent deploy selection_step is empty, not missing" "" "$(read_key "$work/nodeploy.toml" DEPLOY_SELECTION_STEP)"
check "absent deploy fast_track_label is empty, not missing" "" "$(read_key "$work/nodeploy.toml" FAST_TRACK_LABEL)"

# An existing target's [deploy] table -- workflow and step set, but written
# before selection_step existed -- must keep reading exactly as it always
# has: the new key defaults to empty rather than making the whole table
# fail to load or fall back to some other default.
cat >"$work/deploynoselection.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[deploy]
workflow = "deploy.yml"
step = "Deploy and verify"
[test]
command = "make test"
TOML
check "a [deploy] table written before selection_step existed still reads empty for it" \
  "" "$(read_key "$work/deploynoselection.toml" DEPLOY_SELECTION_STEP)"
check "a [deploy] table written before fast_track_label existed still reads empty for it" \
  "" "$(read_key "$work/deploynoselection.toml" FAST_TRACK_LABEL)"

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

# fast_track_label round-trips through `gh pr edit --add-label`, which splits
# its argument on commas -- a comma in the value would silently add a
# different label (or several) than the one written here.
cat >"$work/fasttrackcomma.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[deploy]
fast_track_label = "fast,track"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/fasttrackcomma.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL a comma in deploy.fast_track_label must be refused\n'; fail=1
else
  case "$err" in *deploy.fast_track_label*) printf 'ok   comma in fast_track_label is refused\n' ;;
    *) printf 'FAIL error did not name deploy.fast_track_label: %s\n' "$err"; fail=1 ;; esac
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

cat >"$work/labelchars.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_label_chars = 96
TOML
check "max_label_chars round-trips" "96" "$(read_key "$work/labelchars.toml" MAX_LABEL_CHARS)"

# A target that declares no [limits] table at all -- not even an empty one --
# must still get bin/contract.py's own default, the same as every other key
# in LIMITS.
cat >"$work/nolimits.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
check "no [limits] table at all still yields the max_label_chars default" \
  "80" "$(read_key "$work/nolimits.toml" MAX_LABEL_CHARS)"

# Junk is refused, naming the key. A contract that says less than its author
# thought, and says it with exit code 0, is what this loader exists to
# prevent -- a string or a negative number must not silently become a plan
# checker running on the wrong budget.
cat >"$work/labelchars_string.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_label_chars = "96"
TOML
if err="$("$root/bin/contract.py" "$work/labelchars_string.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL max_label_chars = "96" (a string) must be refused\n'; fail=1
else
  case "$err" in *max_label_chars*) printf 'ok   max_label_chars as a string is refused\n' ;;
    *) printf 'FAIL error did not name max_label_chars: %s\n' "$err"; fail=1 ;; esac
fi

cat >"$work/labelchars_negative.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_label_chars = -1
TOML
if err="$("$root/bin/contract.py" "$work/labelchars_negative.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL max_label_chars = -1 must be refused\n'; fail=1
else
  case "$err" in *max_label_chars*) printf 'ok   negative max_label_chars is refused\n' ;;
    *) printf 'FAIL error did not name max_label_chars: %s\n' "$err"; fail=1 ;; esac
fi

# max_label_chars = 0 LOADS. It is deliberately absent from LIMIT_MINIMUMS:
# zero refuses every label, which starves planning loudly -- the card idles
# unplanned -- unlike max_review_rounds = 0, which disarms the review gate and
# lets an unreviewed diff merge. Same shape as the max_concurrent = 0 case
# above: a limit whose zero only starves work, rather than skipping a check,
# is a legitimate operator choice and must still load.
cat >"$work/zero_labelchars.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_label_chars = 0
TOML
check "max_label_chars = 0 still loads (starves planning, disarms nothing)" \
  "0" "$(read_key "$work/zero_labelchars.toml" MAX_LABEL_CHARS)"

# The default of 80 is written twice on purpose -- bin/contract.py's LIMITS
# and bin/check-plan-graph.py's Budget.label_chars cannot import each
# other -- so this pins the two together instead of retyping either number.
# If they drift, a target that declares no [limits] gets a plan judged
# against one number by check-plan-graph.py while the prompt that told it to
# write within budget named the other. The number here comes from
# check-plan-graph.py's own --limits sentence, not from a copy typed in this
# file: a test that retypes either number would stay green while the two
# drifted, which is the defect this case exists to catch.
# `[0-9][0-9]*` and not `[0-9]\+`: BSD sed reads `\+` as a literal plus, so
# the substitution matched nothing, `plan_default` came back empty, and this
# case compared "" against 80 on every macOS run while CI's GNU sed passed.
plan_default="$(python3 "$root/bin/check-plan-graph.py" --limits |
  sed -n 's/.*at most \([0-9][0-9]*\) characters.*/\1/p')"
check "check-plan-graph.py's default agrees with contract.py's MAX_LABEL_CHARS default" \
  "$plan_default" "$(read_key "$work/nolimits.toml" MAX_LABEL_CHARS)"

# A fully-specified [cleanup] table round-trips all three keys.
cat >"$work/cleanup.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
every_days = 5
model = "opus"
max_plan_nodes = 12
TOML
check "cleanup.every_days round-trips"      "5"    "$(read_key "$work/cleanup.toml" CLEANUP_EVERY_DAYS)"
check "cleanup.model round-trips"           "opus" "$(read_key "$work/cleanup.toml" CLEANUP_MODEL)"
check "cleanup.max_plan_nodes round-trips"  "12"   "$(read_key "$work/cleanup.toml" CLEANUP_MAX_PLAN_NODES)"

# A board with no [cleanup] table at all still gets cleanup ON by default:
# every_days=3, an empty (not missing) model, and max_plan_nodes=8.
check "no [cleanup] table defaults every_days to 3"      "3"  "$(read_key "$work/nolimits.toml" CLEANUP_EVERY_DAYS)"
check "no [cleanup] table defaults model to empty, not missing" "" "$(read_key "$work/nolimits.toml" CLEANUP_MODEL)"
check "no [cleanup] table defaults max_plan_nodes to 8"  "8"  "$(read_key "$work/nolimits.toml" CLEANUP_MAX_PLAN_NODES)"

# every_days = 0 is the operator's explicit off switch, not a refusal.
cat >"$work/cleanupoff.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
every_days = 0
TOML
check "cleanup.every_days = 0 loads (cleanup off)" "0" "$(read_key "$work/cleanupoff.toml" CLEANUP_EVERY_DAYS)"

# Negative values are refused, naming the key -- same shape as every other
# integer this loader validates.
cat >"$work/cleanupnegative.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
every_days = -1
max_plan_nodes = -1
TOML
if err="$("$root/bin/contract.py" "$work/cleanupnegative.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL cleanup.every_days = -1 must be refused\n'; fail=1
else
  case "$err" in *every_days*) printf 'ok   negative cleanup.every_days is refused, naming the key\n' ;;
    *) printf 'FAIL error did not name every_days: %s\n' "$err"; fail=1 ;; esac
fi

# A string where an integer is required is refused, naming the key -- a
# quoted "3" must not silently become the string "3" surviving as an int.
cat >"$work/cleanupstring.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
every_days = "3"
TOML
if err="$("$root/bin/contract.py" "$work/cleanupstring.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL cleanup.every_days = "3" (a string) must be refused\n'; fail=1
else
  case "$err" in *every_days*) printf 'ok   cleanup.every_days as a string is refused\n' ;;
    *) printf 'FAIL error did not name every_days: %s\n' "$err"; fail=1 ;; esac
fi

# [limits] max_followups is deprecated, not refused: the contract still
# loads and MAX_FOLLOWUPS is gone from the emitted pairs -- an existing
# board.toml written before this change must keep loading.
cat >"$work/maxfollowups.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_followups = 3
TOML

# Finding 3 (this round): the deprecation warning used to fire
# unconditionally, so a board that still sets the key printed it on every
# dispatch, sweep, evidence.sh call and reconcile.py query -- dozens of times
# a tick, none of them redirected by load-pairs.sh. A warning that fires that
# often is one nobody reads. It is still a warning (the contract below still
# loads), but now fires only when stderr is a terminal -- this test harness
# captures stderr through command substitution, which is never a tty, so the
# warning must be silent here.
if err="$("$root/bin/contract.py" "$work/maxfollowups.toml" 2>&1 >/dev/null)"; then
  if [[ -z "$err" ]]; then
    printf 'ok   limits.max_followups does not warn when stderr is not a terminal\n'
  else
    printf 'FAIL limits.max_followups warned even though stderr is not a terminal: %s\n' "$err"; fail=1
  fi
else
  printf 'FAIL limits.max_followups must not refuse the contract\n'; fail=1
fi
check "MAX_FOLLOWUPS is gone from the emitted pairs" "<missing>" "$(read_key "$work/maxfollowups.toml" MAX_FOLLOWUPS)"

# The warning must still reach the one reader who can see it: an operator
# running contract.py by hand at an interactive terminal. python3's pty module
# gives the subprocess a real tty on stderr, so isatty() reports True inside
# it exactly as it would for a human at a shell -- this is the positive half
# of the firing rule; the block above is the negative half.
tty_stderr="$(python3 -c '
import os, pty, subprocess, sys
master, slave = pty.openpty()
proc = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=slave)
os.close(slave)
# Read to EOF BEFORE reaping the child, not after: waiting first let the
# kernel tear the pty down on macOS once the child (the only remaining
# holder of the slave fd) exited, and the buffered warning was gone by the
# time this script got around to reading it -- os.read() came back b""
# even though the child had written and flushed the line.
chunks = []
while True:
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    chunks.append(chunk)
os.close(master)
proc.wait()
sys.stdout.buffer.write(b"".join(chunks))
' "$root/bin/contract.py" "$work/maxfollowups.toml")"
case "$tty_stderr" in *max_followups*) printf 'ok   limits.max_followups still warns when stderr is a terminal\n' ;;
  *) printf 'FAIL warning did not fire with a tty stderr: %s\n' "$tty_stderr"; fail=1 ;; esac

# Unknown-key rejection under [cleanup] is symmetric with every other table.
cat >"$work/cleanupunknownkey.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
every_dyas = 5
TOML
if err="$("$root/bin/contract.py" "$work/cleanupunknownkey.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL a typo'"'"'d key under [cleanup] must be refused\n'; fail=1
else
  case "$err" in *every_dyas*) printf 'ok   unknown key under [cleanup] is refused\n' ;;
    *) printf 'FAIL error did not name every_dyas: %s\n' "$err"; fail=1 ;; esac
fi

# Finding 1 (this round): `dig_checked(...) or {}` ran the `or {}` BEFORE the
# isinstance check that follows it, so a FALSY wrong-typed ancestor --
# `false`, `0`, `""`, `[]` are all falsy in Python -- turned into {} first and
# never reached the check at all. `risk = "high"` (truthy) was already
# refused above; `limits = false` and `cleanup = 0` loaded silently with
# every default instead, which is the identical "wrong-typed ancestor" case
# this module's docstring already claims is a die(). Only genuine absence
# (the key missing) may default; every other type must die, naming the table.
check_falsy_wrongtype() { # table  toml_value  label
  local table="$1" value="$2" label="$3"
  local f="$work/falsy_${table}_${label}.toml"
  # The assignment must come BEFORE any [table] header: TOML attaches a bare
  # `key = value` line to whichever table was most recently opened, so one
  # written after [test] would set test.limits, not the top-level ancestor
  # this case means to test. `risk = "high"` above uses the same placement.
  cat >"$f" <<TOML
${table} = ${value}
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
  if err="$("$root/bin/contract.py" "$f" 2>&1 >/dev/null)"; then
    printf 'FAIL %s = %s (falsy, wrong type) must be refused\n' "$table" "$value"; fail=1
  else
    case "$err" in *"$table"*) printf 'ok   %s = %s (falsy, wrong type) is refused\n' "$table" "$value" ;;
      *) printf 'FAIL error did not name %s: %s\n' "$table" "$err"; fail=1 ;; esac
  fi
}
check_falsy_wrongtype limits false false
check_falsy_wrongtype limits 0 zero
check_falsy_wrongtype limits '""' emptystr
check_falsy_wrongtype limits '[]' emptylist
check_falsy_wrongtype cleanup false false
check_falsy_wrongtype cleanup 0 zero
check_falsy_wrongtype cleanup '""' emptystr
check_falsy_wrongtype cleanup '[]' emptylist

# Finding 2 (this round): cleanup.model was checked for str and for NUL, but
# not for emptiness, so "   " (whitespace only) is non-empty by that check
# and used to survive. config.sh's `CLEANUP_MODEL="${CLEANUP_MODEL:-$PLAN_MODEL}"`
# only falls back to PLAN_MODEL on a truly empty value, so dispatch.sh would
# hand the adapter `--model "   "`. codex and opencode do not refuse a wrong
# model at spawn time (see bin/installation.py's resolve_models): the agent
# dies inside its own log, the card never moves, and the cleanup stamp is
# already written, so the board would repeat this silently every
# every_days with nothing in Linear to diagnose. Refuse it here instead,
# naming the key the way installation.py names a stage model.
cat >"$work/cleanupmodelwhitespace.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
model = "   "
TOML
if err="$("$root/bin/contract.py" "$work/cleanupmodelwhitespace.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL cleanup.model = "   " (whitespace only) must be refused\n'; fail=1
else
  case "$err" in *cleanup.model*) printf 'ok   whitespace-only cleanup.model is refused, naming the key\n' ;;
    *) printf 'FAIL error did not name cleanup.model: %s\n' "$err"; fail=1 ;; esac
fi

# An explicit empty string is the documented "no override" spelling (see
# CLEANUP_MODEL's default above) and must keep round-tripping as empty, not
# regress into a refusal alongside the whitespace case above.
cat >"$work/cleanupmodelempty.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
model = ""
TOML
check "explicit empty cleanup.model still round-trips as no override" \
  "" "$(read_key "$work/cleanupmodelempty.toml" CLEANUP_MODEL)"

exit "$fail"
