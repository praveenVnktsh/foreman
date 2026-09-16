#!/usr/bin/env bash
# config.sh is TOLD which board it is, and reads every fact about that board
# from a declaration -- never from what happens to be on disk. Deriving REPO
# from the skill's own checkout is correct for a skill committed into the repo
# it builds and wrong for one installed once and pointed at many, and the wrong
# answer is silent: the board would cut worktrees in its own installation
# directory.
#
# ~/.foreman/boards.toml is now that declaration, and bin/boards.py is what
# reads it. The pieces this file pins:
#   - REPO and KEY_FILE come from the board's entry in boards.toml.
#   - KEY_FILE is a PATH. The key's CONTENTS never enter the calling process.
#   - ids.env is a cache. Absent is not fatal.
#   - A directory under instances/ declares nothing. Only boards.toml does.
#
# FOREMAN_HOME points at a temp directory throughout. Nothing here may read or
# write the real ~/.foreman.
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
[limits]
max_concurrent = 3
TOML

# One machine, four boards. `demo` has run before and has an ids.env cache;
# `fresh` has been declared and has never run, so it has no runtime directory
# at all; `otherws` lives in a different Linear workspace and declares its own
# credential; `target_staging` exists to prove an underscore is legal.
home="$work/home"; mkdir -p "$home"
cat >"$home/boards.toml" <<TOML
[boards.demo]
repo = "$target"

[boards.fresh]
repo = "$target"

[boards.otherws]
repo = "$target"
key = "$work/other.key"

[boards.target_staging]
repo = "$target"
TOML

inst="$home/instances/demo"; mkdir -p "$inst"
printf 'LINEAR_TEAM_ID=team-uuid\nLINEAR_PROJECT_ID=project-uuid\n' >"$inst/ids.env"

# The shared credential, one per Linear workspace. Its CONTENTS are what must
# never reach the calling process; see the leak check below.
secret='never-let-this-reach-the-environment'
printf '%s\n' "$secret" >"$home/linear.key"

ask() { # VAR [env assignments...]
  local var="$1"; shift
  env FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo "$@" \
    bash -c ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$$var\""
}
ask_board() { # BOARD VAR
  env FOREMAN_HOME="$home" FOREMAN_INSTANCE="$1" \
    bash -c ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$$2\""
}

check "REPO comes from the board declaration" "$target"     "$(ask REPO)"
check "contract reaches config"          "make test"   "$(ask TEST_COMMAND)"
check "contract limits reach config"     "3"           "$(ask MAX_CONCURRENT)"
check "ids reach config"                 "team-uuid"   "$(ask LINEAR_TEAM_ID)"
check "env beats contract"               "make fast"   "$(ask TEST_COMMAND TEST_COMMAND='make fast')"
check "env beats ids"                    "other"       "$(ask LINEAR_TEAM_ID LINEAR_TEAM_ID=other)"
# bin/resolve-ids.py scrubs REPO out of the environment before it sources this
# file, and its comment says why: because the environment wins here. If that
# stopped being true, that scrub would look like superstition and get deleted.
# A real second repository, not a bare path: the override has to survive the
# contract load that follows it, which reads $REPO/board.toml.
elsewhere="$work/elsewhere"; mkdir -p "$elsewhere"
cp "$target/board.toml" "$elsewhere/board.toml"
check "env beats the board declaration"  "$elsewhere" "$(ask REPO REPO="$elsewhere")"

# `-` and not `:-`, in EVERY loader. `env VAR=` sets VAR in the environment to
# the empty string -- it is SET, just empty. `${VAR-x}` leaves a set-but-empty
# VAR alone; `${VAR:-x}` treats set-but-empty the same as unset and falls back
# to x. Get this wrong and an operator's explicit "nothing is high risk"
# silently reinstates whatever ids.env or the contract said instead -- for
# HIGH_RISK_PATHS specifically, the difference between merging autonomously and
# parking every PR for a human. These two cases fail loudly under `:-` and pass
# under `-`; see task-3-decisions.md section 5.
check "explicit empty env beats ids (not :-)"      ""  "$(ask LINEAR_TEAM_ID LINEAR_TEAM_ID=)"
check "explicit empty env beats contract (not :-)" ""  "$(ask TEST_COMMAND TEST_COMMAND=)"

# HOST_SLOT_STALE_MINUTES is not read through a loader -- it is a plain
# `${VAR-720}` further down -- and it used to be `${VAR:-720}`, the one place
# in this file that got the `-` vs `:-` distinction backwards. config.sh's OWN
# comment above it says "Empty disables the backstop entirely", and
# reconcile.py's HOST_SLOT_STALE_MINUTES already treats an empty string as
# `None` (disabled) on its own side -- so an operator who set
# `HOST_SLOT_STALE_MINUTES=` meaning "disabled" instead silently got 720 back,
# from config.sh alone, before reconcile.py ever saw the value.
check "an explicitly empty HOST_SLOT_STALE_MINUTES stays empty (not :-)" \
  "" "$(ask HOST_SLOT_STALE_MINUTES HOST_SLOT_STALE_MINUTES=)"
