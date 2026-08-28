#!/usr/bin/env bash
# config.sh is TOLD which repository it serves. Deriving it from the skill's own
# checkout is correct for a skill committed into the repo it builds and wrong
# for one installed once and pointed at many -- and the wrong answer is silent:
# the board would cut worktrees in its own installation directory.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi }

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
[limits]
max_concurrent = 3
TOML

home="$work/home"; inst="$home/.foreman/instances/demo"; mkdir -p "$inst"
printf 'REPO=%s\n' "$target" >"$inst/instance.env"
printf 'LINEAR_TEAM_ID=team-uuid\nLINEAR_PROJECT_ID=project-uuid\n' >"$inst/ids.env"

ask() { # VAR [env assignments...]
  local var="$1"; shift
  env HOME="$home" FOREMAN_INSTANCE=demo "$@" \
    bash -c ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$$var\""
}

check "REPO comes from the instance"     "$target"     "$(ask REPO)"
check "contract reaches config"          "make test"   "$(ask TEST_COMMAND)"
check "contract limits reach config"     "3"           "$(ask MAX_CONCURRENT)"
check "ids reach config"                 "team-uuid"   "$(ask LINEAR_TEAM_ID)"
check "env beats contract"               "make fast"   "$(ask TEST_COMMAND TEST_COMMAND='make fast')"
check "env beats ids"                    "other"       "$(ask LINEAR_TEAM_ID LINEAR_TEAM_ID=other)"

# `-` and not `:-`, in BOTH loaders. `env VAR=` sets VAR in the environment to
# the empty string -- it is SET, just empty. `${VAR-x}` leaves a set-but-empty
# VAR alone; `${VAR:-x}` treats set-but-empty the same as unset and falls back
# to x. Get this wrong and an operator's explicit "nothing is high risk"
# silently reinstates whatever instance.env/ids.env or the contract said
# instead -- for HIGH_RISK_PATHS specifically, the difference between merging
# autonomously and parking every PR for a human. These two cases fail loudly
# under `:-` and pass under `-`; see task-3-decisions.md section 5.
check "explicit empty env beats ids (not :-)"      ""  "$(ask LINEAR_TEAM_ID LINEAR_TEAM_ID=)"
check "explicit empty env beats contract (not :-)" ""  "$(ask TEST_COMMAND TEST_COMMAND=)"
check "instance name is exported"        "demo"        "$(ask INSTANCE)"

# REPO must NOT be the foreman checkout. This is the bug the change exists to
# prevent, so assert on it directly rather than trusting the positive case.
[[ "$(ask REPO)" != "$root" ]] && printf 'ok   REPO is not the installation\n' \
  || { printf 'FAIL REPO resolved to the foreman checkout\n'; fail=1; }

# An unknown instance fails closed and NAMES itself. Falling back to a default
# instance would point a live board at the wrong repository.
if err="$(env HOME="$home" FOREMAN_INSTANCE=nope bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  printf 'FAIL an unknown instance must fail\n'; fail=1
else
  case "$err" in *nope*) printf 'ok   unknown instance names itself\n' ;;
    *) printf 'FAIL error did not name the instance: %s\n' "$err"; fail=1 ;; esac
fi

# No instance at all fails closed too, rather than guessing.
if env HOME="$home" bash -c ". '$root/skills/board/config.sh'" 2>/dev/null; then
  printf 'FAIL unset FOREMAN_INSTANCE must fail\n'; fail=1
else printf 'ok   unset FOREMAN_INSTANCE fails closed\n'; fi

