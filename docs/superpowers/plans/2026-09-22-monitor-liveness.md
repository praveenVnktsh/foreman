# Monitor liveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A board whose agent Monitor is not armed stops foreman, instead of silently running one `TICK_INTERVAL_MINUTES` slower on every finished agent.

**Architecture:** The Monitor's own command witnesses itself. `watch-agents.py` runs only while a Monitor is alive, so it stamps `$BOARD_HOME/monitor.stamp` on every poll. `reconcile.py --monitor-stamps` is the single reader of those stamps; `dispatch.sh`, `supervise.sh` and `bin/dashboard.py` are its three consumers. Fail-stop is enforced by scripts, never by prose, because a tick asked in prose to exit on a failed tool call may carry on instead.

**Tech Stack:** Python 3.11+ stdlib only, bash 3.2, `tests/run-all.sh`.

**Spec:** `docs/specs/2026-09-22-monitor-liveness-design.md`

## Global Constraints

Copied from `AGENTS.md` and the spec. Every task's requirements include these.

- **Python stdlib only.** No third-party packages. `tomllib` sets the floor at 3.11; CI runs 3.12.
- **bash 3.2.** No `mapfile`, no `declare -A`. Under `set -u`, `"${arr[@]}"` on an empty array is an error.
- **A target's config is parsed, never sourced.**
- **Name nothing outside this repository.** No other project, operator, ticket key or path. `tests/test-no-target-specifics.sh` enforces it.
- **A test drives the real script**, stubbing at the external boundary. `tests/lib/instance-fixture.sh` is the fixture; `tests/run-all.sh` discovers `tests/test-*.sh` by glob, so a new test file needs no registration.
- **Do not weaken a gate.**
- **Conclusion first, then the reason.** Every comment states the failure it prevents.

Values this plan uses, all defined in `skills/board/config.sh` unless noted:

| Name | Value | Where |
| --- | --- | --- |
| `WATCH_POLL_SECONDS` | `15` | `skills/board/watch-agents.py:43` |
| `MONITOR_STALE_SECONDS` | `WATCH_POLL_SECONDS * 4` = `60` | new, Task 3 |
| `MONITOR_GRACE_SECONDS` | `120` | new, Task 3 |
| stamp path | `$BOARD_HOME/monitor.stamp` | new, Task 2 |
| board runtime dir | `$FOREMAN_HOME/instances/<board>/` | `config.sh:198` |

**Task order delivers the live bug fix first.** Task 1 depends on nothing and corrects a `Monitor` call that a newer harness rejects. Tasks 2–6 build the mechanism that makes the next such break loud.

---

### Task 1: The arming contract in SKILL.md

The documented call omits `timeout_ms`, which `sdk-tools.d.ts` declares required on every version checked. It also passes `persistent`, which Claude Code 2.1.228 requires and 2.1.275 removed. Write down both facts so the next version shift is a known hazard.

**Files:**
- Modify: `skills/board/SKILL.md:528-547`
- Modify: `skills/board/watch-agents.py:1-31` (the docstring carries the same call)
- Test: `tests/test-monitor-arming-contract.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks read. This task is prose plus one test.

- [ ] **Step 1: Write the failing test**

Create `tests/test-monitor-arming-contract.sh`:

```bash
#!/usr/bin/env bash
# SKILL.md's Monitor call must name timeout_ms. sdk-tools.d.ts declares it
# required on Claude Code 2.1.228 and on 2.1.275, and the call shipped without
# it. It must also carry the version note: 2.1.228 requires `persistent` and
# 2.1.275 removed it, so no single call works on both and a tick that arms
# nothing leaves the board running at heartbeat speed with nothing saying so.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo_root/skills/board/SKILL.md"
watcher="$repo_root/skills/board/watch-agents.py"
fail=0

check() { # <file> <pattern> <why>
  if grep -q "$2" "$1"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s does not match %s\n' "$3" "$1" "$2" >&2
    fail=1
  fi
}

check "$skill" 'timeout_ms' "SKILL.md's Monitor call names timeout_ms"
check "$watcher" 'timeout_ms' "watch-agents.py's docstring names timeout_ms"
check "$skill" '2\.1\.275' "SKILL.md names the version that removed persistent"

exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-monitor-arming-contract.sh`
Expected: FAIL on all three checks, exit 1.

- [ ] **Step 3: Correct the call in SKILL.md**

In `skills/board/SKILL.md`, replace the fenced block at lines 533-536 with:

````markdown
```bash
Monitor(command="FOREMAN_INSTANCE=<board> ~/.foreman/install/skills/board/watch-agents.py",
        persistent=True, timeout_ms=1800000,
        description="board agents finishing: <board>")