check "an unset HOST_SLOT_STALE_MINUTES still falls back to 720" \
  "720" "$(ask HOST_SLOT_STALE_MINUTES)"

check "board name is exported"           "demo"        "$(ask INSTANCE)"

# An absent [cleanup] table means "same schedule and model as the plan"
# -- contract.py emits CLEANUP_MODEL="" for it, and config.sh's fallback below
# reads that empty as "inherit PLAN_MODEL", the same reading fable/fable/opus/opus
# gives the other three stage models above.
check "no [cleanup] table gives the plan's every-days default" "3" "$(ask CLEANUP_EVERY_DAYS)"
check "no [cleanup] table gives the plan's model" "$(ask PLAN_MODEL)" "$(ask CLEANUP_MODEL)"

cleanuptarget="$work/cleanuptarget"; mkdir -p "$cleanuptarget"; git -C "$cleanuptarget" init -q -b main
cat >"$cleanuptarget/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[cleanup]
model = "opus"
TOML
cleanuphome="$work/cleanuphome"; mkdir -p "$cleanuphome"
cat >"$cleanuphome/boards.toml" <<TOML
[boards.demo]
repo = "$cleanuptarget"
TOML
check "a declared [cleanup] model overrides the plan's" "opus" \
  "$(env FOREMAN_HOME="$cleanuphome" FOREMAN_INSTANCE=demo bash -c \
       ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$CLEANUP_MODEL\"")"

# The credential.
#
# One key per Linear WORKSPACE, in the machine's foreman root, replacing the
# per-board copy of one secret that had to be rotated in every board directory
# at once. A board in a different workspace names its own.
check "a board with no key of its own gets the shared credential" \
  "$home/linear.key" "$(ask KEY_FILE)"
check "a board in another workspace gets the key it declares" \
  "$work/other.key" "$(ask_board otherws KEY_FILE)"

# THE key must not enter the calling process. One tick agent now walks every
# board on this machine; if sourcing a board's config pulled that board's key
# into the environment, that one agent would hold every workspace's secret at
# once, and every subprocess it spawned would inherit them. `set` prints every
# shell variable in this shell, `env` every exported one -- the key's contents
# may appear in neither. KEY_FILE, a path, is how the subprocess that talks to
# Linear finds it.
leak="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo bash -c \
     ". '$root/skills/board/config.sh' >/dev/null; set; env" 2>&1 || true)"
if [[ "$leak" == *"$secret"* ]]; then
  not_ok "sourcing config.sh put the Linear key's contents in the environment"
else
  ok "the key's contents never enter the calling process, only its path"
fi

# An explicitly empty REPO or KEY_FILE refuses rather than degrades. boards.py
# never emits either one empty, so an environment override is the only way to
# reach this: `REPO=` would resolve every worktree path, glob and git command
# below against "/", and `KEY_FILE=` reads downstream as "use the default
# credential", which is the wrong Linear workspace for the one board that
# declares a key of its own.
for var in REPO KEY_FILE; do
  if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo "$var=" bash -c \
       ". '$root/skills/board/config.sh'" 2>&1)"; then
    not_ok "an explicitly empty $var must refuse"
  elif [[ "$err" == *"$var"* ]]; then
    ok "an explicitly empty $var refuses, naming it"
  else
    not_ok "error did not name $var: $err"
  fi
done

# REPO must NOT be the foreman checkout. This is the bug the change exists to
# prevent, so assert on it directly rather than trusting the positive case.
[[ "$(ask REPO)" != "$root" ]] && ok "REPO is not the installation" \
  || not_ok "REPO resolved to the foreman checkout"

# ids.env is a CACHE. Deleting it costs one re-resolve and never a broken
# board, so a board that has never run -- no runtime directory at all -- still
# loads. Treating its absence as fatal would make `boardctl add` followed by a
# tick fail on a board that is correctly declared.
if env FOREMAN_HOME="$home" FOREMAN_INSTANCE=fresh bash -c \
     ". '$root/skills/board/config.sh' >/dev/null"; then
  ok "a declared board with no runtime directory yet still loads"
else
  not_ok "a declared board with no runtime directory yet must still load"
fi
check "a board with no ids.env has no ids, and is not an error" \
  "" "$(ask_board fresh LINEAR_TEAM_ID)"
check "the runtime directory stays at instances/<board>" \
  "$home/instances/fresh" "$(ask_board fresh INSTANCE_HOME)"

# A directory under instances/ declares nothing. boards.toml is the only
# declaration, so runtime state left behind by a removed board must not
# resurrect it -- that board would keep dispatching against a repository the
# operator believes it no longer serves.
mkdir -p "$home/instances/ghost/cards"
if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE=ghost bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "a runtime directory with no declaration must not load"
elif [[ "$err" == *ghost* ]]; then
  ok "a runtime directory with no declaration is refused, naming the board"
else
  not_ok "error did not name the undeclared board: $err"
fi

