#!/usr/bin/env bash
# bin/dashboard.py is the page an operator opens from a phone when a board
# looks wrong, so the things that must hold are about reachability and about
# failing visibly.
#
# Prove: it renders under ANY mount path, because `tailscale serve` publishes
# it behind a prefix this process is never told; its endpoints are reached
# relatively from wherever it is mounted; a machine it cannot read becomes a
# rendered problem rather than a traceback or a blank page; it binds loopback
# and nothing else; and a message goes into the tick's inbox atomically, is
# refused when empty or oversized, and never lands as a half-written file.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_root/bin/dashboard.py"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

[[ -x "$dashboard" ]] || { echo "FAIL: $dashboard is missing or not executable" >&2; exit 1; }

work_dir="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

home="$work_dir/home"
mkdir -p "$home/instances/demo/cards" "$home/bin"
target="$work_dir/target"
mkdir -p "$target"
fixture_board_toml "$target"
printf '[boards.demo]\nrepo = "%s"\n' "$target" >"$home/boards.toml"

# The one external boundary, as tests/test-overview-answers-for-the-machine.sh
# explains: the real registry.sh and claude.sh run, and only the CLI is stubbed.
cat >"$home/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "agents" ]] && { echo '[{"name":"foreman/tick","state":"working","startedAt":1,"id":"t1"}]'; exit 0; }
exit 0
STUB
chmod +x "$home/bin/claude"

# A port nothing else on a test runner is likely to hold. Bound before the
# server starts so a failure to bind is this test's failure and not a timeout.
port="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

PATH="$home/bin:$PATH" FOREMAN_HOME="$home" FOREMAN_DASHBOARD_PORT="$port" \
  "$dashboard" >"$work_dir/server.log" 2>&1 &
server_pid=$!

# Wait for the socket rather than sleeping a fixed time: a loaded CI runner is
# slower than a laptop, and a fixed sleep is how this file becomes flaky.
ready=""
for _ in $(seq 1 100); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[[ -n "$ready" ]] || { echo "FAIL: the dashboard never came up: $(cat "$work_dir/server.log")" >&2; exit 1; }

code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$1"; }
body() { curl -s "http://127.0.0.1:$port$1"; }

# =============================================================================
# Case: it renders wherever it is mounted
#
# `tailscale serve --set-path /foreman` is one operator's choice; the prefix is
# never passed to this process. The dashboard this replaced stripped a
# hardcoded "foreman" segment and served nothing under any other name.
# =============================================================================
mounts_ok=1
for path in "/" "/foreman/" "/boards/foreman/" "/deeply/nested/mount/"; do
  [[ "$(code "$path")" == "200" ]] || { mounts_ok=0; not_ok "mount $path did not render (got $(code "$path"))"; }
done
[[ "$mounts_ok" == 1 ]] && ok "the page renders under any mount path, not just the root"

if [[ "$(body "/")" == *"<title>foreman</title>"* ]]; then
  ok "what renders is the page"
else
  not_ok "what renders is the page"
fi

# =============================================================================
# Case: the endpoints are reached relatively from any mount
# =============================================================================
api_ok=1
for prefix in "" "/foreman" "/boards/foreman"; do
  [[ "$(code "$prefix/api")" == "200" ]] || { api_ok=0; not_ok "$prefix/api did not answer"; }
done
[[ "$api_ok" == 1 ]] && ok "the api endpoint answers relative to any mount"

if body "/api" | python3 -c '
import json, sys
picture = json.load(sys.stdin)
sys.exit(0 if picture["tick"]["running"] and picture["boards"][0]["name"] == "demo" else 1)'; then
  ok "the api serves the overview, with the tick and the board in it"
else
  not_ok "the api serves the overview: $(body "/api" | head -c 400)"
fi

# =============================================================================
# Case: the page's endpoints resolve from where the page IS
#
# THE BUG THIS REPLACES A TEST FOR. A bare relative "api" resolves against the
# DIRECTORY of the current URL. At /foreman/ that is /foreman/api; at /foreman
# -- no trailing slash, which is what an operator types -- it is /api, at the
# proxy root, where another site answered "not found" and the page rendered
# "SyntaxError: Unexpected token 'o'". The old assertion here required exactly
# the bare form, so it passed while the page was broken, and every mount case
# below used a trailing slash and never exercised it.
#
# Resolution itself happens in a browser, which this file has no way to run.
# What it can pin is that the page builds a base ending in "/" from
# location.pathname and uses it for both endpoints -- the three things whose
# absence caused the failure.
# =============================================================================
if grep -q 'location.pathname.endsWith("/") ? location.pathname : location.pathname + "/"' "$dashboard"; then
  ok "the page derives its endpoint base from location.pathname, slash guaranteed"
else
  not_ok "the page does not derive a trailing-slash base; a mount without one asks the proxy root"
fi

if ! grep -qE 'fetch\("(/?)(api|message)"' "$dashboard"; then
  ok "no endpoint is fetched bare or absolute; both go through the base"
