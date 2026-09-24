#!/usr/bin/env bash
# Claim: a dispatched card agent carries the board it was dispatched for in its
# own `--settings` `env`, on the spawn path and the resume path, whatever board
# the environment around it last configured.
#
# `claude --bg` does not start the session from dispatch.sh's process. It hands
# it to a pre-warmed `claude bg-spare`, whose environment was captured when an
# EARLIER spawn started it. Measured 2026-09-22 on a foreman cleanup agent: its
# environment and its parent spare both held another board's FOREMAN_INSTANCE,
# FOREMAN_CONFIG_INSTANCE and REPO, and its first evidence.sh answered from that
# board's repository. config.sh's cross-board guard agreed with the wrong answer,
# because both markers named the same stale board.
#
# The stale shell is stood in for by a second, VALID board declared beside the
# dispatching one, whose FOREMAN_CONFIG_INSTANCE, REPO and the rest of
# FOREMAN_BOARD_EXPORTS reach the real dispatch.sh. FOREMAN_INSTANCE cannot: it
# is how the dispatch is told which board it serves, so a stale one there would
# only make it serve the stale board. The spare's stale FOREMAN_INSTANCE is
# still covered, because `env` names it and a live session applies `env` over
# what the spare holds. That last step is the one thing no test here proves: it
# is the real CLI's behaviour, and this suite stubs `claude`.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

dispatch_fixture_setup "$work" "$repo_root"
prompt="$(cat "$DISPATCH_PROMPT")"
demo_repo="$work/target"

# The stale board: declared, with a repository of its own, so every value it
# leaves behind is one config.sh would have derived for a real board.
stale_repo="$work/stale-target"
mkdir -p "$stale_repo"
git -C "$stale_repo" init -q -b main
fixture_add_board "$DISPATCH_HOME" stale "$stale_repo"
stale_home="$DISPATCH_HOME/.foreman/instances/stale"
DISPATCH_INHERITED_ENV=(
  FOREMAN_CONFIG_INSTANCE=stale
  REPO="$stale_repo"
  INSTANCE=stale
  INSTANCE_HOME="$stale_home"
  BOARD_HOME="$stale_home"
  KEY_FILE="$DISPATCH_HOME/.foreman/stale.key"
  BOARD_NAME_PREFIX="stale-prefix"
  BOARD_WORKTREE_PREFIX="stale-worktree"
)

# The names the env must cover, from config.sh itself rather than a copy here.
exports="$(env -i HOME="$DISPATCH_HOME" FOREMAN_INSTANCE=demo \
  FOREMAN_HOME="$DISPATCH_HOME/.foreman" PATH="$PATH" \
  bash -c ". '$repo_root/skills/board/config.sh' >/dev/null; printf '%s' \"\$FOREMAN_BOARD_EXPORTS\"")"
[[ -n "$exports" ]] || bad "could not read FOREMAN_BOARD_EXPORTS from config.sh"

# settings_report <argv file> <prompt> <names...> -- one line per fact, each
# "key=value", read from the one `--settings` the spawn carried.
settings_report() {
  python3 - "$@" <<'PY'
import json, sys
argv_file, prompt, names = sys.argv[1], sys.argv[2], sys.argv[3:]
argv = open(argv_file).read().split("\n")[:-1]
if not argv:
    print("spawned=no"); sys.exit(0)
hits = [i for i, a in enumerate(argv[:-1]) if a == "--settings"]
print("settings=%d" % len(hits))
if len(hits) != 1:
    sys.exit(0)
try:
    settings = json.loads(argv[hits[0] + 1])
except ValueError:
    print("parse=no"); sys.exit(0)
env = settings.get("env") or {}
print("instance=%s" % env.get("FOREMAN_INSTANCE"))
print("config_instance=%s" % env.get("FOREMAN_CONFIG_INSTANCE"))
print("repo=%s" % env.get("REPO"))
print("missing=%s" % ",".join(n for n in names if n not in env))
print("stale=%s" % ",".join(sorted(k for k, v in env.items() if "stale" in v)))
print("rc=%s" % settings.get("disableRemoteControl"))
print("prompt_last=%s" % (argv[-1] == prompt))
print("env=%s" % json.dumps(env, sort_keys=True))
PY
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

check_env() { # <path> <report>
  local path="$1" r="$2"
  if [[ "$(field "$r" spawned)" == no ]]; then
    bad "$path: the dispatch never reached claude --bg"
    dispatch_fixture_show_run_log
    return
  fi
  if [[ "$(field "$r" settings)" != 1 ]]; then
    bad "$path: expected one --settings, got $(field "$r" settings)"
    return
  fi
  if [[ "$(field "$r" instance)" == demo && "$(field "$r" repo)" == "$demo_repo" \
        && "$(field "$r" config_instance)" == demo && -z "$(field "$r" stale)" ]]; then
    ok "$path: --settings env names the dispatching board's FOREMAN_INSTANCE and REPO, not the stale ones"
  else
    bad "$path: --settings env serves the wrong board: $(field "$r" env)"
  fi
  if [[ -z "$(field "$r" missing)" ]]; then
    ok "$path: env covers every name in FOREMAN_BOARD_EXPORTS, plus FOREMAN_INSTANCE and FOREMAN_CONFIG_INSTANCE"
  else
    bad "$path: env is missing $(field "$r" missing)"
  fi
  if [[ "$(field "$r" rc)" == True && "$(field "$r" prompt_last)" == True ]]; then
    ok "$path: disableRemoteControl is still true, and the prompt is still the last argument"
  else
    bad "$path: disableRemoteControl=$(field "$r" rc) prompt_last=$(field "$r" prompt_last)"
  fi
}

# shellcheck disable=SC2086 # split on purpose: one name per word
names=(FOREMAN_INSTANCE FOREMAN_CONFIG_INSTANCE $exports)

dispatch_fixture_run --ticket PRA-9 --role build --attempt 1
spawn_report="$(settings_report "$DISPATCH_ARGV_LOG" "$prompt" "${names[@]}")"
check_env spawn "$spawn_report"

dispatch_fixture_resume --ticket PRA-9 --role build --attempt 1 --reason fix
resume_report="$(settings_report "$DISPATCH_ARGV_LOG" "$prompt" "${names[@]}")"
check_env resume "$resume_report"
if [[ "$(field "$spawn_report" env)" == "$(field "$resume_report" env)" ]]; then
  ok "the resume path carries the same env as the spawn"
else
  bad "resume env differs from spawn env:
  spawn:  $(field "$spawn_report" env)
  resume: $(field "$resume_report" env)"
fi

exit "$fail"
