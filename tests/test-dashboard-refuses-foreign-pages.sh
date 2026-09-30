#!/usr/bin/env bash
# bin/dashboard.py binds loopback, but a browser on this host is not the
# operator: any page it has open can send requests to 127.0.0.1. A message
# posted here becomes an instruction to a tick that runs with permissions
# bypassed, so the server must refuse what a foreign page can send.
#
# Prove: a Host that is not a name of this machine is refused (DNS rebinding);
# loopback, the tailnet name of this host and a name the installer declared
# are accepted; a POST without the page's own header is refused (a cross-site
# form cannot set it); a POST whose Origin is foreign is refused; the page
# sends the header; and a negative Content-Length is refused at once instead
# of holding a worker until the client hangs up.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_root/bin/dashboard.py"

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
mkdir -p "$home/inbox"

port="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

FOREMAN_HOME="$home" FOREMAN_DASHBOARD_PORT="$port" FOREMAN_DASHBOARD_HOSTS="board.example, other.example" \
  "$dashboard" >"$work_dir/server.log" 2>&1 &
server_pid=$!

ready=""
for _ in $(seq 1 100); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[[ -n "$ready" ]] || { echo "FAIL: the dashboard never came up: $(cat "$work_dir/server.log")" >&2; exit 1; }

url="http://127.0.0.1:$port"
get_as() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "$url/"; }
inbox_count() { find "$home/inbox" -maxdepth 1 -type f | wc -l | tr -d ' '; }

# =============================================================================
# Case: Host must name this machine
# =============================================================================
[[ "$(get_as "evil.example")" == "403" ]] \
  && ok "a foreign Host is refused, so a rebound name cannot read the page" \
  || not_ok "a foreign Host was served: $(get_as "evil.example")"

[[ "$(get_as "127.0.0.1.evil.example:$port")" == "403" ]] \
  && ok "a name that only starts with a loopback address is refused" \
  || not_ok "127.0.0.1.evil.example was served"

loopback_ok=1
for host in "localhost:$port" "127.0.0.1:$port" "[::1]:$port" "LOCALHOST"; do
  [[ "$(get_as "$host")" == "200" ]] || { loopback_ok=0; not_ok "loopback Host $host was refused"; }
done
[[ "$loopback_ok" == 1 ]] && ok "every loopback spelling of Host is served"

short="$(python3 -c 'import socket; print(socket.gethostname().lower().split(".")[0])')"
[[ "$(get_as "$short.tail1234.ts.net")" == "200" ]] \
  && ok "this host's tailnet name, which tailscale serve forwards, is served" \
  || not_ok "$short.tail1234.ts.net was refused"

[[ "$(get_as "not-$short.tail1234.ts.net")" == "403" ]] \
  && ok "another machine's tailnet name is refused" \
  || not_ok "not-$short.tail1234.ts.net was served"

[[ "$(get_as "other.example")" == "200" ]] \
  && ok "a name declared in FOREMAN_DASHBOARD_HOSTS is served" \
  || not_ok "a declared name was refused: $(get_as "other.example")"

# =============================================================================
# Case: a POST must come from the page itself
# =============================================================================
before="$(inbox_count)"
code="$(curl -s -o "$work_dir/out" -w '%{http_code}' -X POST --data-binary "rm everything" "$url/message")"
if [[ "$code" == "403" ]] && [[ "$(inbox_count)" == "$before" ]]; then
  ok "a POST without the dashboard header is refused and queues nothing"
else
  not_ok "a POST without the header: code=$code, inbox $before -> $(inbox_count)"
fi

code="$(curl -s -o "$work_dir/out" -w '%{http_code}' -X POST -H 'X-Foreman-Dashboard: 1' \
  -H 'Origin: https://evil.example' --data-binary "rm everything" "$url/message")"
if [[ "$code" == "403" ]] && [[ "$(inbox_count)" == "$before" ]]; then
  ok "a POST from a foreign Origin is refused and queues nothing"
else
  not_ok "a POST from a foreign Origin: code=$code"
fi

code="$(curl -s -o "$work_dir/out" -w '%{http_code}' -X POST -H 'X-Foreman-Dashboard: 1' \
  -H "Origin: http://127.0.0.1:$port" --data-binary "hello tick" "$url/message")"
if [[ "$code" == "200" ]] && [[ "$(inbox_count)" == "$((before + 1))" ]]; then
  ok "a POST from this page's own Origin with the header is queued"
else
  not_ok "a same-origin POST: code=$code body=$(cat "$work_dir/out")"
fi

if grep -q '"X-Foreman-Dashboard": "1"' "$dashboard"; then
  ok "the page sends the header the server requires"
else
  not_ok "the page does not send X-Foreman-Dashboard, so its own messages are refused"
fi

# =============================================================================
# Case: a negative Content-Length is refused at once
#
# rfile.read(-1) reads until the client closes, so this request used to hold a
# worker for as long as the sender kept the socket open.
# =============================================================================
if python3 - "$port" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Foreman-Dashboard: 1\r\n"
          b"Content-Length: -1\r\n\r\n")
try:
    reply = s.recv(200)
except socket.timeout:
    sys.exit(1)
sys.exit(0 if reply.startswith(b"HTTP/1.0 400") or reply.startswith(b"HTTP/1.1 400") else 1)
PY
then
  ok "a negative Content-Length is answered 400 without waiting for the body"
else
  not_ok "a negative Content-Length hung or was not refused"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