else
  not_ok "an endpoint is fetched without the base: $(grep -oE 'fetch\("[^"]*"' "$dashboard" | tr "\n" " ")"
fi

if [[ "$(grep -c 'fetch(BASE + "' "$dashboard")" == "2" ]]; then
  ok "both the api and the message endpoint use the base"
else
  not_ok "not both endpoints use the base: $(grep -c 'fetch(BASE + "' "$dashboard") of 2"
fi

# The server half: it routes on the LAST segment, so a base that appends a
# slash cannot produce a path it refuses -- including the /index.html case,
# where the base becomes /index.html/ and the endpoint /index.html/api.
for path in "/api" "/foreman/api" "/boards/foreman/api" "/index.html/api"; do
  [[ "$(code "$path")" == "200" ]] || not_ok "the server refused $path, which a computed base can produce"
done
ok "every path a computed base can produce is answered"

# =============================================================================
# Case: a message reaches the tick's inbox
# =============================================================================
send() { curl -s -X POST --data-binary "$1" "http://127.0.0.1:$port${2:-/message}"; }

queued="$(send "look at the stuck card again" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("queued",""))')"
if [[ -n "$queued" ]] && [[ -f "$home/inbox/$queued" ]]; then
  ok "a message is written into the inbox under the name the page is told"
else
  not_ok "a message is written into the inbox: queued='$queued'"
fi

if grep -q "look at the stuck card again" "$home/inbox/$queued"; then
  ok "the message body is what was sent"
else
  not_ok "the message body: $(cat "$home/inbox/$queued" 2>/dev/null)"
fi

# Posted through a prefix, the way a tailnet viewer's browser will.
if send "a second message" "/foreman/message" | grep -q '"queued"'; then
  ok "a message posted through a mount prefix is accepted"
else
  not_ok "a message posted through a mount prefix is accepted"
fi

# NOTHING PARTIAL IS EVER VISIBLE. The write is a rename into place, so a tick
# listing the inbox mid-write sees the whole message or no message. A leftover
# `.partial` would be read by nothing and cleaned by nothing.
if [[ -z "$(find "$home/inbox" -maxdepth 1 -name '*.partial' -print -quit)" ]]; then
  ok "no partial file is left behind in the inbox"
else
  not_ok "a .partial file was left in the inbox"
fi

if [[ "$(find "$home/inbox" -maxdepth 1 -type f | wc -l | tr -d ' ')" == "2" ]]; then
  ok "each message is its own file, so one cannot be half-answered"
else
  not_ok "each message is its own file: $(ls "$home/inbox")"
fi

# =============================================================================
# Case: a message that is not one is refused
# =============================================================================
if send "   " | grep -q '"error"'; then
  ok "an empty message is refused rather than queued"
else
  not_ok "an empty message is refused"
fi

big="$(python3 -c 'print("x" * 5000, end="")')"
if send "$big" | grep -q '"error"'; then
  ok "an oversized message is refused rather than queued"
else
  not_ok "an oversized message is refused"
fi

if [[ "$(find "$home/inbox" -maxdepth 1 -type f | wc -l | tr -d ' ')" == "2" ]]; then
  ok "a refused message writes nothing"
else
  not_ok "a refused message wrote a file anyway: $(ls "$home/inbox")"
fi

# =============================================================================
# Case: loopback only
#
# The page carries no credential and asks who nobody is. What keeps it private
# is that only this host can reach the socket, and the publisher in front is
# what decides the rest.
# =============================================================================
if python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
# A non-loopback address of this host. If the server bound 0.0.0.0 this
# connects; if it bound 127.0.0.1 it is refused, which is the pass.
try:
    probe = socket.socket()
    probe.connect(("8.8.8.8", 53))
    outward = probe.getsockname()[0]
    probe.close()
except OSError:
    sys.exit(0)  # no route out; nothing to prove and nothing to fail
if outward.startswith("127."):
    sys.exit(0)
s = socket.socket()
s.settimeout(2)
try:
    s.connect((outward, port))
except OSError:
    sys.exit(0)
sys.exit(1)
PY
then
  ok "the server is not reachable on a non-loopback address"
else
  not_ok "the server accepted a connection on a non-loopback address"
fi

# =============================================================================
# Case: a machine it cannot read is a rendered problem, never a blank page
# =============================================================================
blind="$work_dir/blind"
mkdir -p "$blind"
out="$(FOREMAN_HOME="$blind" "$dashboard" --once)"
if printf '%s' "$out" | python3 -c '
import json, sys
picture = json.load(sys.stdin)
problems = picture["problems"]
sys.exit(0 if problems and problems[0]["severity"] == "critical"
         and problems[0]["kind"] == "dashboard-blind" else 1)'; then
  ok "a home with no boards renders a critical problem saying so"
else
  not_ok "a home with no boards: $(printf '%s' "$out" | head -c 300)"
fi

if printf '%s' "$out" | python3 -c '
import json, sys
json.load(sys.stdin)' 2>/dev/null; then
  ok "even the failure is a well-formed picture the page can render"
else
  not_ok "the failure is not valid JSON"
fi

status=0
FOREMAN_HOME="$blind" "$dashboard" --nonsense >/dev/null 2>"$work_dir/arg.err" || status=$?
if [[ $status -ne 0 ]] && grep -q -- "--nonsense" "$work_dir/arg.err"; then
  ok "an unknown argument is refused by name"
else
  not_ok "an unknown argument is refused: status=$status"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