```

**`timeout_ms` is required even when `persistent` is true.** `sdk-tools.d.ts`
declares it non-optional, and the call here shipped without it. `persistent`
makes it moot at runtime; leaving it out risks the call being rejected, which
arms nothing.

**The argument list is version-bound, and the boundary is a date.** Claude Code
2.1.228 requires `persistent` and documents it as "Run for the lifetime of the
session (no timeout)". 2.1.275 removed `persistent`, sets
`additionalProperties: false`, and caps every monitor at 30 minutes. No single
call works on both. On a harness that rejects `persistent`, drop it and keep
`timeout_ms` — the tick re-arms at the top of every tick anyway, which is what
a capped monitor needs.

**If the call is rejected, stop.** Do not carry on without a Monitor. The
board would keep merging cards one interval slower on every finished agent,
and every surface would read healthy. `dispatch.sh` and `supervise.sh` enforce
this with the stamp below, because prose cannot.
````

- [ ] **Step 4: Correct the same call in the watcher's docstring**

In `skills/board/watch-agents.py`, replace lines 7-8:

```python
    Monitor(command="~/.foreman/install/skills/board/watch-agents.py",
            persistent=True, description="board agents finishing")
```

with:

```python
    Monitor(command="~/.foreman/install/skills/board/watch-agents.py",
            persistent=True, timeout_ms=1800000,
            description="board agents finishing")

`timeout_ms` is required even when `persistent` is true, and `persistent`
itself exists only up to Claude Code 2.1.228 -- 2.1.275 removed it. SKILL.md
carries the version note; this is the copy a reader of this file sees.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-monitor-arming-contract.sh`
Expected: three `ok` lines, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/test-monitor-arming-contract.sh skills/board/SKILL.md skills/board/watch-agents.py
git commit -m "The Monitor call omitted a required argument, and named one a newer harness removed

sdk-tools.d.ts declares timeout_ms required on Claude Code 2.1.228 and on
2.1.275, and the documented call shipped without it. 2.1.275 also removed
persistent, which 2.1.228 requires, so no single call works on both. A tick
whose arming is rejected arms nothing, and the board keeps merging cards one
TICK_INTERVAL_MINUTES slower on every finished agent with nothing saying so.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The stamp

`watch-agents.py` runs only while a Monitor is alive. Make its execution a fact on disk.

**Files:**
- Modify: `skills/board/watch-agents.py` (add `STAMP_PATH`, `stamp()`, call it in `main()`)
- Test: `tests/test-monitor-stamp.sh`

**Interfaces:**
- Consumes: `reconcile.BOARD_HOME`, already imported at `skills/board/watch-agents.py:62`.
- Produces: `$BOARD_HOME/monitor.stamp`, a file holding one ISO-8601 UTC timestamp and a trailing newline. Its **mtime** is what Task 3 reads.

- [ ] **Step 1: Write the failing test**

Create `tests/test-monitor-stamp.sh`:

```bash
#!/usr/bin/env bash
# watch-agents.py must stamp $BOARD_HOME/monitor.stamp on every poll, including
# the silent seeding poll and a poll that sees no dispatched agents. The stamp
# is the only evidence that a Monitor is armed: a Monitor lives inside the
# session and nothing persists it, and a tick asked to report its own arming
# reports intent rather than liveness. A board with no agents in flight must
# still stamp, or an idle board reads as an unarmed one and stops the machine.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
  python3 - "$board_dir" <<'PY'
import importlib.util
import os
import sys
import time

board_dir = sys.argv[1]
sys.path.insert(0, board_dir)

spec = importlib.util.spec_from_file_location(
    "watch_agents", os.path.join(board_dir, "watch-agents.py")
)
watch_agents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch_agents)

stamp_path = watch_agents.STAMP_PATH
assert not os.path.exists(stamp_path), "the fixture must start with no stamp"

# A poll that finds nothing must still stamp. An idle board is not an unarmed
# one, and main()'s loop skips an empty poll -- so the stamp cannot live after
# that skip.
watch_agents.stamp()
assert os.path.exists(stamp_path), f"no stamp written at {stamp_path}"
first = os.path.getmtime(stamp_path)

body = open(stamp_path).read()
assert body.endswith("\n"), f"stamp must end with a newline, got {body!r}"
time.strptime(body.strip(), "%Y-%m-%dT%H:%M:%SZ")

# Every poll refreshes it. A stamp written once proves a process started; a
# stamp refreshed every WATCH_POLL_SECONDS proves the Monitor is alive now.
time.sleep(1.1)
watch_agents.stamp()
second = os.path.getmtime(stamp_path)
assert second > first, f"stamp not refreshed: {first} then {second}"

print("ok   watch-agents.py stamps on every poll, empty or not")
PY
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-monitor-stamp.sh`
Expected: FAIL with `AttributeError: module 'watch_agents' has no attribute 'STAMP_PATH'`.

- [ ] **Step 3: Write the minimal implementation**

In `skills/board/watch-agents.py`, after the `BOARD_NAME_PREFIX` assignment (around line 64), add:

```python
# PROOF THAT A MONITOR IS ARMED. This process runs only while one is alive, so
# its own execution is the fact worth recording. The tick cannot report this:
# asked whether it armed a Monitor it reports intent, and a call rejected by a
# newer harness reports armed just as readily. The harness cannot report it
# either -- a Monitor lives inside the session and nothing persists it.
#
# Read by reconcile.py --monitor-stamps, and through it by dispatch.sh,
# supervise.sh and bin/dashboard.py. The mtime is what those read; the contents
# are for a human who opens the file.
STAMP_PATH = os.path.join(reconcile.BOARD_HOME, "monitor.stamp")


