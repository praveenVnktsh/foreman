#!/usr/bin/env bash
# `reconcile.py --overview` is the one picture bin/dashboard.py renders, and
# everything it says has to come from somewhere that already knows.
#
# Prove: it answers for the MACHINE and not for the board that happened to be
# named; it counts only foreman's OWN agents, because the harness registry is
# the whole machine's and a watcher must not be shown the operator's editor
# sessions; a roster it cannot read stops the command loudly rather than
# printing a machine with no boards, because "no boards" and "I could not
# look" must not render the same; a registry it cannot read is that same
# distinction one level down; it reports
# rate-limit stamps by the model's real name rather than fallback.py's
# percent-encoded filename; and it makes no network call unless asked, because
# a browser polls it.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
reconcile="$repo_root/skills/board/reconcile.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$reconcile" ]] || { echo "FAIL: $reconcile is missing or not executable" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

field() {
  local json="$1" expr="$2"
  printf '%s' "$json" | python3 -c '
import json, sys
v = json.load(sys.stdin)
print(eval(sys.argv[1]))
' "$expr"
}

# THE BOUNDARY IS THE CLI, not $HARNESS_SH. config.sh assigns HARNESS_SH from
# its own location and is deliberately not environment-wins about it -- "a name
# this shell pastes into a glob is not the environment's to answer" -- so a
# test that exports HARNESS_SH is quietly ignored and measures the developer's
# own live sessions instead. The real registry.sh and the real claude.sh run
# here; only `claude agents --json --all` is stubbed, which is the one thing
# that leaves this machine.
stub_claude() { # <bin-dir> <agents-json>
  mkdir -p "$1"
  cat >"$1/claude" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "agents" ]]; then
cat <<'JSON'
$2
JSON
  exit 0
fi
exit 0
STUB
  chmod +x "$1/claude"
}

new_home() {
  local home; home="$(mktemp -d "$work_dir/home.XXXXXX")"
  local target; target="$(mktemp -d "$work_dir/target.XXXXXX")"
  fixture_board_toml "$target"
  printf '[boards.demo]\nrepo = "%s"\n' "$target" >"$home/boards.toml"
  mkdir -p "$home/instances/demo/cards"
  printf '%s' "$home"
}

run_overview() { # <home> <agents-json> [extra args...]
  local home="$1" agents="$2"; shift 2
  stub_claude "$home/bin" "$agents"
  PATH="$home/bin:$PATH" FOREMAN_HOME="$home" FOREMAN_INSTANCE=demo \
    "$reconcile" --overview "$@" 2>"$work_dir/err"
}

# =============================================================================
# Case: the tick and the boards, from a machine with one card in flight
# =============================================================================
home1="$(new_home)"
mkdir -p "$home1/instances/demo/cards/PRA-1"
printf '{"at":"%s","event":{"action":"spawn","role":"build","attempt":"1"}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$home1/instances/demo/cards/PRA-1/history.jsonl"

# `foreman/tick` and one build agent are foreman's. The other two rows are what
# the machine's registry also holds -- a human's own sessions -- and are the
# reason AGENT_ROOT exists.
out1="$(run_overview "$home1" '[
  {"name":"foreman/tick","state":"working","startedAt":1,"id":"t1"},
  {"name":"foreman/demo/PRA-1/build-1","state":"working","startedAt":2,"id":"b1"},
  {"name":"Refactoring the parser","state":"working","startedAt":3,"id":"x1"},
  {"name":"my notes","state":"done","startedAt":4,"id":"x2"}
]')"

if [[ "$(field "$out1" 'v["tick"]["running"]')" == "True" ]]; then
  ok "the tick is reported running"
else
  not_ok "the tick is reported running: $(field "$out1" 'v["tick"]')"
fi

if [[ "$(field "$out1" 'len(v["agents"])')" == "2" ]]; then
  ok "only foreman's own agents are counted, not every session on the machine"
else
  not_ok "only foreman's own agents are counted: $(field "$out1" '[a["name"] for a in v["agents"]]')"
