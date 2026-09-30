#!/usr/bin/env bash
# Claim: `reconcile.py` scores a pull request that moves a file OUT of a risk
# path as `risk: high`, and a files list the API cut short as `risk: unknown`.
#
# The failure it prevents: the risk scan read `gh pr diff --name-only` first,
# which lists only the path a renamed file went TO. A pull request that moved
# `db/migrations/001.sql` to `archive/001.sql` therefore touched no risk path,
# scored `low`, and merged with no operator. The files API names the path it
# came from, so it answers first now. It stops at 3000 files without an error,
# so a list shorter than the pull request's own `changedFiles` is no diff at all.
#
# It drives the real script over a real board.toml. Only `gh` and `claude` are
# stubbed: `gh pr diff` always answers with the new path alone, the way GitHub
# does, so a scan that still read it first would score the rename `low`.
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
git init -q -b main "$repo"
fixture_board_toml "$repo"
printf '[risk]\npaths = ["db/migrations/"]\n' >> "$repo/board.toml"
fixture_add_board "$home" demo "$repo"

# `$work/files` is what the files API prints, one JSON pair per line, and a
# missing file makes it fail. `$work/changed` is the pull request's own count.
stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  printf '[{"number":5,"state":"OPEN","isCrossRepository":false,"statusCheckRollup":[],"changedFiles":%s}]\n' "\$(cat "$work/changed")"
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "repos/{owner}/{repo}/pulls/5/files" ]]; then
  [[ -f "$work/files" ]] || exit 1
  cat "$work/files"; exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then printf 'README.md\narchive/001.sql\n'; exit 0; fi
exit 1
STUB
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] && printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh" "$stub_bin/claude"

risk_of() {  # prints "<risk> <files_changed> <risk_paths> | <risk_reason>"
  env PATH="$stub_bin:$PATH" HOME="$home" FOREMAN_HOME="$fh" FOREMAN_INSTANCE=demo \
    "$root/skills/board/reconcile.py" P-1 2>"$work/err" \
    | python3 -c 'import json, sys
pr = json.load(sys.stdin)[0]["pr"]
print(pr["risk"], pr["files_changed"], ",".join(pr["risk_paths"]), "|", pr.get("risk_reason", ""))'
}

rename='["README.md", ""]
["archive/001.sql", "db/migrations/001.sql"]'

printf '%s\n' "$rename" > "$work/files"
echo 2 > "$work/changed"
got="$(risk_of)"
[[ "$got" == "high 2 db/migrations/ | " ]] \
  && ok "a file renamed out of a risk path is high risk" \
  || bad "a file renamed out of a risk path is high risk: got [$got] $(cat "$work/err")"

printf '["README.md", ""]\n["archive/001.sql", ""]\n' > "$work/files"
got="$(risk_of)"
[[ "$got" == "low 2  | " ]] \
  && ok "a diff that touches no risk path, before or after, is low risk" \
  || bad "a diff that touches no risk path is low risk: got [$got] $(cat "$work/err")"

printf '%s\n' "$rename" > "$work/files"
echo 3001 > "$work/changed"
got="$(risk_of)"
case "$got" in
  "unknown None  | "*"listed 2 files and the pull request reports 3001"*)
    ok "a files list shorter than the pull request says is unknown, and says so" ;;
  *) bad "a files list shorter than the pull request says is unknown: got [$got] $(cat "$work/err")" ;;
esac

rm -f "$work/files"
echo 2 > "$work/changed"
got="$(risk_of)"
[[ "$got" == "low 2  | " ]] \
  && ok "a failed files API falls back to gh pr diff --name-only" \
  || bad "a failed files API falls back to gh pr diff: got [$got] $(cat "$work/err")"

[[ "$fail" -eq 0 ]] && printf 'PASS: the risk scan reads where a renamed file came from\n'
exit "$fail"
