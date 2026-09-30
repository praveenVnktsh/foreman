#!/usr/bin/env bash
# Claim: every card agent is spawned with a Claude Code deny list that keeps its
# editing tools off foreman's install, the machine's config and keys, every
# history.jsonl and the board's main checkout; an author (build, plan, cleanup)
# is also kept off every card's reviews, and a reviewer is not, because it
# writes its own review there.
#
# Before this, a build agent running with permissions bypassed could write its
# own passing review under cards/<T>/reviews/ with the Write tool, and nothing
# said no. The deny list is the one layer Claude Code applies in
# bypassPermissions mode.
#
# Also claimed here:
#   - the list never names .claude, where every worktree lives, so a build can
#     still edit its own checkout;
#   - a deny list already in CARD_AGENT_SETTINGS is kept and extended, not
#     replaced;
#   - a rule that would cover the agent's own worktree or scratch dir refuses
#     the dispatch, as NOT a failure of the ticket, before any spawn.
#
# Drives the real dispatch.sh through tests/lib/dispatch-fixture.sh, which
# stubs only `claude` and preflight.py.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
real() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

dispatch_fixture_setup "$work" "$repo_root"

# A main checkout with a tracked directory and a tracked .claude, so the test
# sees a directory rule, a file rule and the one entry that must be skipped.
target="$work/target"
mkdir -p "$target/src" "$target/.claude"
echo code >"$target/src/main.txt"
echo '{}' >"$target/.claude/settings.json"
git -C "$target" add -A
git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
  -C "$target" commit -q -m "Add src and .claude"
git -C "$target" push -q origin main

fh="$(real "$DISPATCH_HOME/.foreman")"
shim="$(real "$work/shim-repo")"
repo="$(real "$target")"

# expected_deny <role> -- the exact list, one rule per line, in order.
expected_deny() {
  printf '%s\n' \
    "Edit(/$fh/install/**)" \
    "Edit(/$shim/**)" \
    "Edit(/$fh/boards.toml)" \
    "Edit(/$fh/foreman.toml)" \
    "Edit(/$fh/*.key)" \
    "Edit(/$fh/inbox/**)" \
    "Edit(/$fh/instances/*/HALT)" \
    "Edit(/$fh/instances/*/ids.env)" \
    "Edit(/$fh/instances/*/last-cleanup)" \
    "Edit(/$fh/instances/*/cards/**/history.jsonl)"
  [[ "$1" == review ]] || printf '%s\n' "Edit(/$fh/instances/*/cards/**)"
  printf '%s\n' \
    "Edit(/$repo/board.toml)" \
    "Edit(/$repo/seed.txt)" \
    "Edit(/$repo/src/**)" \
    "Edit(/$repo/.git/config)" \
    "Edit(/$repo/.git/hooks/**)"
}

# spawned_settings <key> -- from the captured argv's --settings: `deny` prints
# permissions.deny one per line, `rest` prints everything else as JSON.
spawned_settings() {
  python3 - "$DISPATCH_ARGV_LOG" "$1" <<'PY'
import json, sys
argv = open(sys.argv[1]).read().split("\n")[:-1]
if "--settings" not in argv:
    print("<never spawned>"); sys.exit(0)
settings = json.loads(argv[argv.index("--settings") + 1])
deny = settings.get("permissions", {}).pop("deny", None)
if sys.argv[2] == "deny":
    print("\n".join(deny) if deny is not None else "<no deny list>")
else:
    settings.pop("env", None)
    print(json.dumps(settings, sort_keys=True))
PY
}

check_role() { # <role> <dispatch.sh args...>
  local role="$1"; shift
  dispatch_fixture_run "$@"
  local got
  got="$(spawned_settings deny)"
  if [[ "$got" == "$(expected_deny "$role")" ]]; then
    ok "a $role agent is spawned with its role's exact deny list"
  else
    bad "a $role agent's deny list is wrong:"
    diff <(expected_deny "$role") <(printf '%s\n' "$got") >&2
    [[ "$got" == "<never spawned>" ]] && dispatch_fixture_show_run_log
  fi
  if printf '%s\n' "$got" | grep -q '/\.claude'; then
    bad "a $role agent's deny list names .claude, where its own worktree lives"
  else
    ok "a $role agent's deny list leaves .claude and its worktree writable"
  fi
}
check_role plan    --ticket PRA-1 --role plan --attempt 1
check_role build   --ticket PRA-2 --role build --attempt 1
check_role review  --ticket PRA-3 --role review --attempt 1 --slot a --ref "$DISPATCH_SEED_SHA"
check_role cleanup --ticket cleanup --role cleanup --attempt 202609301200

# --- a deny list already in CARD_AGENT_SETTINGS is extended ------------------
#
# The shim's config.sh becomes a copy of the real one with CARD_AGENT_SETTINGS
# reassigned at the end: the base settings an operator or a later change might
# write. One of its rules duplicates a generated one, which must not repeat.
config="$work/shim-repo/skills/board/config.sh"
rm "$config"
cat "$repo_root/skills/board/config.sh" >"$config"
printf '%s\n' "CARD_AGENT_SETTINGS='{\"disableRemoteControl\":true,\"permissions\":{\"allow\":[\"Read\"],\"deny\":[\"Bash(rm -rf:*)\",\"Edit(/$fh/boards.toml)\"]}}'" >>"$config"
dispatch_fixture_run --ticket PRA-4 --role build --attempt 1
got="$(spawned_settings deny)"
want="$(printf '%s\n' "Bash(rm -rf:*)" "Edit(/$fh/boards.toml)"; expected_deny build | grep -vxF "Edit(/$fh/boards.toml)")"
[[ "$got" == "$want" ]] \
  && ok "a deny list already in CARD_AGENT_SETTINGS is kept first and extended once" \
  || { bad "the existing deny list was not merged:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2; }
got="$(spawned_settings rest)"
[[ "$got" == '{"disableRemoteControl": true, "permissions": {"allow": ["Read"]}}' ]] \
  && ok "the rest of CARD_AGENT_SETTINGS survives the merge" \
  || bad "the rest of CARD_AGENT_SETTINGS changed: $got"
rm "$config"
ln -s "$repo_root/skills/board/config.sh" "$config"

# --- a rule that covers the agent's own directories refuses -----------------
#
# refuses <description> <what the refusal names> <ticket>
refuses() {
  local desc="$1" names="$2" ticket="$3"
  dispatch_fixture_run --ticket "$ticket" --role build --attempt 1
  if [[ -s "$DISPATCH_ARGV_LOG" ]]; then
    bad "$desc: the agent was spawned anyway"
  elif ! grep -q "would cover this agent's $names" "$DISPATCH_RUN_LOG" ||
       ! grep -q "NOT a failure of ticket $ticket" "$DISPATCH_RUN_LOG"; then
    bad "$desc: the refusal does not name the $names or spare the ticket"
    dispatch_fixture_show_run_log
  else
    ok "$desc"
  fi
}

# foreman's install symlinked to the board's own checkout: the install rule,
# resolved, covers every worktree under $REPO/.claude/worktrees.
ln -s "$target" "$DISPATCH_HOME/.foreman/install"
refuses "a FOREMAN_HOME whose install resolves to the board's checkout refuses the dispatch" \
  worktree PRA-5
rm "$DISPATCH_HOME/.foreman/install"

DISPATCH_INHERITED_ENV=(FOREMAN_TMP_ROOT="$DISPATCH_HOME/.foreman/inbox/tmp")
refuses "a scratch root under a denied directory refuses the dispatch" \
  "scratch dir" PRA-6
DISPATCH_INHERITED_ENV=()

exit "$fail"
