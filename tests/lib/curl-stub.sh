#!/usr/bin/env bash
# The curl the deploy harnesses run instead of the real one.
#
# One copy, shared by every deploy test. There were four, byte-identical apart
# from a comment and some unreachable trailing lines, and they had to agree with
# `verify_*` in the deploy script -- so teaching the read-surface gate to read a
# response header broke three harnesses that were not testing headers at all.
# Four copies of a stub that must track one script is the same hand-kept-duplicate
# failure the system pane's rosters had.
#
# Models only the parts of curl the deploy depends on:
#
# `--fail` matters: it exits non-zero on >= 400, so a stub that echoes "503" and
# exits 0 hides a bug that real curl would expose.
#
# `-D -` writes headers to stdout. The read-surface gate reads them, because a
# 200 alone does not prove *the target application* answered -- a stray
# `python -m http.server` squatted port 3015 for a month and served 200s the
# whole time.
#
# `WHATSAPP_CONNECT_AFTER` models the real startup shape: a Baileys runtime
# answers /status with 503 for a second or two after the port opens, before the
# WhatsApp socket finishes its handshake. A stub that answered 200 or 503
# immediately and forever could not tell an impatient check from a correct one.
url="$*"
if [[ "$url" == *":3015/"* ]]; then
  # The read surface is a different port answering a different question: what it
  # *refuses*. Falling through to PROBE_STATUS would make these harnesses assert
  # the wrong thing about a surface they are not testing.
  if [[ "$url" == *"-X POST"* ]]; then
    code="${READ_SURFACE_POST_STATUS:-405}"
  else
    code="${READ_SURFACE_STATUS:-200}"
  fi
elif [[ "$url" == *":3002/health"* ]]; then
  # Anchored to the port and the end of the path. It used to be `*/health*`,
  # which also swallowed /commands/health/correct -- an authenticated route
  # reported as an unauthenticated 200, so the harness failed claiming the
  # deploy script had probed the wrong place.
  code=200
elif [[ "$url" == *"/status"* ]]; then
  code="${WHATSAPP_STATUS:-200}"
  if [[ -n "${WHATSAPP_CONNECT_AFTER:-}" ]]; then
    counter="${STUB_COUNTER:?stub counter path}"
    calls=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    echo "$calls" > "$counter"
    if (( calls > WHATSAPP_CONNECT_AFTER )); then code=200; else code=503; fi
  fi
else
  code="${PROBE_STATUS:-401}"
fi

if [[ "$url" == *"-D -"* ]]; then
  echo "HTTP/1.1 $code STUB"
  # `READ_SURFACE_CSP=0` models something other than the target application
  # holding the port: it can answer 200, but it does not send the read
  # service's policy.
  if [[ "${READ_SURFACE_CSP:-1}" != "0" ]]; then
    echo "content-security-policy: default-src 'none'; script-src 'self'"
  fi
  echo "cache-control: no-store"
  echo
fi
[[ "$url" == *"-w"* ]] && echo "$code"
if [[ "$url" == *"--fail"* || "$url" =~ (^|[[:space:]])-[[:alnum:]]*f ]] && (( code >= 400 )); then
  exit 22
fi
exit 0