def stamp() -> None:
    """Refresh STAMP_PATH. Called on every poll, including the seeding one.

    WRITTEN VIA A TEMPORARY AND RENAMED, so a reader never sees a half-written
    file and mistakes a truncated stamp for a corrupt one. os.replace is atomic
    within a directory.

    A FAILURE HERE IS SWALLOWED, and that is not the same as ignored. The watch
    must keep emitting: its wakeups are useful even when the stamp is not
    writable. The gates then halt foreman on the stale stamp, which is the
    correct outcome -- a board whose runtime directory cannot be written is not
    a board that should be dispatching.
    """
    try:
        tmp = f"{STAMP_PATH}.tmp"
        with open(tmp, "w") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
        os.replace(tmp, STAMP_PATH)
    except OSError:
        pass
```

- [ ] **Step 4: Call it on every poll**

Replace `main()` at `skills/board/watch-agents.py:157-163`:

```python
def main() -> int:
    stamp()
    seen = poll()          # seed silently
    while True:
        time.sleep(POLL_SECONDS)
        # BEFORE the poll and BEFORE the empty-poll skip below, for two
        # reasons. A board with no dispatched agents polls empty and `continue`s
        # -- stamping after that would read an idle board as an unarmed one and
        # stop the machine. And a registry read that hangs takes up to its own
        # 30s timeout, so stamping first bounds the gap between stamps at
        # WATCH_POLL_SECONDS + 30 = 45s, inside MONITOR_STALE_SECONDS of 60.
        stamp()
        now = poll()
        if not now:
            continue
```

Leave the rest of the loop unchanged.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-monitor-stamp.sh`
Expected: `ok   watch-agents.py stamps on every poll, empty or not`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/test-monitor-stamp.sh skills/board/watch-agents.py
git commit -m "A Monitor that is armed now leaves evidence that it is