fi

if [[ "$(field "$out1" '[a["name"] for a in v["agents"] if "parser" in a["name"]]')" == "[]" ]]; then
  ok "a human's own harness session is not shown as a board agent"
else
  not_ok "a human's own harness session leaked into the agent list"
fi

if [[ "$(field "$out1" '[a["role"] for a in v["agents"] if a["ticket"]=="PRA-1"]')" == "['build']" ]]; then
  ok "an agent's board, ticket and role are taken apart from its name"
else
  not_ok "an agent's name is not taken apart: $(field "$out1" 'v["agents"]')"
fi

if [[ "$(field "$out1" 'v["boards"][0]["slots_held"]')" == "1" ]]; then
  ok "the board's in-flight count comes from the same slot rule dispatch uses"
else
  not_ok "the board's in-flight count: $(field "$out1" 'v["boards"][0]')"
fi

# =============================================================================
# Case: a roster that will not load is an error field, never an empty machine
# =============================================================================
# config.sh loads this board's own declaration before reconcile.py has a main()
# to run, so a boards.toml that will not parse at all stops the command rather
# than reaching overview(). That is the right layer for it -- the same refusal
# every other consumer of boards.py gets -- and what must be true is that it is
# LOUD: bin/dashboard.py turns a non-zero --overview into a rendered problem,
# and a zero exit with an empty machine is the one answer that would render as
# "this foreman has no boards".
home2="$(new_home)"
stub_claude "$home2/bin" '[]'
printf 'this is not toml\n' >"$home2/boards.toml"
status=0
out2="$(PATH="$home2/bin:$PATH" FOREMAN_HOME="$home2" FOREMAN_INSTANCE=demo \
  "$reconcile" --overview 2>"$work_dir/roster.err")" || status=$?
if [[ $status -ne 0 ]] && [[ -z "$out2" ]] && [[ -s "$work_dir/roster.err" ]]; then
  ok "a boards.toml that will not parse fails the overview loudly, printing no picture"
else
  not_ok "a boards.toml that will not parse: status=$status out=$out2 err=$(cat "$work_dir/roster.err")"
fi

# =============================================================================
# Case: a registry that will not answer is not "nothing is running"
# =============================================================================
home3="$(new_home)"
mkdir -p "$home3/bin"
cat >"$home3/bin/claude" <<'STUB'
#!/usr/bin/env bash
# `claude agents` exits non-zero. claude.sh refuses to answer as if nothing
# were running, and that refusal has to survive all the way to the page.
[[ "${1:-}" == "agents" ]] && { echo "the registry is down" >&2; exit 1; }
exit 0
STUB
chmod +x "$home3/bin/claude"
out3="$(PATH="$home3/bin:$PATH" FOREMAN_HOME="$home3" FOREMAN_INSTANCE=demo \
  "$reconcile" --overview 2>/dev/null)"
if [[ "$(field "$out3" 'v["registry_ok"]')" == "False" ]] \
   && [[ "$(field "$out3" '[p["kind"] for p in v["problems"]]')" == "['registry-unreadable']" ]]; then
  ok "a registry that cannot be read is its own problem, not an empty agent list"
else
  not_ok "a registry that cannot be read: registry_ok=$(field "$out3" 'v["registry_ok"]') problems=$(field "$out3" 'v["problems"]')"
fi

# =============================================================================
# Case: rate-limit stamps are reported under the model's real name
#
# fallback.py percent-encodes the filename so a model holding `/` or `:` cannot
# escape the directory. `claude%3Aopus` is not what the operator called it, so
# the encoding has to be undone on the way out.
# =============================================================================
home4="$(new_home)"
mkdir -p "$home4/rate-limits"
future="$(python3 -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc)
       + datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
past="$(python3 -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '%s\n' "$future" >"$home4/rate-limits/claude%3Aopus"
printf '%s\n' "$past" >"$home4/rate-limits/opencode%3Afoundry%2Fsol"
out4="$(run_overview "$home4" '[]')"

