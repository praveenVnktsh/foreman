#!/usr/bin/env bash
# Claim: `reconcile.py --cleanup-due` exits 1 only for "not due". A fault --
# a `boards.toml` that will not load, a HOST_MAX_CONCURRENT that is not a
# ceiling -- exits 2 and says what failed on stderr.
#
# The failure it prevents: "not due" was exit 1 with its reason on stdout, and
# every fault that stopped the process before it could answer was exit 1 too.
# The tick branches on `if reconcile.py --cleanup-due`, so a broken config read
# as a cleanup that was not due yet: skipped, reported as nothing, for as long
# as the config stayed broken. The machine ceiling was also read from the
# environment with a fallback of 4 when it did not parse, so a typo weighed a
# ceiling nobody declared. It is now read from config.sh, which refuses one.
#
# It drives the real script. Nothing is stubbed but the agent registry.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/without-board.sh
source "$root/tests/lib/without-board.sh"
. "$root/tests/lib/instance-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work/home"
fh="$home/.foreman"
repo="$work/repo"
mkdir -p "$repo"
fixture_board_toml "$repo"
fixture_add_board "$home" demo "$repo"

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/claude"

cleanup_due() {  # extra environment assignments as arguments
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo "$@" \
    "$root/skills/board/reconcile.py" --cleanup-due demo 2>"$work/err"
}

date -u +%Y-%m-%dT%H:%M:%SZ > "$fh/instances/demo/last-cleanup"
out="$(cleanup_due FOREMAN_CLEANUP_TEST=1)"; status=$?
case "$status:$out" in
  1:*"next due"*) ok "a board cleaned just now is not due: exit 1, reason on stdout" ;;
  *) bad "a board cleaned just now is not due: status=$status out=$out $(cat "$work/err")" ;;
esac

out="$(cleanup_due HOST_MAX_CONCURRENT=lots)"; status=$?
if [[ "$status" -eq 2 && -z "$out" ]] && grep -q "HOST_MAX_CONCURRENT" "$work/err"; then
  ok "a machine ceiling that is not a number is a fault: exit 2, named on stderr"
else
  bad "a machine ceiling that is not a number is a fault: status=$status out=[$out] err=$(cat "$work/err")"
fi

cp "$fh/boards.toml" "$work/boards.toml.good"
printf '[boards.demo\nrepo = \n' > "$fh/boards.toml"
out="$(cleanup_due FOREMAN_CLEANUP_TEST=1)"; status=$?
if [[ "$status" -eq 2 && -z "$out" && -s "$work/err" ]]; then
  ok "a boards.toml that will not load is a fault: exit 2, reason on stderr"
else
  bad "a boards.toml that will not load is a fault: status=$status out=[$out] err=$(cat "$work/err")"
fi
cp "$work/boards.toml.good" "$fh/boards.toml"

[[ "$fail" -eq 0 ]] && printf 'PASS: --cleanup-due never reports a fault as not due\n'
exit "$fail"