Nothing witnessed the arming. The only Monitor( outside SKILL.md was a
docstring here, no script armed one, and the single test mentioning Monitor
mentioned it in a comment -- so a tick that armed nothing passed the whole
suite and the board ran at heartbeat speed with no surface saying so.

This process runs only while a Monitor is alive, so it stamps
\$BOARD_HOME/monitor.stamp on every poll. Before the poll and before the
empty-poll skip: an idle board must not read as an unarmed one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The reader

One derivation of "is this board's Monitor alive", read by three consumers.

**Files:**
- Modify: `skills/board/config.sh` (add `MONITOR_STALE_SECONDS`, `MONITOR_GRACE_SECONDS` beside `DEMAND_STALE_MINUTES`, around line 450)
- Modify: `skills/board/reconcile.py` (add `monitor_stamps()` beside `host_slots()` at line 1328, and the `--monitor-stamps` branch beside `--host-slots` at line 3133)
- Test: `tests/test-monitor-stamps-reader.sh`

**Interfaces:**
- Consumes: `declared_boards(foreman_home)` at `skills/board/reconcile.py:1170`, `FOREMAN_HOME` at line 116.
- Produces: `reconcile.py --monitor-stamps`, printing JSON to stdout and exiting 0:

```json
{
  "boards": {"<board>": {"age_seconds": 12.4, "stale": false, "present": true}},
  "stale": ["<board>"],
  "ok": false,
  "stale_seconds": 60
}
```

  `ok` is `true` when `stale` is empty. A board with no stamp file is `present: false`, `stale: true`, `age_seconds: null`. Exit 2 when `boards.toml` will not load, printing `reconcile: ` plus the reason on stderr — consumers must refuse, never read that as "no boards".

- [ ] **Step 1: Write the failing test**

Create `tests/test-monitor-stamps-reader.sh`:

```bash
#!/usr/bin/env bash
# reconcile.py --monitor-stamps is the single derivation of "is this board's
# Monitor alive". dispatch.sh, supervise.sh and bin/dashboard.py all read it,
# so the staleness rule is spelled once. MONITOR_STALE_SECONDS is DERIVED from
# WATCH_POLL_SECONDS, for the reason DEMAND_STALE_MINUTES derives from
# TICK_INTERVAL_MINUTES: an operator who slows the poll widens the window with
# it, instead of silently breaking every gate.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

run() { HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
          "$board_dir/reconcile.py" --monitor-stamps; }

field() { python3 -c 'import json,sys; print(json.load(sys.stdin)["boards"]["demo"][sys.argv[1]])' "$1"; }

stamp="$py_home/.foreman/instances/demo/monitor.stamp"
fail=0

# A board with no stamp at all is stale, not absent from the report. A missing
# stamp is the fault this exists to catch, so it must never read as "no answer".
out="$(run)"
[[ "$(printf '%s' "$out" | field present)" == "False" ]] || { echo "FAIL missing stamp not reported" >&2; fail=1; }
[[ "$(printf '%s' "$out" | field stale)" == "True" ]] || { echo "FAIL missing stamp not stale" >&2; fail=1; }
[[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')" == "False" ]] \
  || { echo "FAIL ok true with a missing stamp" >&2; fail=1; }

# A stamp written now is fresh.
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] || { echo "FAIL fresh stamp read as stale" >&2; fail=1; }

# A stamp older than MONITOR_STALE_SECONDS is stale. 61s beats the default 60.
touch -t "$(date -u -r "$(( $(date +%s) - 61 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d @"$(( $(date +%s) - 61 ))" +%Y%m%d%H%M.%S)" "$stamp"
out="$(run)"
[[ "$(printf '%s' "$out" | field stale)" == "True" ]] || { echo "FAIL 61s-old stamp read as fresh" >&2; fail=1; }

# The window follows the poll. At WATCH_POLL_SECONDS=60 the window is 240s, so
# the same 61s-old stamp is fresh.
out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
        WATCH_POLL_SECONDS=60 "$board_dir/reconcile.py" --monitor-stamps)"
[[ "$(printf '%s' "$out" | field stale)" == "False" ]] \
  || { echo "FAIL MONITOR_STALE_SECONDS does not follow WATCH_POLL_SECONDS" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --monitor-stamps classifies missing, fresh and stale"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-monitor-stamps-reader.sh`
Expected: FAIL — `reconcile.py` treats `--monitor-stamps` as a ticket id and exits non-zero.

- [ ] **Step 3: Add the two settings to config.sh**

In `skills/board/config.sh`, immediately after the `DEMAND_STALE_MINUTES` line (currently line 450), add:

```bash
# How long a board's monitor.stamp may go unrefreshed before its Monitor counts
# as not armed. watch-agents.py stamps it every WATCH_POLL_SECONDS, and that
# process runs only while a Monitor is alive.
#
# DERIVED FROM THE POLL, not stated, for the reason DEMAND_STALE_MINUTES is
# derived from TICK_INTERVAL_MINUTES: an operator who slows the poll widens
# this with it, instead of silently breaking every gate that reads it.
#
# FOUR POLLS. The gap between two stamps is at most WATCH_POLL_SECONDS plus the
# 30s timeout on the registry read the loop makes between them -- 45s with the
# default poll of 15. Four polls is 60s, which clears that without calling a
# live Monitor dead, and is short enough that a dead one is caught inside a
# minute.
MONITOR_STALE_SECONDS="${MONITOR_STALE_SECONDS:-$(( ${WATCH_POLL_SECONDS:-15} * 4 ))}"

# How long after a tick starts before supervise.sh acts on a stale stamp.
#
# Nothing is armed in the first seconds of a fresh tick, by definition. 120s is
# longer than a tick needs to read its inbox, list its boards and arm one
# Monitor each, and far shorter than TICK_BUDGET_MINUTES.
#
# ONLY supervise.sh reads this. dispatch.sh needs no grace: arming happens at
# the top of a tick and a dispatch happens later in the same pass, so a stamp is
# already fresh by the time dispatch.sh runs.
MONITOR_GRACE_SECONDS="${MONITOR_GRACE_SECONDS:-120}"
```

Add `MONITOR_STALE_SECONDS` and `MONITOR_GRACE_SECONDS` to the list of keys `reconcile.py` reads — in `skills/board/reconcile.py:47`, extend the tuple passed to `_load_config` to include both names.

- [ ] **Step 4: Add the reader to reconcile.py**

In `skills/board/reconcile.py`, immediately before `def host_slots(` at line 1328, add:

```python
MONITOR_STALE_SECONDS = float(_CFG.get("MONITOR_STALE_SECONDS") or 60)


def monitor_stamps(foreman_home: str = FOREMAN_HOME) -> dict:
    """Is every declared board's agent Monitor alive right now?

    ONE DERIVATION, THREE READERS. dispatch.sh refuses on a stale stamp,
    supervise.sh stops the tick on one, and bin/dashboard.py shows it. Spelling
    the rule once is why `--host-slots` exists in this file rather than in each
    caller, and this answers the same shape of question over the same local
    files.

    A MISSING STAMP IS STALE, never absent. A board that never armed a Monitor
    is the fault this exists to catch; reporting it as "no answer" would let a
    caller skip the gate, which is how the slot ceilings were once disabled with
    nothing on stderr.

    RAISES BoardsUnreadable when boards.toml will not load, exactly as
    host_slots() does. A roster nobody can read must never read as a machine
    with nothing to check.
    """
    now = time.time()
    boards = {}
    for board in declared_boards(foreman_home):
        path = os.path.join(foreman_home, "instances", board, "monitor.stamp")
        try:
            age = now - os.path.getmtime(path)
        except OSError:
            boards[board] = {"age_seconds": None, "stale": True, "present": False}
            continue
        boards[board] = {
            "age_seconds": round(age, 1),
            "stale": age > MONITOR_STALE_SECONDS,
            "present": True,
        }
    stale = sorted(n for n, b in boards.items() if b["stale"])
    return {
        "boards": boards,
        "stale": stale,
        "ok": not stale,
        "stale_seconds": MONITOR_STALE_SECONDS,
    }
```

Confirm `time` and `os` are already imported at the top of `reconcile.py`; both are.

- [ ] **Step 5: Add the argv branch**

In `skills/board/reconcile.py`, immediately after the `--host-slots` branch (line 3133-3139), add:

```python
    if argv[0] == "--monitor-stamps":
        # Local files only, like --host-slots: a gate that needed the network to
        # answer would fail open on every rate limit.
        try:
            json.dump(monitor_stamps(), sys.stdout, indent=2)
        except BoardsUnreadable as exc:
            print(f"reconcile: {exc}", file=sys.stderr)
            return 2
        print()
        return 0
```

Add the usage line beside the `--host-slots` one at line 2979:

```python
              "       reconcile.py --monitor-stamps\n"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-monitor-stamps-reader.sh`
Expected: `ok   --monitor-stamps classifies missing, fresh and stale`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tests/test-monitor-stamps-reader.sh skills/board/config.sh skills/board/reconcile.py
git commit -m "One derivation of whether a board's Monitor is alive

dispatch.sh, supervise.sh and bin/dashboard.py all need the same answer, so the
staleness rule is spelled once here rather than three times. A missing stamp is
stale and never absent: a board that armed nothing is the fault this exists to
catch, and reporting it as no answer would let a caller skip the gate.

MONITOR_STALE_SECONDS derives from WATCH_POLL_SECONDS, the way
DEMAND_STALE_MINUTES derives from TICK_INTERVAL_MINUTES, so an operator who
slows the poll widens the window instead of breaking every gate that reads it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The dispatch gate

No dispatch on any board while any board's Monitor is not alive.

**Files:**
- Modify: `skills/board/dispatch.sh` (new gate after the preflight gate at line 59-64, before the slot gates at line 100)
- Test: `tests/test-dispatch-refuses-stale-monitor.sh`

**Interfaces:**
- Consumes: `reconcile.py --monitor-stamps` from Task 3 — the `ok` and `stale` fields.
- Produces: nothing other tasks read.

- [ ] **Step 1: Write the failing test**

Create `tests/test-dispatch-refuses-stale-monitor.sh`:

```bash
#!/usr/bin/env bash
# dispatch.sh must refuse while any board's Monitor is not alive. Machine-wide,
# because a rejected Monitor call is evidence about the harness contract and
# every board on the machine shares one harness.
#
# The gate belongs here rather than only in SKILL.md so that it holds however
# the script is called -- by the tick, by a resume, or by hand. That is the same
# reason the preflight and slot gates live here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"

prompt="$work_dir/prompt.txt"
echo "build the card" >"$prompt"
stamp="$py_home/.foreman/instances/demo/monitor.stamp"
fail=0

attempt() {
  HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
    "$board_dir/dispatch.sh" --ticket DEMO-1 --role build --attempt 1 \
    --prompt-file "$prompt" 2>&1
}

# No stamp at all: refuse, and say so in the same voice as the other gates.
if out="$(attempt)"; then
  echo "FAIL dispatched with no monitor stamp" >&2; fail=1
else
  printf '%s' "$out" | grep -q "refusing to dispatch" \
    || { echo "FAIL refusal does not name itself: $out" >&2; fail=1; }
  printf '%s' "$out" | grep -q "must not consume its attempt budget" \
    || { echo "FAIL refusal charges the ticket an attempt: $out" >&2; fail=1; }
fi

# A stale stamp: refuse.
touch -t "$(date -u -r "$(( $(date +%s) - 300 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d @"$(( $(date +%s) - 300 ))" +%Y%m%d%H%M.%S)" "$stamp"
if attempt >/dev/null 2>&1; then
  echo "FAIL dispatched with a stale monitor stamp" >&2; fail=1
fi

# A fresh stamp: the monitor gate must not be what stops it. Any later gate may
# still refuse in this fixture, so assert on the message rather than the exit.
date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
out="$(attempt || true)"
printf '%s' "$out" | grep -q "no board on this machine has a live agent Monitor" \
  && { echo "FAIL monitor gate refused a fresh stamp: $out" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   dispatch.sh refuses while a Monitor is not alive"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-dispatch-refuses-stale-monitor.sh`
Expected: FAIL on the first case — dispatch proceeds past a missing stamp.

- [ ] **Step 3: Add the gate**

In `skills/board/dispatch.sh`, after the preflight gate's closing `fi` (line 64) and before the concurrency comment at line 66, add:

```bash
# THE EDGE-TRIGGER MUST BE ALIVE BEFORE ANYTHING IS DISPATCHED.
#
# A board whose Monitor is not armed still works: it dispatches, reviews and
# merges. It is slower by up to one TICK_INTERVAL_MINUTES on every finished
# agent, and no surface says so -- waiting looks exactly like running. Measured
# 2026-09-22 across five cards, dispatch to first commit ran from 38 minutes to
# 33 hours, against about five minutes for a hand-driven pull request in the
# same window.
#
# HELD HERE AND NOT ONLY IN SKILL.md, for the reason the preflight above is: a
# tick asked in prose to stop when a Monitor fails to arm may carry on instead,
# and that is the failure this gate exists to remove.
#
# MACHINE-WIDE, not this board alone. A rejected Monitor call is evidence about
# the harness contract, and every board on this machine shares one harness.
if ! STAMPS="$("$SKILL_DIR/reconcile.py" --monitor-stamps)"; then
  die "could not read the machine's monitor stamps; refusing to dispatch $NAME.
reconcile.py's own message is above: a boards.toml that will not load, or
foreman's own scripts being unrunnable.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget.
Repair the machine, then dispatch again at the same attempt number."
fi
if ! printf '%s' "$STAMPS" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["ok"] else 1)'; then
  die "no board on this machine has a live agent Monitor; refusing to dispatch $NAME.
Stale or missing: $(printf '%s' "$STAMPS" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["stale"]))')
A board whose Monitor is not armed runs at heartbeat speed and says nothing.
Arm it as skills/board/SKILL.md describes, then dispatch again at the same
attempt number.
This is NOT a failure of ticket $TICKET and must not consume its attempt budget."
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-dispatch-refuses-stale-monitor.sh`
Expected: `ok   dispatch.sh refuses while a Monitor is not alive`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/test-dispatch-refuses-stale-monitor.sh skills/board/dispatch.sh
git commit -m "Refuse to dispatch while the edge-trigger is not alive

A board whose Monitor is not armed still dispatches, reviews and merges. It is
slower by up to one TICK_INTERVAL_MINUTES on every finished agent, and nothing
says so -- waiting looks exactly like running.

Held here and not only in SKILL.md, for the reason the preflight gate above is:
a tick asked in prose to stop when arming fails may carry on instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The supervisor halt

foreman goes down, and stays down, until an operator repairs it.

**Files:**
- Modify: `skills/board/supervise.sh` (add `monitor_stale_board()` beside `find_starved_board()` at line 860, `halt_foreman()` beside `repair_tick`, and a branch in the decision chain at line 900)
- Test: `tests/test-supervise-halts-on-stale-monitor.sh`

**Interfaces:**
- Consumes: `reconcile.py --monitor-stamps` from Task 3; `AGE` (tick age in hours) and `ID`, both already set by `inspect()` at `skills/board/supervise.sh:209`.
- Produces: nothing other tasks read.

- [ ] **Step 1: Write the failing test**

Create `tests/test-supervise-halts-on-stale-monitor.sh`:

**This test drives the real `supervise.sh`**, as `AGENTS.md` requires. Do not write a `grep`-the-source test; this branch stops the whole machine and must be proven by behaviour.

Copy the fixture preamble verbatim from `tests/test-supervise-restarts-a-tick-starving-todo.sh:1-60` — it already builds everything needed: the `unset` block that stops an inherited board slice answering for the fixture, a bare origin repository, `fixture_board_toml`, the stub `claude` on `PATH` from `tests/lib/harness-stub.sh`, and a stub `gh`. In your copy, add `MONITOR_STALE_SECONDS MONITOR_GRACE_SECONDS` to that `unset` list, since the environment wins over `config.sh`. Do not edit the model file.

Then the deltas that make it this test. The stamp lives at `$FOREMAN_HOME/instances/<board>/monitor.stamp`:

```bash
stamp="$work/home/.foreman/instances/demo/monitor.stamp"
mkdir -p "$(dirname "$stamp")"

age_stamp() { # <seconds old>
  local t
  t="$(date -u -r "$(( $(date +%s) - $1 ))" +%Y%m%d%H%M.%S 2>/dev/null \
       || date -u -d @"$(( $(date +%s) - $1 ))" +%Y%m%d%H%M.%S)"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  touch -t "$t" "$stamp"
}

# 1. A live tick past the grace, with a stale stamp: halt, and say which board.
age_stamp 600
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && printf '%s' "$out" | grep -q 'demo' \
  && ok "a stale stamp halts foreman and names the board" \
  || bad "a stale stamp did not halt foreman: $out"

# 2. THE POINT OF THIS TEST: it must not come back. A restart against a harness
#    that rejects the Monitor call arms nothing again and loops forever.
printf '%s' "$out" | grep -qi 'started .*tick' \
  && bad "halt started a replacement tick; it must not" \
  || ok "halt does not start a replacement"

# 3. A fresh stamp leaves the tick alone.
age_stamp 0
out="$(run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && bad "a fresh stamp halted foreman: $out" \
  || ok "a fresh stamp does not halt"

# 4. A tick younger than MONITOR_GRACE_SECONDS is left alone even with no stamp
#    at all. Nothing is armed in the first seconds of a tick, by definition, and
#    halting there would stop every replacement before its first pass.
rm -f "$stamp"
out="$(MONITOR_GRACE_SECONDS=86400 run_supervise 2>&1)"
printf '%s' "$out" | grep -q 'HALTING foreman' \
  && bad "halted inside the grace period: $out" \
  || ok "a tick inside MONITOR_GRACE_SECONDS is left alone"
```

Define `run_supervise` to invoke `"$supervise"` with the fixture's `HOME` and `FOREMAN_HOME`, matching how the model file invokes it. Keep that file's `ok`/`bad`/`fail` helpers and its `exit "$fail"`.

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-supervise-halts-on-stale-monitor.sh`
Expected: FAIL on every check, exit 1.

- [ ] **Step 3: Add the reader and the halt**

In `skills/board/supervise.sh`, immediately after `find_starved_board()`'s closing `}` (line 889), add:

```bash
# Is any declared board's agent Monitor not alive? Sets MONITOR_STALE_REASON.
#
# reconcile.py owns the staleness rule; this only asks. Two readers of one
# setting is the drift config.sh warns about throughout.
monitor_stale_board() {
  local out
  MONITOR_STALE_REASON=""
  if ! out="$("$SKILL_DIR/reconcile.py" --monitor-stamps 2>/dev/null)"; then
    # Unreadable is not the same as stale. A boards.toml that will not load is
    # already the corpse/starved branches' problem, and halting the machine on
    # a failed read would stop it for a fault it cannot name.
    log "monitor: could not read the monitor stamps; leaving the tick alone"
    return 1
  fi
  MONITOR_STALE_REASON="$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d["ok"]:
    sys.exit(0)
stale = ", ".join(d["stale"])
secs = d["stale_seconds"]
print(f"no live agent Monitor on: {stale} (stamp older than {secs:.0f}s)")
')"
  [[ -n "$MONITOR_STALE_REASON" ]]
}