if [[ "$(field "$out4" 'sorted(r["model"] for r in v["machine"]["rate_limits"])')" \
      == "['claude:opus', 'opencode:foundry/sol']" ]]; then
  ok "a stamp is reported under the model's real name, not its encoded filename"
else
  not_ok "a stamp's model name: $(field "$out4" 'v["machine"]["rate_limits"]')"
fi

if [[ "$(field "$out4" '[r["expired"] for r in v["machine"]["rate_limits"] if r["model"]=="claude:opus"]')" == "[False]" ]] \
   && [[ "$(field "$out4" '[r["expired"] for r in v["machine"]["rate_limits"] if "sol" in r["model"]]')" == "[True]" ]]; then
  ok "a stamp in the past is expired and one in the future is not"
else
  not_ok "stamp expiry: $(field "$out4" 'v["machine"]["rate_limits"]')"
fi

if [[ "$(field "$out4" '[p["kind"] for p in v["problems"] if p["kind"]=="rate-limited"]')" == "['rate-limited']" ]]; then
  ok "only the live limit is a problem; the expired one is history"
else
  not_ok "only the live limit is reported: $(field "$out4" '[p["kind"] for p in v["problems"]]')"
fi

# =============================================================================
# Case: the inbox is reported by name, and its bodies are not
#
# The picture is polled; a message is prose somebody typed. Names tell the page
# there is something waiting without putting the text in every refresh.
# =============================================================================
home5="$(new_home)"
mkdir -p "$home5/inbox/done"
printf 'look at the stuck card again\n' >"$home5/inbox/20260920T000000Z-aaa.md"
printf 'handled\n' >"$home5/inbox/done/20260919T000000Z-bbb.md"
out5="$(run_overview "$home5" '[]')"
if [[ "$(field "$out5" 'v["inbox"]["waiting"]')" == "['20260920T000000Z-aaa.md']" ]] \
   && [[ "$(field "$out5" 'v["inbox"]["done_count"]')" == "1" ]]; then
  ok "the inbox reports what is waiting and how much has been answered"
else
  not_ok "the inbox view: $(field "$out5" 'v["inbox"]')"
fi
if [[ "$out5" != *"look at the stuck card again"* ]]; then
  ok "a message's body is not in the polled picture"
else
  not_ok "a message's body leaked into the polled picture"
fi

# =============================================================================
# Case: no network on the default path
#
# A browser polls this every few seconds. `gh` is rate-limited, and the twelve
# invocation sites in reconcile.py must stay behind --with-remote.
# =============================================================================
home6="$(new_home)"
mkdir -p "$home6/bin"
cat >"$home6/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh was called by --overview\n' >>"$GH_CANARY"
exit 1
STUB
chmod +x "$home6/bin/gh"
stub_claude "$home6/bin" '[]'
canary="$work_dir/gh-canary"
: >"$canary"
GH_CANARY="$canary" PATH="$home6/bin:$PATH" \
  FOREMAN_HOME="$home6" FOREMAN_INSTANCE=demo "$reconcile" --overview >/dev/null 2>&1 || true
if [[ ! -s "$canary" ]]; then
  ok "--overview reaches no network; gh is never called"
else
  not_ok "--overview called gh $(wc -l <"$canary") time(s)"
fi

# =============================================================================
# Case: an unknown flag is refused rather than ignored
# =============================================================================
home7="$(new_home)"
stub_claude "$home7/bin" '[]'
status=0
PATH="$home7/bin:$PATH" FOREMAN_HOME="$home7" FOREMAN_INSTANCE=demo \
  "$reconcile" --overview --with-remot >/dev/null 2>"$work_dir/typo.err" || status=$?
if [[ $status -ne 0 ]] && grep -q -- "--with-remot" "$work_dir/typo.err"; then
  ok "a mistyped flag is refused by name, not silently dropped"
else
  not_ok "a mistyped flag is refused: status=$status err=$(cat "$work_dir/typo.err")"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
