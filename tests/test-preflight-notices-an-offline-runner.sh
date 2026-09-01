#!/usr/bin/env bash
# Claim: preflight fails a repository whose every self-hosted runner is offline,
# and stays quiet about repositories that do not use them.
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

# $RUNNERS_JSON is what `gh api .../actions/runners` returns. Everything else gh
# is asked for succeeds, so this test isolates the runner check.
cat > "$stub/gh" <<'GH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *actions/runners*) printf '%s\n' "$RUNNERS_JSON"; exit 0 ;; esac
done
exit 0
GH
chmod +x "$stub/gh"

verdict() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$stub:$PATH" RUNNERS_JSON="$1" \
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

# --- an unreadable answer must not invent a fault the gh check already reports
r="$(field "$(verdict 'not json at all')")"
case "$r" in
  "True | True |"*) ok "an unreadable response is not reported as an offline runner" ;;
  *) bad "unreadable response -> $r" ;;
esac

exit "$fail"