# Has this tick been running long enough to have armed its Monitors?
#
# Nothing is armed in the first seconds of a fresh tick, by definition. AGE is
# in hours, from inspect(); MONITOR_GRACE_SECONDS is in seconds.
tick_outlived_monitor_grace() {
  [[ "$AGE" != "None" ]] || return 1
  awk "BEGIN{exit !($AGE * 3600 > $MONITOR_GRACE_SECONDS)}"
}

# Stop every tick and start nothing. THE ONE BRANCH THAT DOES NOT RESTART.
#
# A tick restarted against a harness that rejects the Monitor call arms nothing
# again, and the next fire does it again: a slow machine turned into a thrashing
# one. The trigger is a changed tool contract, which no restart repairs.
#
# What an operator does next is in docs/specs/2026-09-22-monitor-liveness-design.md:
# correct the call in SKILL.md, then start the tick again.
halt_foreman() {
  log "HALTING foreman: $MONITOR_STALE_REASON"
  log "a board with no armed Monitor runs at heartbeat speed and says nothing;"
  log "this does NOT restart, because a restart would arm nothing again."
  log "correct the Monitor call in skills/board/SKILL.md, then start the tick."
  stop_ticks
}
```

- [ ] **Step 4: Add the branch to the decision chain**

In `skills/board/supervise.sh`, between the `TICK_DEAD_MINUTES` branch and the `tick_outlived_starved_window` branch (after line 903), add:

```bash
# AFTER the liveness branches above: a tick that is not running cannot have
# armed anything, and halting for that would hide the real fault. BEFORE the
# starved and recycle branches, because both of those restart, and a machine
# whose edge-trigger is gone must stop rather than cycle.
elif tick_outlived_monitor_grace && monitor_stale_board; then
  halt_foreman
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-supervise-halts-on-stale-monitor.sh`
Expected: `ok   supervise.sh halts, does not restart, and respects the grace`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/test-supervise-halts-on-stale-monitor.sh skills/board/supervise.sh
git commit -m "A machine whose edge-trigger is gone stops, and stays stopped

This is the one watchdog branch that does not restart. The trigger is a changed
tool contract -- Claude Code 2.1.275 removed the persistent argument 2.1.228
requires -- and no restart repairs that. A tick restarted against a harness that
rejects the call arms nothing again, turning a slow machine into a thrashing
one.

It sits after the liveness branches: a tick that is not running cannot have
armed anything, and halting for that would hide the real fault.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The dashboard surface

An operator reading the page sees the stopped machine and its cause together.

**`bin/dashboard.py` derives nothing.** Its own header says so: "Every number comes from `reconcile.py --overview`." So the monitor state joins `--overview`'s per-board row, and the page renders it. A second subprocess call from the dashboard would put a second reader of the same fact beside the first, which is the drift `reconcile.py:_load_config` warns about.

**Files:**
- Modify: `skills/board/reconcile.py` (`overview()` at line 2809, the per-board dict)
- Modify: `bin/dashboard.py` (render the new field)
- Test: `tests/test-dashboard-shows-monitor.sh`

**Interfaces:**
- Consumes: `monitor_stamps()` from Task 3.
- Produces: a `monitor` key on each board in `reconcile.py --overview`, shaped `{"present": bool, "stale": bool, "age_seconds": float | null}` — the same per-board value `--monitor-stamps` prints.

- [ ] **Step 1: Write the failing test**

Create `tests/test-dashboard-shows-monitor.sh`:

```bash
#!/usr/bin/env bash
# --overview must carry each board's monitor state, so the page can name the
# board whose Monitor is not alive and the age of its stamp. A halted machine
# whose page does not say why sends the operator to the logs, and the halt is
# the one state where that costs the most.
#
# It rides on --overview rather than a second call from bin/dashboard.py,
# because that file derives nothing: every number on the page comes from one
# --overview. Two readers of one fact is the drift _load_config warns about.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_repo="$work_dir/target"
mkdir -p "$fixture_repo"
fixture_board_toml "$fixture_repo"
py_home="$work_dir/py-home"
fixture_add_instance "$py_home" demo "$fixture_repo"
fail=0