# A hyphenated instance name is refused, and names itself. worktree_path and
# every worktree/scratch glob in sweep.sh join INSTANCE and the ticket with a
# HYPHEN (foreman-<instance>-<ticket>), which an unconstrained name can
# absorb: FOREMAN_INSTANCE=alpha-x would make "foreman-alpha-x-PRA-1" match
# the glob "foreman-alpha-*", so instance "alpha"'s sweep would reap instance
# "alpha-x"'s worktrees on a shared REPO. This never gets that far -- an
# invalid instance name is refused before INSTANCE_HOME, board.toml, or
# anything downstream is even reached.
# "invalid" is required, not just the instance name in the message: a
# NONEXISTENT instance directory also names the instance in its own error
# ("no instance %s at %s"), so a substring-only check on the name would still
# pass if this regex guard were deleted entirely and alpha-x fell through to
# THAT check instead. This caught exactly that when first written.
if err="$(env HOME="$home" FOREMAN_INSTANCE="alpha-x" bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  printf 'FAIL a hyphenated instance name must fail\n'; fail=1
elif [[ "$err" == *alpha-x* && "$err" == *invalid* ]]; then
  printf 'ok   hyphenated instance name is refused and names itself\n'
else
  printf 'FAIL error was not the invalid-name refusal: %s\n' "$err"; fail=1
fi

# The reviewer's collision, reproduced directly and shown unreachable: without
# this guard, "alpha" and "alpha-x" would both resolve a worktree_path, and
# alpha's "foreman-alpha-*" glob would match alpha-x's worktrees too. With the
# guard, alpha-x is refused before worktree_path is ever called for it, so the
# case that used to match never gets a worktree_path to match against.
if err="$(env HOME="$home" FOREMAN_INSTANCE="alpha-x" bash -c \
     ". '$root/skills/board/config.sh'; worktree_path PRA-1" 2>&1)"; then
  printf 'FAIL alpha-x reached worktree_path: %s\n' "$err"; fail=1
elif [[ "$err" == *alpha-x* && "$err" == *invalid* ]]; then
  printf 'ok   the alpha/alpha-x worktree-glob collision cannot reproduce: alpha-x never reaches worktree_path\n'
else
  printf 'FAIL error was not the invalid-name refusal: %s\n' "$err"; fail=1
fi

# A slash is refused too, for the same reason -- and underscores stay legal,
# so an operator can still write `murmr_staging`.
if err="$(env HOME="$home" FOREMAN_INSTANCE="alpha/x" bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  printf 'FAIL an instance name containing a slash must fail\n'; fail=1
elif [[ "$err" == *invalid* ]]; then
  printf 'ok   an instance name with a slash is refused\n'
else
  printf 'FAIL error was not the invalid-name refusal: %s\n' "$err"; fail=1
fi

staging_inst="$home/.foreman/instances/murmr_staging"; mkdir -p "$staging_inst"
printf 'REPO=%s\n' "$target" >"$staging_inst/instance.env"
check "an underscore in the instance name is legal" "murmr_staging" \
  "$(env HOME="$home" FOREMAN_INSTANCE=murmr_staging bash -c \
       ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$INSTANCE\"")"

# A contract that does not load must fail the SOURCE too, loudly -- not
# silently continue with an empty TEST_COMMAND and REQUIRED_CHECKS. This is
# exactly the failure bash 3.2's `$(...)` NUL-eating bug would otherwise hide:
# a loader that only checks contract.py's output and not its exit status would
# read a failed load as "no keys", not "stop". See task-3-decisions.md section 1.
badtarget="$work/badtarget"; mkdir -p "$badtarget"; git -C "$badtarget" init -q -b main
cat >"$badtarget/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
ci_workflow = "CI"
[test]
command = "make test"
TOML
badhome="$work/badhome"; badinst="$badhome/.foreman/instances/demo"; mkdir -p "$badinst"
printf 'REPO=%s\n' "$badtarget" >"$badinst/instance.env"
if err="$(env HOME="$badhome" FOREMAN_INSTANCE=demo bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  printf 'FAIL loader must fail when contract.py exits non-zero\n'; fail=1
else
  if [[ -n "$err" ]]; then
    printf 'ok   loader fails loudly when contract.py fails\n'
  else
    printf 'FAIL loader failed silently (no message on stderr)\n'; fail=1
  fi
fi

exit "$fail"
