#!/usr/bin/env bash
# Claim: preflight fails a repository whose every self-hosted runner is offline,
# counting every page and the organization's runners, stays quiet about
# repositories that do not use them, and says "unknown" -- never pass -- about
# a runner list it could not read.
#
# A required check that no runner can pick up does not fail. It queues forever,
# and a board waiting on it looks exactly like a board watching a job that is
# still running -- the same "waiting looks identical to running" failure SKILL.md
# names for a check-name mismatch, reached a different way.
#
# Measured on 2026-09-01: a self-hosted runner was OOM-killed overnight and
# nothing noticed for fifteen hours. Every card sat waiting on checks
# that could not start, while preflight reported the machine fit, because nothing
# asked.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"; target="$work/target"; origin="$work/origin"
mkdir -p "$target"
git init -q --bare "$origin"
git init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git -C "$target" add -A
git -C "$target" -c user.email=t@e -c user.name=t commit -qm seed
git -C "$target" remote add origin "$origin"
git -C "$target" push -q origin main
fixture_add_board "$home" demo "$target"

stub="$work/bin"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"; chmod +x "$stub/claude"

# $RUNNERS_JSON is what `gh api --paginate repos/.../actions/runners` returns:
# one JSON document per page, back to back. $OWNER_TYPE answers who owns the
# repository (User unless a case says otherwise), and $ORG_RUNNERS_JSON is the
# organization's list. A list whose variable is FAIL answers HTTP 403, as it
# does for a token without admin rights. Everything else gh is asked for
# succeeds, so this test isolates the runner check.
cat > "$stub/gh" <<'GH'
#!/usr/bin/env bash
argv=" $* "
answer() {
  # Without --paginate real gh returns only the first page of 30 runners.
  if [[ "$argv" != *" --paginate "* ]]; then
    echo "stub: runner list read without --paginate, so only its first page" >&2
    exit 1
  fi
  if [[ "$1" == FAIL ]]; then
    echo "gh: Resource not accessible by integration (HTTP 403)" >&2
    exit 1
  fi
  printf '%s\n' "$1"
  exit 0
}
for a in "$@"; do
  case "$a" in
    repos/*/actions/runners) answer "$RUNNERS_JSON" ;;
    orgs/*/actions/runners) answer "${ORG_RUNNERS_JSON-FAIL}" ;;
    'repos/{owner}/{repo}') echo "${OWNER_TYPE:-User}"; exit 0 ;;
  esac
done
exit 0
GH
chmod +x "$stub/gh"

# verdict <runners-json> [KEY=VALUE ...]
verdict() {
  local runners="$1"; shift
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$stub:$PATH" RUNNERS_JSON="$runners" "$@" \
    "$root/skills/board/preflight.py" 2>/dev/null
}
field() { printf '%s' "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=[x for x in d['checks'] if x['name']=='a runner is online']
print(d['fit'], '|', (c[0]['ok'] if c else 'NOCHECK'), '|', (c[0]['detail'] if c else ''))" 2>/dev/null; }

# --- every registered runner offline: unfit, and it says which
r="$(field "$(verdict '{"total_count":1,"runners":[{"name":"builder-1","status":"offline"}]}')")"
case "$r" in
  "False | False |"*builder-1*) ok "an offline runner makes the machine unfit, and names it" ;;
  *) bad "offline runner -> $r" ;;
esac

# --- one online among several: fine
r="$(field "$(verdict '{"total_count":2,"runners":[{"name":"a","status":"offline"},{"name":"b","status":"online"}]}')")"
case "$r" in
  "True | True |"*) ok "one online runner is enough" ;;
  *) bad "mixed runners -> $r" ;;
esac

# --- no self-hosted runners at all: GitHub-hosted, nothing to be wrong about
r="$(field "$(verdict '{"total_count":0,"runners":[]}')")"
case "$r" in
  "True | True |"*) ok "a repository with no self-hosted runners passes" ;;
  *) bad "no runners -> $r" ;;
esac

# --- an unreadable answer must not invent a fault the gh check already reports,
# and must not claim a pass either
r="$(field "$(verdict 'not json at all')")"
case "$r" in
  "True | True | unknown:"*) ok "an unreadable response is unknown, not an offline runner and not a pass" ;;
  *) bad "unreadable response -> $r" ;;
esac

# Found auditing the board on 2026-09-30: a failed call read as "no runners
# registered", only the first page was read, and an organization's runners were
# never asked about.
r="$(field "$(verdict FAIL)")"
case "$r" in
  "True | True | unknown:"*"HTTP 403"*) ok "a failed runner list is unknown, not a pass, and quotes gh" ;;
  *) bad "failed runner list -> $r" ;;
esac

r="$(field "$(verdict '{"total_count":2,"runners":[{"name":"a","status":"offline"}]}{"total_count":2,"runners":[{"name":"b","status":"online"}]}')")"
case "$r" in
  "True | True |"*"online: b"*) ok "a runner online on the second page is found" ;;
  *) bad "second page -> $r" ;;
esac

r="$(field "$(verdict '{"total_count":2,"runners":[{"name":"a","status":"offline"}]}{"total_count":2,"runners":[{"name":"b","status":"offline"}]}')")"
case "$r" in
  "False | False |"*"a, b"*) ok "every runner offline across pages makes the machine unfit" ;;
  *) bad "two offline pages -> $r" ;;
esac

r="$(field "$(verdict '{"total_count":1,"runners":[{"name":"a","status":"offline"}]}' \
  OWNER_TYPE=Organization ORG_RUNNERS_JSON='{"total_count":1,"runners":[{"name":"org-1","status":"online"}]}')")"
case "$r" in
  "True | True |"*"online: org-1"*) ok "an online organization runner counts for an org-owned repository" ;;
  *) bad "org runner online -> $r" ;;
esac

r="$(field "$(verdict '{"total_count":1,"runners":[{"name":"a","status":"offline"}]}' \
  OWNER_TYPE=Organization ORG_RUNNERS_JSON=FAIL)")"
case "$r" in
  "True | True | unknown:"*"organization runners"*) ok "a 403 on organization runners is unknown, not a failure" ;;
  *) bad "org 403 -> $r" ;;
esac

r="$(field "$(verdict '{"total_count":0,"runners":[]}' OWNER_TYPE=Organization \
  ORG_RUNNERS_JSON='{"total_count":1,"runners":[{"name":"org-1","status":"offline"}]}')")"
case "$r" in
  "False | False |"*org-1*) ok "an offline organization runner with no other runner makes the machine unfit" ;;
  *) bad "org runner offline -> $r" ;;
esac

exit "$fail"