out="$(HOME="$py_home" FOREMAN_HOME="$py_home/.foreman" FOREMAN_INSTANCE=demo \
       "$board_dir/reconcile.py" --overview)" \
  || { echo "FAIL --overview did not answer" >&2; exit 1; }

# A board with no stamp reports stale, and --overview stays TOLERANT: it must
# report what it could reach, never raise. A crash renders as nothing at all.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
board = next(b for b in d["boards"] if b["name"] == "demo")
m = board["monitor"]
assert m["present"] is False, m
assert m["stale"] is True, m
assert m["age_seconds"] is None, m
' || { echo "FAIL --overview does not carry monitor state" >&2; fail=1; }

# The page must render it. It reads --overview and nothing else.
grep -q 'monitor' "$repo_root/bin/dashboard.py" \
  || { echo "FAIL dashboard.py does not render the monitor field" >&2; fail=1; }
python3 -c "import ast; ast.parse(open('$repo_root/bin/dashboard.py').read())" \
  || { echo "FAIL dashboard.py does not parse" >&2; fail=1; }

[[ "$fail" -eq 0 ]] && echo "ok   --overview carries monitor state and the page renders it"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/test-dashboard-shows-monitor.sh`
Expected: FAIL with `KeyError: 'monitor'`.

- [ ] **Step 3: Carry the monitor state on --overview**

In `skills/board/reconcile.py`, inside `overview()`, before the loop that builds the per-board dicts, add:

```python
    # TOLERANT, like every other field here: a roster that will not load is
    # reported, never raised. bin/dashboard.py renders a failed --overview as a
    # problem, and a crash would render as nothing at all.
    try:
        monitors = monitor_stamps()["boards"]
    except BoardsUnreadable:
        monitors = {}
