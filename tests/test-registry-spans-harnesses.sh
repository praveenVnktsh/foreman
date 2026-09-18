#!/usr/bin/env bash
# registry.sh is the one reader, and it merges across the harnesses an
# installation can spawn on. Codex and OpenCode share one registry, so the same
# agent appears from both adapters and must not appear twice; stop and
# transcript must reach the adapter that owns the agent.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

harness="$work/harness"
mkdir -p "$harness"
cp "$repo_root/skills/board/harness/registry.sh" "$harness/registry.sh"
chmod +x "$harness/registry.sh"

# a and b share their registry (the detached case): both list agent x; b also
# lists y. Only b can stop y; only a has a transcript.
cat > "$harness/a.sh" <<'A'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo '[{"id":"x","name":"t","startedAt":1}]' ;;
  stop) if [[ "${2:-}" == "x" ]]; then echo "a-stop x" >>"$REGISTRY_LOG"; exit 0; fi; exit 1 ;;
  transcript) echo "/a/${3:-}" ;;
  *) echo "a-${1:-}" ;;
esac
A
cat > "$harness/b.sh" <<'B'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo '[{"id":"x","name":"t","startedAt":1},{"id":"y","name":"u","startedAt":2}]' ;;
  stop) echo "b-stop ${2:-}" >>"$REGISTRY_LOG"; [[ "${2:-}" == "y" ]] ;;
  transcript) exit 1 ;;
  *) echo "b-${1:-}" ;;
esac
B
chmod +x "$harness/a.sh" "$harness/b.sh"

export REGISTRY_LOG="$work/calls"
: >"$REGISTRY_LOG"
reg="$harness/registry.sh"
export FOREMAN_DEFAULT_HARNESS=a FOREMAN_HARNESSES="a b"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

listed="$("$reg" list)"
n_x="$(printf '%s' "$listed" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r["id"]=="x"))')"
n_y="$(printf '%s' "$listed" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r["id"]=="y"))')"
[[ "$n_x" == "1" ]] && ok "an agent shared by two adapters is listed once" || bad "x listed $n_x times"
[[ "$n_y" == "1" ]] && ok "an agent only one adapter owns is listed" || bad "y listed $n_y times"

"$reg" stop y >/dev/null 2>&1 && ok "stop succeeds for the owning adapter" || bad "stop y failed"
grep -q "b-stop y" "$REGISTRY_LOG" && ok "stop reached the owner" || bad "stop did not reach b"
grep -q "a-stop y" "$REGISTRY_LOG" && bad "stop wrongly tried a before b" || ok "stop did not signal the non-owner first"

out="$("$reg" transcript cwd session-9)"
[[ "$out" == "/a/session-9" ]] && ok "transcript falls through to the adapter that has it" || bad "transcript got '$out'"

out="$("$reg" check)"
[[ "$out" == "a-check" ]] && ok "a harness-shaped verb goes to the default adapter" || bad "check got '$out'"

exit "$fail"