# An unknown board fails closed and NAMES itself. Falling back to a default
# board would point a live tick at the wrong repository.
if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE=nope bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "an unknown board must fail"
else
  case "$err" in *nope*) ok "unknown board names itself" ;;
    *) not_ok "error did not name the board: $err" ;; esac
fi

# No board at all fails closed too, rather than guessing.
if env FOREMAN_HOME="$home" bash -c ". '$root/skills/board/config.sh'" 2>/dev/null; then
  not_ok "unset FOREMAN_INSTANCE must fail"
else ok "unset FOREMAN_INSTANCE fails closed"; fi

# A hyphenated board name is refused, and names itself. worktree_path and every
# worktree/scratch glob in sweep.sh join INSTANCE and the ticket with a HYPHEN
# (foreman-<instance>-<ticket>), which an unconstrained name can absorb:
# FOREMAN_INSTANCE=alpha-x would make "foreman-alpha-x-PRA-1" match the glob
# "foreman-alpha-*", so board "alpha"'s sweep would reap board "alpha-x"'s
# worktrees on a shared REPO. This never gets that far -- an invalid name is
# refused before INSTANCE_HOME, boards.toml, board.toml, or anything downstream
# is even reached.
# "invalid" is required, not just the name in the message: an UNDECLARED board
# also names itself in its own error ("no board named alpha-x"), so a
# substring-only check on the name would still pass if this regex guard were
# deleted entirely and alpha-x fell through to THAT check instead. This caught
# exactly that when first written.
if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE="alpha-x" bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "a hyphenated board name must fail"
elif [[ "$err" == *alpha-x* && "$err" == *invalid* ]]; then
  ok "hyphenated board name is refused and names itself"
else
  not_ok "error was not the invalid-name refusal: $err"
fi

# The reviewer's collision, reproduced directly and shown unreachable: without
# this guard, "alpha" and "alpha-x" would both resolve a worktree_path, and
# alpha's "foreman-alpha-*" glob would match alpha-x's worktrees too. With the
# guard, alpha-x is refused before worktree_path is ever called for it, so the
# case that used to match never gets a worktree_path to match against.
if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE="alpha-x" bash -c \
     ". '$root/skills/board/config.sh'; worktree_path PRA-1" 2>&1)"; then
  not_ok "alpha-x reached worktree_path: $err"
elif [[ "$err" == *alpha-x* && "$err" == *invalid* ]]; then
  ok "the alpha/alpha-x worktree-glob collision cannot reproduce: alpha-x never reaches worktree_path"
else
  not_ok "error was not the invalid-name refusal: $err"
fi

# A slash is refused too, for the same reason -- and underscores stay legal,
# so an operator can still write `target_staging`.
if err="$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE="alpha/x" bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "a board name containing a slash must fail"
elif [[ "$err" == *invalid* ]]; then
  ok "a board name with a slash is refused"
else
  not_ok "error was not the invalid-name refusal: $err"
fi

check "an underscore in the board name is legal" "target_staging" \
  "$(ask_board target_staging INSTANCE)"

# ONE tick walks every board, so its agent name carries no board segment. A
# per-board tick name would ask supervise.sh to keep one agent alive per board,
# and N ticks would then dispatch against one machine-wide
# HOST_MAX_CONCURRENT. The per-CARD names keep their board segment, which is
# what stops two boards reaping each other's agents, branches and worktrees.
#
# It carries no installation segment either. This home declares no
# installation.toml, so bin/installation.py reads it as the lone Claude
# installation with legacy names -- the shapes an un-migrated machine's live
# agents and open pull requests already have. The scoped shape is
# tests/test-names-carry-installation.sh.
check "the tick name carries no board segment" "foreman/tick" "$(ask TICK_AGENT_NAME)"
check "a card's agent name still carries the board" "foreman/demo/PRA-1/build-1" \
  "$(env FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo bash -c \
       ". '$root/skills/board/config.sh' >/dev/null; agent_name PRA-1 build 1")"

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
badhome="$work/badhome"; mkdir -p "$badhome"
cat >"$badhome/boards.toml" <<TOML
[boards.demo]
repo = "$badtarget"
TOML
if err="$(env FOREMAN_HOME="$badhome" FOREMAN_INSTANCE=demo bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "loader must fail when contract.py exits non-zero"
else
  if [[ -n "$err" ]]; then
    ok "loader fails loudly when contract.py fails"
  else
    not_ok "loader failed silently (no message on stderr)"
  fi
fi

# The same, one file earlier: a boards.toml that does not load must fail the
# source. Reading a refusal as "no keys" would leave REPO unset and every path
# below resolving against nothing.
brokenhome="$work/brokenhome"; mkdir -p "$brokenhome"
printf 'this is not toml =\n' >"$brokenhome/boards.toml"
if err="$(env FOREMAN_HOME="$brokenhome" FOREMAN_INSTANCE=demo bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  not_ok "loader must fail when boards.py exits non-zero"
elif [[ -n "$err" ]]; then
  ok "loader fails loudly when the board declarations do not parse"
else
  not_ok "loader failed silently (no message on stderr)"
fi

exit "$fail"
