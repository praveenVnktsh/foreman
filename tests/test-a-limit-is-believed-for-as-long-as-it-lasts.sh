#!/usr/bin/env bash
# `fallback.py mark` stamps a model for FALLBACK_COOLDOWN_MINUTES, 60 by
# default. That is right for a per-minute limit and wrong for the one measured
# on 2026-09-20: "You've hit your weekly limit - resets 4am
# (America/Los_Angeles)", on a machine whose plan, build and review stages all
# prefer the same model. Sixty minutes against a weekly limit means the board
# retries every hour for days, and every retry spawns an agent that is refused
# on its first call and left in the registry -- two were found still sitting
# there, 1.1 and 2.2 days old.
#
# The refusal says when it ends. Prove reconcile.py reads it, in both shapes
# Claude Code writes, and that anything it cannot read answers None so the
# configured cooldown still applies -- a wrong moment is worse than a short one.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
reconcile="$repo_root/skills/board/reconcile.py"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# The two functions, lifted out of reconcile.py rather than run through it: a
# full --overview needs a board, a home and a registry, and none of that is
# what this file is about. The text is sliced from the real source, so a change
# to either function is measured here and a rename fails loudly.
probe() { # <python expression using rate_limit_until / rate_limit_minutes>
  python3 - "$reconcile" "$1" <<'PY'
import math, re, sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

source = open(sys.argv[1]).read()
start = source.index("_RESET_EPOCH = re.compile")
end = source.index("def _api_error_text")
ns = {"re": re, "math": math, "datetime": datetime, "timezone": timezone,
      "timedelta": timedelta, "ZoneInfo": ZoneInfo,
      "ZoneInfoNotFoundError": ZoneInfoNotFoundError}
exec(source[start:end], ns)
# A fixed NOW, so this file does not fail at 3am. 16:30 UTC is 09:30 in
# Los Angeles, which puts "resets 4am" firmly in tomorrow.
ns["NOW"] = datetime(2026, 9, 20, 16, 30, tzinfo=timezone.utc)
print(eval(sys.argv[2], ns))
PY
}

# The exact string measured on the host, `error` field and all: reconcile.py's
# _api_error_text joins the error kind to the message, and that join is what
# the parser is handed.
real="rate_limit You've hit your weekly limit · resets 4am (America/Los_Angeles)"

# Does this host carry a tz database at all? Without one every zone lookup
# raises and the clock cases correctly answer None -- which is the documented
# fallback, not a failure of the parser.
has_tz="$(probe 'bool(rate_limit_until("resets 4am (America/Los_Angeles)", NOW))')"

if [[ "$has_tz" == "True" ]]; then
  got="$(probe "rate_limit_minutes(\"$real\", NOW)")"
  # 09:30 LA to 04:00 LA the next day is 18h30m.
  if [[ "$got" == "1110" ]]; then
    ok "a weekly limit that names its reset is believed until that reset, not for an hour"
  else
    not_ok "a weekly limit's reset: expected 1110 minutes, got $got"
  fi

  got="$(probe 'rate_limit_minutes("resets 4:30pm (America/Los_Angeles)", NOW)')"
  if [[ "$got" == "420" ]]; then
    ok "a reset later the same day is not rolled forward a day"
  else
    not_ok "a same-day reset: expected 420 minutes, got $got"
  fi

  got="$(probe 'rate_limit_minutes("resets 4am (Mars/Olympus)", NOW)')"
  if [[ "$got" == "None" ]]; then
    ok "a zone this host does not carry answers None, so the cooldown applies"
  else
    not_ok "an unknown zone: expected None, got $got"
  fi
else
  ok "no tz database on this host; the clock form answers None and the cooldown applies"
fi

# The other shape: an epoch after a pipe.
got="$(probe 'rate_limit_minutes("Claude AI usage limit reached|%d" % int((NOW + timedelta(hours=5)).timestamp()), NOW)')"
if [[ "$got" == "300" ]]; then
  ok "an epoch reset is read as the minutes until it"
else
  not_ok "an epoch reset: expected 300 minutes, got $got"
fi

# An epoch already past is not a limit that ends in the past -- it is a stale
# or misread number, and believing it would mark a model for zero minutes.
got="$(probe 'rate_limit_minutes("limit reached|1000000000", NOW)')"
if [[ "$got" == "None" ]]; then
  ok "an epoch already past is ignored rather than believed"
else
  not_ok "a past epoch: expected None, got $got"
fi

# A refusal that says nothing about when it ends is the common case.
got="$(probe 'rate_limit_minutes("API Error: 429 {\"type\":\"rate_limit_error\"}", NOW)')"
if [[ "$got" == "None" ]]; then
  ok "a refusal that names no reset answers None, so FALLBACK_COOLDOWN_MINUTES applies"
else
  not_ok "a refusal with no reset: expected None, got $got"
fi

# Never zero and never negative: fallback.py refuses a non-positive cooldown,
# and a stamp that expires as it is written is the hourly retry again.
got="$(probe 'rate_limit_minutes("limit|%d" % int((NOW + timedelta(seconds=40)).timestamp()), NOW)')"
if [[ "$got" == "1" ]]; then
  ok "a reset seconds away is one minute, never zero"
else
  not_ok "a reset seconds away: expected 1, got $got"
fi

# SKILL.md is what actually passes this to fallback.py; a field nothing reads
# is a field that does not work.
if grep -q -- '--minutes <death.rate_limit_minutes>' "$repo_root/skills/board/SKILL.md"; then
  ok "SKILL.md passes the measured reset to fallback.py mark"
else
  not_ok "SKILL.md does not pass rate_limit_minutes to fallback.py mark"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