```

Then add one key to the per-board dict, beside `"halted"`:

```python
            "monitor": monitors.get(
                name, {"present": False, "stale": True, "age_seconds": None}
            ),
```

A board missing from `monitors` defaults to stale rather than absent, for the reason `monitor_stamps()` does: a board that armed nothing is the fault this exists to catch.

- [ ] **Step 4: Render it on the page**

In `bin/dashboard.py`, find where the per-board row renders `halted` and add the monitor beside it, in that file's existing idiom. The rule the text must satisfy: when `stale` is true, the row says so and gives `age_seconds` rounded to whole seconds, or "never" when `present` is false.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-dashboard-shows-monitor.sh`
Expected: `ok   --overview carries monitor state and the page renders it`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/test-dashboard-shows-monitor.sh bin/dashboard.py
git commit -m "Say which board has no live Monitor, and how old its stamp is

A halted machine whose page does not say why sends the operator to the logs,
and the halt is the one state where that costs the most.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Whole-suite verification

**Files:** none modified.

- [ ] **Step 1: Run the whole suite**

Run: `tests/run-all.sh`
Expected: every assertion passes, every source parses, exit 0. Record the counts; `AGENTS.md` expects a pull request body to state them.

- [ ] **Step 2: Confirm the naming constraint still holds**

Run: `bash tests/test-no-target-specifics.sh`
Expected: `ok   no target-specific identifiers outside docs/ and README.md`.

- [ ] **Step 3: Confirm the gate actually gates**

With a fresh fixture and no stamp, `dispatch.sh` must refuse. This is the assertion the whole plan exists for, and Task 4's test covers it — re-run it alone and read the output rather than trusting the suite's summary:

Run: `bash tests/test-dispatch-refuses-stale-monitor.sh`
Expected: `ok   dispatch.sh refuses while a Monitor is not alive`.

- [ ] **Step 4: Commit nothing**

There is nothing to commit. If the suite failed, return to the task that owns the failure rather than fixing it here.
