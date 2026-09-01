#!/usr/bin/env bash
# Claim: preflight fails a machine whose GitHub token is configured but dead.
#
# Measured on a real host on 2026-09-01: with an expired token, `gh auth status`
# prints "The token ... is invalid" and EXITS 0, while every actual API call
# returns HTTP 401. preflight checked that exit code alone, so it reported a
# machine fit to build on which `gh pr create` could not work at all.
#
# That is the precise failure preflight exists to prevent. An agent dispatched
# into an unusable environment does the whole job, dies at the end, and costs the
# ticket one of its few attempts for a reason that was knowable before it
# started. A check that asks whether a credential is CONFIGURED rather than
# whether it WORKS is not a gate.
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

# The stub reproduces the real gh's behaviour exactly: `auth status` succeeds
# while the token is dead, and any API call fails.
cat > "$stub/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  echo "  X Failed to log in. The token is invalid." >&2
  exit 0
fi
echo "HTTP 401: Requires authentication" >&2
exit 1
GH
chmod +x "$stub/gh"

verdict="$(env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
  PATH="$stub:$PATH" "$root/skills/board/preflight.py" 2>/dev/null)"

fit="$(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fit"])' 2>/dev/null)"
if [[ "$fit" == "False" ]]; then
  ok "a configured but dead GitHub token makes the machine unfit"
else
  bad "preflight reported fit=$fit on a host where every gh API call returns 401"
fi

named="$(printf '%s' "$verdict" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(",".join(c["name"] for c in d["checks"] if not c["ok"]))' 2>/dev/null)"
case "$named" in
  *"gh auth"*) ok "and it names the gh check, so an operator knows what to fix" ;;
  *) bad "unfit, but the failing check was reported as: ${named:-<none>}" ;;
esac

# The inverse: a working token must not be reported as broken.
cat > "$stub/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$stub/gh"
verdict="$(env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
  PATH="$stub:$PATH" "$root/skills/board/preflight.py" 2>/dev/null)"
broke="$(printf '%s' "$verdict" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(",".join(c["name"] for c in d["checks"] if not c["ok"]))' 2>/dev/null)"
case "$broke" in
  *"gh auth"*) bad "a working token was reported as a gh failure" ;;
  *) ok "a working token passes the gh check" ;;
esac

exit "$fail"
