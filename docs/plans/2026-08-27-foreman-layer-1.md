# Foreman Layer 1 — the contract seam

> **For agentic workers:** implement this task-by-task, in order. Each task ends
> green and committed before the next begins. Steps use checkbox (`- [ ]`) syntax
> for tracking. This plan depends on no skill being installed anywhere.

**Goal:** A standalone repository holding a target-agnostic autonomous build loop, driven by one declarative contract file in the target repo, proven by building itself.

**Architecture:** murmr's board skill is copied verbatim in one commit, then generalised in reviewable deltas. The knobs that are facts about a *project* move into `board.toml` in the target repo; the knobs that are facts about an *installation* move into instance state under `~/.foreman/instances/<name>/`. `config.sh` stops deriving the repository from its own checkout location and starts being told. Agent names gain an instance segment so two installations cannot reap each other's agents.

**Tech Stack:** bash 3.2-compatible shell, Python 3.11+ stdlib only (`tomllib`), `git`, `gh`, `claude` CLI, Linear MCP/API.

**Spec:** `2026-08-27-autonomous-board-runner-design.md` (ships alongside this plan; both become the new repo's first commit)

## Global Constraints

- **murmr is never modified.** No task may write, move or delete anything under the murmr checkout. Reads are fine — every seed copy is a read.
- **Repository root:** `~/Developer/foreman`. Never created inside the murmr checkout or any of its worktrees.
- **No third-party Python dependencies.** Stdlib only, as the copied code already is. This is why the contract is TOML and not YAML — `tomllib` is stdlib from 3.11, `pyyaml` is not. **This deviates from the spec, which said `board.yaml`.** The deviation is deliberate and preserves the property that made the original installable anywhere: no install step before the config can be read.
- **bash 3.2 compatible.** macOS ships 3.2; `"${arr[@]}"` on an empty array under `set -u` is an error, so use the `"${arr[@]+"${arr[@]}"}"` form the copied code already uses.
- **The contract is parsed, never sourced.** No task may add a code path that `source`s a file from a target repository.
- **Every value keeps its environment-variable override.** The copied code's convention is `X="${X:-default}"`; preserve it. Use `-` and not `:-` where an explicitly empty value must mean "empty" rather than "absent" — `HIGH_RISK_PATHS` already depends on this.
- **Seed commit is separate.** Task 1's commit is a byte-identical copy. Every later commit is a readable delta against murmr's working design.
- **Placeholder name.** `foreman` is a working name. It appears in paths, the instance root, and agent name prefixes. If it changes, it changes in Task 1 before anything else is written.

---

### Task 1: Repository skeleton and verbatim seed

**Files:**
- Create: `~/Developer/foreman/` (git repo)
- Create: `foreman/README.md`, `foreman/LICENSE`, `foreman/.gitignore`
- Create: `foreman/skills/board/` ← copy of murmr `.claude/skills/board/`
- Create: `foreman/skills/adversarial-reviewer/` ← copy of murmr `.claude/skills/adversarial-reviewer/`
- Create: `foreman/bin/tmp-dir.sh` ← copy of murmr `ops/tmp-dir.sh`
- Create: `foreman/bin/check-syntax.sh` ← copy of murmr `ops/check-syntax.sh`
- Create: `foreman/tests/` ← copies of murmr `ops/tests/test-{evidence-reads-are-fresh,preflight-fetches-only-to-gate,board-deploy-outcomes,sweep-reaps-leaked-evidence-refs,tmp-dir,check-syntax}.sh`
- Create: `foreman/tests/lib/` ← copies of murmr `ops/tests/lib/{board-outcome-cases.py,curl-stub.sh}`
- Create: `foreman/docs/specs/2026-08-27-autonomous-board-runner-design.md`
- Create: `foreman/docs/plans/2026-08-27-foreman-layer-1.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the repository root `$FOREMAN` referred to by every later task; `skills/board/config.sh` with murmr's contents; `bin/tmp-dir.sh`; `tests/*.sh` each runnable as `tests/<name>.sh` from the repo root, exiting 0 on pass.

- [ ] **Step 1: Create the repository**

```bash
MURMR=~/Developer/murmr
FOREMAN=~/Developer/foreman
test ! -e "$FOREMAN" || { echo "refusing: $FOREMAN exists"; exit 1; }
mkdir -p "$FOREMAN" && git -C "$FOREMAN" init -b main
```

- [ ] **Step 2: Copy the code verbatim**

Nothing is edited in this task. `cp -R`, not `git mv` — murmr keeps its copy.

```bash
mkdir -p "$FOREMAN"/{skills,bin,tests/lib,docs/specs,docs/plans}
cp -R "$MURMR/.claude/skills/board" "$FOREMAN/skills/board"
cp -R "$MURMR/.claude/skills/adversarial-reviewer" "$FOREMAN/skills/adversarial-reviewer"
cp "$MURMR/ops/tmp-dir.sh" "$FOREMAN/bin/tmp-dir.sh"
cp "$MURMR/ops/check-syntax.sh" "$FOREMAN/bin/check-syntax.sh"
for t in evidence-reads-are-fresh preflight-fetches-only-to-gate \
         board-deploy-outcomes sweep-reaps-leaked-evidence-refs \
         tmp-dir check-syntax; do
  cp "$MURMR/ops/tests/test-$t.sh" "$FOREMAN/tests/"
done
cp "$MURMR/ops/tests/lib/board-outcome-cases.py" "$MURMR/ops/tests/lib/curl-stub.sh" "$FOREMAN/tests/lib/"
```

- [ ] **Step 3: Confirm murmr is untouched**

Run: `git -C ~/Developer/murmr status --porcelain`
Expected: no output. If anything appears, stop — a copy went the wrong way.

- [ ] **Step 4: Write `.gitignore` and a README stub**

`.gitignore`:

```
.claude/worktrees/
*.pyc
__pycache__/
```

`README.md`:

```markdown
# foreman

An autonomous build loop that lives outside the project it builds.

A card moved into `Todo` on a Linear board is the only dispatch authorisation.
Everything after that — building it in a worktree, reviewing the diff
adversarially by sessions that did not write it, gating the merge on evidence,
watching the deploy, writing follow-ups — happens without anyone present.

A repository becomes buildable by adding one `board.toml`. Forking this
repository gives you a project that already has a builder.

Seeded from the board orchestrator built inside `murmr`, which remains its own
installation. See `docs/specs/`.
```

`LICENSE`: MIT, copyright Praveen Venkatesh, 2026.

- [ ] **Step 5: Copy the spec and this plan into the repo**

```bash
SCRATCH=<this session's scratchpad>
cp "$SCRATCH/2026-08-27-autonomous-board-runner-design.md" "$FOREMAN/docs/specs/"
cp "$SCRATCH/2026-08-27-foreman-layer-1.md" "$FOREMAN/docs/plans/"
```

- [ ] **Step 6: Verify every copied script still parses**

Run: `cd "$FOREMAN" && bash bin/check-syntax.sh`
Expected: PASS. `check-syntax.sh` was written against murmr's layout; if it exits non-zero because it cannot find a path it expects, note the failing path and fix it in Task 2 — do not edit it here, the seed commit stays verbatim.

- [ ] **Step 7: Commit the seed**

```bash
cd "$FOREMAN" && git add -A && git commit -m "Seed from murmr's board orchestrator, verbatim

Copied unchanged so every later commit reads as a delta against a design
that is running in production somewhere else. murmr keeps its copy; the two
will drift, and that is accepted."
```

---

### Task 2: The contract loader

**Files:**
- Create: `foreman/bin/contract.py`
- Create: `foreman/tests/test-contract.sh`
- Create: `foreman/board.toml` (foreman's own, filled in Task 9; a minimal valid one now so the loader has a fixture)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `bin/contract.py <path-to-board.toml>` printing `KEY\0VALUE\0…` on stdout for shell consumption, exit 0 on a valid contract, exit 1 with a message on stderr naming the offending key otherwise. Keys produced: `TEST_COMMAND`, `BOOTSTRAP_COMMAND`, `REQUIRED_CHECKS` (pipe-joined), `CI_WORKFLOW`, `DEPLOY_WORKFLOW`, `DEPLOY_STEP`, `HIGH_RISK_PATHS` (space-joined), `REQUIRED_DOCS` (space-joined), `LINEAR_TEAM_NAME`, `LINEAR_PROJECT_NAME`, and every `limits.*` upper-cased (`MAX_CONCURRENT`, `MAX_BUILD_ATTEMPTS`, `MAX_REVIEW_ROUNDS`, `REVIEWERS_PER_ROUND`, `STALL_MINUTES`, `MAX_FOLLOWUPS`). Absent optional keys are emitted as empty strings, never omitted — a short read is how `_load_config` in `reconcile.py` and `preflight.py` detects failure.

- [ ] **Step 1: Write the failing test**

`tests/test-contract.sh`:

```bash
#!/usr/bin/env bash
# The contract is data. It is parsed, never sourced, and a contract that tries
# to be shell is inert rather than clever.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}
read_key() { # file key
  "$root/bin/contract.py" "$1" | python3 -c '
import sys
v = sys.stdin.buffer.read().split(b"\0")
d = dict(zip(v[::2], v[1::2]))
sys.stdout.write(d.get(sys.argv[1].encode(), b"<missing>").decode())
' "$2"
}

cat >"$work/full.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests", "Lint"]
ci_workflow = "CI"
[deploy]
workflow = "deploy.yml"
step = "Deploy and verify"
[risk]
paths = ["migrations/"]
[test]
command = "just test-all"
[bootstrap]
command = "uv sync"
[docs]
required = ["ENGINEERING.md"]
[limits]
max_concurrent = 2
TOML

check "required checks are pipe-joined" "Tests|Lint" "$(read_key "$work/full.toml" REQUIRED_CHECKS)"
check "risk paths are space-joined"     "migrations/" "$(read_key "$work/full.toml" HIGH_RISK_PATHS)"
check "test command"                    "just test-all" "$(read_key "$work/full.toml" TEST_COMMAND)"
check "limits are upper-cased"          "2" "$(read_key "$work/full.toml" MAX_CONCURRENT)"
check "unset limit falls back"          "2" "$(read_key "$work/full.toml" MAX_REVIEW_ROUNDS)"

# A target with no deployment. `deploy` absent means merged is done, and the
# keys must still be EMITTED empty -- a consumer detects failure by counting
# fields, so an omitted key reads as a config that would not load.
cat >"$work/nodeploy.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
TOML
check "absent deploy workflow is empty, not missing" "" "$(read_key "$work/nodeploy.toml" DEPLOY_WORKFLOW)"
check "absent deploy step is empty, not missing"     "" "$(read_key "$work/nodeploy.toml" DEPLOY_STEP)"

# An explicitly empty risk list means NOTHING is high risk. It must not fall
# back to a default -- the same distinction `HIGH_RISK_PATHS` uses `-` for.
cat >"$work/norisk.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[risk]
paths = []
[test]
command = "make test"
TOML
check "empty risk list stays empty" "" "$(read_key "$work/norisk.toml" HIGH_RISK_PATHS)"

# A missing REQUIRED key names itself. Merging with no required checks would
# merge a diff nothing tested.
cat >"$work/bad.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[test]
command = "make test"
TOML
if err="$("$root/bin/contract.py" "$work/bad.toml" 2>&1 >/dev/null)"; then
  printf 'FAIL missing checks.required must fail\n'; fail=1
else
  case "$err" in *checks.required*) printf 'ok   missing key names itself\n' ;;
    *) printf 'FAIL error did not name checks.required: %s\n' "$err"; fail=1 ;; esac
fi

# The contract is DATA. Shell in a value is a string.
cat >"$work/evil.toml" <<'TOML'
[linear]
team = "PRA"
project = "foreman"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "$(touch /tmp/foreman-pwned) `touch /tmp/foreman-pwned2`"
TOML
rm -f /tmp/foreman-pwned /tmp/foreman-pwned2
read_key "$work/evil.toml" TEST_COMMAND >/dev/null
if [[ -e /tmp/foreman-pwned || -e /tmp/foreman-pwned2 ]]; then
  printf 'FAIL loading a contract executed shell from it\n'; fail=1
else
  printf 'ok   contract values are inert\n'
fi

exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-contract.sh && tests/test-contract.sh`
Expected: FAIL — `bin/contract.py: No such file or directory`.

- [ ] **Step 3: Write `bin/contract.py`**

```python
#!/usr/bin/env python3
"""Read a target repository's contract and print it for shell consumers.

    contract.py path/to/board.toml

Emits NUL-separated KEY, VALUE pairs on stdout. Consumers count fields to
detect a failed load, so EVERY key is always emitted -- an optional entry that
is absent is emitted empty, never omitted.

PARSED, NEVER SOURCED. The obvious port of `config.sh` would be a shell file in
the target repository, and every knob there is already an environment variable.
It is refused: instances share a user and a home, so a config that can run code
runs beside every other instance's board credential, before anything has decided
whether that repository is trusted. TOML is stdlib from 3.11, which keeps the
"no install step before the config can be read" property that shell had.
"""

from __future__ import annotations

import sys
import tomllib

# (key, toml path, default). A default of None marks the entry REQUIRED.
#
# `checks.required` is required because merging with nothing required merges a
# diff that nothing tested. `test.command` is required because a build agent
# with no test command reports success from having written code.
SCALARS = [
    ("LINEAR_TEAM_NAME", ("linear", "team"), None),
    ("LINEAR_PROJECT_NAME", ("linear", "project"), None),
    ("CI_WORKFLOW", ("checks", "ci_workflow"), None),
    ("TEST_COMMAND", ("test", "command"), None),
    ("BOOTSTRAP_COMMAND", ("bootstrap", "command"), ""),
    ("DEPLOY_WORKFLOW", ("deploy", "workflow"), ""),
    ("DEPLOY_STEP", ("deploy", "step"), ""),
]

# (key, toml path, joiner, default). A default of None marks it REQUIRED.
#
# REQUIRED_CHECKS joins on "|" and the path lists join on " " because that is
# what the copied config.sh already splits on; changing the separator here
# without changing every splitter is a silent empty list.
LISTS = [
    ("REQUIRED_CHECKS", ("checks", "required"), "|", None),
    ("HIGH_RISK_PATHS", ("risk", "paths"), " ", []),
    ("REQUIRED_DOCS", ("docs", "required"), " ", []),
]

# Defaults live here rather than in config.sh so a target that says nothing
# still produces a full record. They are a CEILING per instance; the
# installation's own ceiling is separate and lives in instance state.
LIMITS = {
    "MAX_CONCURRENT": 1,
    "MAX_BUILD_ATTEMPTS": 2,
    "MAX_REVIEW_ROUNDS": 2,
    "REVIEWERS_PER_ROUND": 2,
    "STALL_MINUTES": 30,
    "MAX_FOLLOWUPS": 3,
}


def die(message: str) -> None:
    sys.stderr.write(f"contract: {message}\n")
    raise SystemExit(1)


def dig(doc: dict, path: tuple[str, ...]):
    """Return doc[a][b] or None. Absent and null are the same thing here."""
    node = doc
    for part in path:
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def load(path: str) -> list[tuple[str, str]]:
    try:
        with open(path, "rb") as fh:
            doc = tomllib.load(fh)
    except FileNotFoundError:
        die(f"no contract at {path}")
    except tomllib.TOMLDecodeError as exc:
        die(f"{path} is not valid TOML: {exc}")

    out: list[tuple[str, str]] = []

    for key, path_, default in SCALARS:
        value = dig(doc, path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, str):
            die(f"{path}: {'.'.join(path_)} must be a string")
        out.append((key, value))

    for key, path_, joiner, default in LISTS:
        value = dig(doc, path_)
        if value is None:
            if default is None:
                die(f"{path}: {'.'.join(path_)} is required")
            value = default
        if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
            die(f"{path}: {'.'.join(path_)} must be a list of strings")
        # An EMPTY list is a statement, not an absence: "nothing is high risk".
        # It must survive as an empty string rather than reinstating a default.
        if key == "REQUIRED_CHECKS" and not value:
            die(f"{path}: checks.required must name at least one check")
        if any(joiner in v for v in value):
            die(f"{path}: {'.'.join(path_)} entries may not contain {joiner!r}")
        out.append((key, joiner.join(value)))

    limits = dig(doc, ("limits",)) or {}
    if not isinstance(limits, dict):
        die(f"{path}: limits must be a table")
    unknown = sorted(set(limits) - {k.lower() for k in LIMITS})
    if unknown:
        die(f"{path}: unknown limits: {', '.join(unknown)}")
    for key, fallback in LIMITS.items():
        value = limits.get(key.lower(), fallback)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            die(f"{path}: limits.{key.lower()} must be a non-negative integer")
        out.append((key, str(value)))

    return out


def main() -> int:
    if len(sys.argv) != 2:
        die("usage: contract.py <path-to-board.toml>")
    pairs = load(sys.argv[1])
    blob = b"\0".join(part.encode() for pair in pairs for part in pair)
    sys.stdout.buffer.write(blob + b"\0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x bin/contract.py && tests/test-contract.sh`
Expected: every line `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/contract.py tests/test-contract.sh
git commit -m "A target declares itself in one file, parsed and never sourced"
```

---

### Task 3: config.sh is told its repository instead of deriving it

**Files:**
- Modify: `foreman/skills/board/config.sh:8-32` (the `--git-common-dir` derivation), `:33` (`BOARD_HOME`), `:34-49` (Linear ids), `:68-73` (limits), `:133-143` (checks and deploy), `:213` (`AGENT_TMP_ROOT`)
- Create: `foreman/tests/test-config-resolves-instance.sh`

**Interfaces:**
- Consumes: `bin/contract.py` from Task 2.
- Produces: sourcing `skills/board/config.sh` with `FOREMAN_INSTANCE=<name>` set exports `REPO`, `INSTANCE`, `INSTANCE_HOME`, `BOARD_HOME`, plus every key `contract.py` emits and every id from `$INSTANCE_HOME/ids.env`. Environment variables set before sourcing still win over both.

Instance state layout, established here and depended on by Tasks 4, 6, 9 and 10:

```
~/.foreman/instances/<name>/
  instance.env     REPO=/abs/path  (KEY=VALUE, one per line, no quoting, no shell)
  ids.env          LINEAR_TEAM_ID=…  LINEAR_PROJECT_ID=…  STATE_*  LABEL_*   (written by Task 4)
  linear.key       the board credential, mode 0600
  cards/<TICKET>/history.jsonl
```

- [ ] **Step 1: Write the failing test**

`tests/test-config-resolves-instance.sh`:

```bash
#!/usr/bin/env bash
# config.sh is TOLD which repository it serves. Deriving it from the skill's own
# checkout is correct for a skill committed into the repo it builds and wrong
# for one installed once and pointed at many -- and the wrong answer is silent:
# the board would cut worktrees in its own installation directory.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi }

target="$work/target"; mkdir -p "$target"; git -C "$target" init -q -b main
cat >"$target/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "make test"
[limits]
max_concurrent = 3
TOML

home="$work/home"; inst="$home/.foreman/instances/demo"; mkdir -p "$inst"
printf 'REPO=%s\n' "$target" >"$inst/instance.env"
printf 'LINEAR_TEAM_ID=team-uuid\nLINEAR_PROJECT_ID=project-uuid\n' >"$inst/ids.env"

ask() { # VAR [env assignments...]
  local var="$1"; shift
  env HOME="$home" FOREMAN_INSTANCE=demo "$@" \
    bash -c ". '$root/skills/board/config.sh' >/dev/null; printf '%s' \"\$$var\""
}

check "REPO comes from the instance"     "$target"     "$(ask REPO)"
check "contract reaches config"          "make test"   "$(ask TEST_COMMAND)"
check "contract limits reach config"     "3"           "$(ask MAX_CONCURRENT)"
check "ids reach config"                 "team-uuid"   "$(ask LINEAR_TEAM_ID)"
check "env beats contract"               "make fast"   "$(ask TEST_COMMAND TEST_COMMAND='make fast')"
check "env beats ids"                    "other"       "$(ask LINEAR_TEAM_ID LINEAR_TEAM_ID=other)"
check "instance name is exported"        "demo"        "$(ask INSTANCE)"

# REPO must NOT be the foreman checkout. This is the bug the change exists to
# prevent, so assert on it directly rather than trusting the positive case.
[[ "$(ask REPO)" != "$root" ]] && printf 'ok   REPO is not the installation\n' \
  || { printf 'FAIL REPO resolved to the foreman checkout\n'; fail=1; }

# An unknown instance fails closed and NAMES itself. Falling back to a default
# instance would point a live board at the wrong repository.
if err="$(env HOME="$home" FOREMAN_INSTANCE=nope bash -c \
     ". '$root/skills/board/config.sh'" 2>&1)"; then
  printf 'FAIL an unknown instance must fail\n'; fail=1
else
  case "$err" in *nope*) printf 'ok   unknown instance names itself\n' ;;
    *) printf 'FAIL error did not name the instance: %s\n' "$err"; fail=1 ;; esac
fi

# No instance at all fails closed too, rather than guessing.
if env HOME="$home" bash -c ". '$root/skills/board/config.sh'" 2>/dev/null; then
  printf 'FAIL unset FOREMAN_INSTANCE must fail\n'; fail=1
else printf 'ok   unset FOREMAN_INSTANCE fails closed\n'; fi

exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-config-resolves-instance.sh && tests/test-config-resolves-instance.sh`
Expected: FAIL on `REPO comes from the instance` — the copied `config.sh` still derives `REPO` from `--git-common-dir`.

- [ ] **Step 3: Replace the head of `config.sh`**

Delete lines 8-32 (the `--git-common-dir` block) and line 33 (`BOARD_HOME=…`), and replace with:

```bash
# The repository this installation serves, and where its state lives.
#
# It used to be derived from this file's own `--git-common-dir`, which is right
# for a skill committed into the repository it builds and wrong for one
# installed once and pointed at many. The wrong answer was silent: the board
# would cut its worktrees inside its own installation. The instance is now told,
# and refuses to guess.
FOREMAN_HOME="${FOREMAN_HOME:-$HOME/.foreman}"
INSTANCE="${FOREMAN_INSTANCE:-}"
if [[ -z "$INSTANCE" ]]; then
  printf 'foreman: FOREMAN_INSTANCE is unset; refusing to guess which repository to build\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
INSTANCE_HOME="$FOREMAN_HOME/instances/$INSTANCE"
if [[ ! -d "$INSTANCE_HOME" ]]; then
  printf 'foreman: no instance %s at %s\n' "$INSTANCE" "$INSTANCE_HOME" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
BOARD_HOME="${BOARD_HOME:-$INSTANCE_HOME}"

# instance.env and ids.env are KEY=VALUE, written by boardctl, never by hand and
# never by a target repository. Read line by line rather than sourced: the same
# rule the contract follows, for the same reason.
_foreman_read_env() {
  local file="$1" line key value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Environment wins. `-` and not `:-`: an explicitly empty override must mean
    # empty, the same distinction HIGH_RISK_PATHS depends on.
    eval "$key=\"\${$key-\$value}\""
  done <"$file"
}
_foreman_read_env "$INSTANCE_HOME/instance.env"
_foreman_read_env "$INSTANCE_HOME/ids.env"

if [[ -z "${REPO:-}" ]]; then
  printf 'foreman: instance %s declares no REPO\n' "$INSTANCE" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# The target's own contract. Everything a repository knows about itself.
_foreman_skill_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_foreman_contract="$(dirname -- "$(dirname -- "$_foreman_skill_dir")")/bin/contract.py"
if ! _foreman_pairs="$("$_foreman_contract" "$REPO/board.toml")"; then
  printf 'foreman: %s/board.toml did not load (see above)\n' "$REPO" >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
  [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  eval "$_k=\"\${$_k-\$_v}\""
done <<<"$_foreman_pairs"
unset _foreman_skill_dir _foreman_contract _foreman_pairs _k _v
export REPO INSTANCE INSTANCE_HOME BOARD_HOME FOREMAN_HOME
```

- [ ] **Step 4: Delete the values the contract now owns**

Remove these lines, whose values now arrive from `contract.py`. Removing rather than leaving a `:-` fallback is the point — two sources for one value is how a knob drifts from the file the operator edits.

- `:34-49` — `LINEAR_TEAM_ID` and `LINEAR_PROJECT_ID` (now from `ids.env`), and the four `LABEL_*` and five `STATE_*` lines (Task 4 writes them to `ids.env`). Keep the comment explaining ids-never-names; move it to `bin/resolve-ids.py` in Task 4.
- `:68-73` — the six limits.
- `:133` — `REQUIRED_CHECKS`. `:137` — `CI_WORKFLOW`. `:142-143` — `DEPLOY_WORKFLOW`, `DEPLOY_STEP`.
- `:114-129` — `HIGH_RISK_PATHS`. **Keep the comment about reversibility** — move it verbatim into `bin/contract.py` above the `LISTS` table, generalised per Task 8.

- [ ] **Step 5: Point `AGENT_TMP_ROOT` at foreman's own `tmp-dir.sh`**

Line 213 asks `"$REPO/ops/tmp-dir.sh"`, which assumes the target ships that script. Replace with foreman's copy:

```bash
if ! AGENT_TMP_ROOT="$(BOARD_HOME="$BOARD_HOME" \
    "$(dirname -- "$(dirname -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")")/bin/tmp-dir.sh" --root)"; then
  printf 'foreman: bin/tmp-dir.sh failed; cannot derive the agent scratch root\n' >&2
  if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi
```

Also update `bin/tmp-dir.sh:33`: `root="${FOREMAN_TMP_ROOT:-${BOARD_HOME:-$HOME/.foreman}/tmp}"`.

The comment in `tmp-dir.sh` explaining that this file exists because the path once had two authors stays. It is still true, and the second author is now the target's own test runner.

- [ ] **Step 6: Run the tests**

Run: `tests/test-config-resolves-instance.sh && tests/test-contract.sh && tests/test-tmp-dir.sh`
Expected: all `ok`. `test-tmp-dir.sh` will fail on `MURMR_TMP_ROOT` and `~/.murmr-board`; update those two strings to `FOREMAN_TMP_ROOT` and `~/.foreman` and re-run.

- [ ] **Step 7: Commit**

```bash
git add skills/board/config.sh bin/tmp-dir.sh bin/contract.py tests/
git commit -m "The instance names the repository; the repository declares itself"
```

---

### Task 4: Resolve names to ids once, verified, and pin them

**Files:**
- Create: `foreman/bin/resolve-ids.py`
- Create: `foreman/tests/test-resolve-ids.sh`

**Interfaces:**
- Consumes: `LINEAR_TEAM_NAME` / `LINEAR_PROJECT_NAME` from Task 2's contract; `$INSTANCE_HOME` from Task 3.
- Produces: `bin/resolve-ids.py --instance <name> [--api-url URL]` reading the credential from `$INSTANCE_HOME/linear.key` and writing `$INSTANCE_HOME/ids.env` with `LINEAR_TEAM_ID`, `LINEAR_PROJECT_ID`, `STATE_PLANNED`, `STATE_TO_PICK_UP`, `STATE_IN_PROGRESS`, `STATE_IN_REVIEW`, `STATE_MERGED`, `LABEL_FOLLOW_UP`, `LABEL_FOLLOW_UPS_WRITTEN`, `LABEL_NEEDS_MERGE`, `LABEL_BOARD_FAILED`. Exit 0 on success, 1 with a message naming what failed to verify.

- [ ] **Step 1: Write the failing test**

`tests/test-resolve-ids.sh` runs `resolve-ids.py` against a Python `http.server` stub answering Linear's GraphQL endpoint, following the `curl-stub.sh` pattern already in `tests/lib/`. Cases:

```
ok  resolves team and project by name into ids.env
ok  resolves the five states by name
ok  creates a label that does not exist and records its id
ok  reuses a label that does exist rather than creating a second
ok  REFUSES when the to-pick-up state is not of type `unstarted`
ok  REFUSES when a resolved label id belongs to a differently-named label
ok  REFUSES when two projects in the team share the requested name
ok  writes ids.env atomically (a failed run leaves the previous file intact)
ok  ids.env is mode 0600
```

The two `REFUSES` cases carry the design. From murmr's `file-linear.sh`: a mismatched label re-files every finding every morning forever; a mismatched state is the difference between a card that waits and a card that ships. Both must fail closed, and inverting a guard rather than deleting it is what keeps a wrong id failing on a new target.

The duplicate-project case exists because a name is not unique and an id is. Resolution is the one moment names are trusted, so it is the moment ambiguity must be fatal.

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-resolve-ids.sh && tests/test-resolve-ids.sh`
Expected: FAIL — `bin/resolve-ids.py: No such file or directory`.

- [ ] **Step 3: Write `bin/resolve-ids.py`**

Stdlib only (`urllib.request`, `json`, `tomllib`). Structure:

```python
#!/usr/bin/env python3
"""Turn the names in a contract into the ids the board moves cards by.

    resolve-ids.py --instance <name>

The contract names a team, a project and nothing else, because a fork must not
inherit somebody else's project UUID. The running loop moves cards by ID and
never by name, because renaming a column must not silently change which column
the orchestrator is allowed to write to. This script is the one moment those two
requirements meet, and therefore the one moment a name is trusted.

Everything it resolves, it verifies. A label id must belong to a label with the
name that asked for it: a mismatch there re-files every finding, forever. The
to-pick-up state must be of type `unstarted`: a mismatch there is the difference
between a card that waits and a card that ships.

Ambiguity is fatal. Two projects with the requested name is not a coin flip.
"""
```

Functions: `query(api_url, key, document, variables) -> dict`; `resolve_team(name)`; `resolve_project(team_id, name)`; `resolve_states(team_id)` returning the five, asserting the to-pick-up one has `type == "unstarted"`; `ensure_labels(team_id)` creating the four by name and verifying each returned id round-trips to the same name; `write_ids(instance_home, ids)` writing to `ids.env.tmp` then `os.replace`, `os.chmod(0o600)` before the replace.

- [ ] **Step 4: Run the test to verify it passes**

Run: `tests/test-resolve-ids.sh`
Expected: every line `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/resolve-ids.py tests/test-resolve-ids.sh
git commit -m "Names in the file, ids at runtime, and a wrong id fails closed"
```

---

### Task 5: Agent names carry the instance

**Files:**
- Modify: `foreman/skills/board/config.sh` (`agent_name`, `TICK_AGENT_NAME`, `worktree_path`)
- Modify: `foreman/skills/board/reconcile.py:129`
- Modify: `foreman/skills/board/watch-agents.py:44`
- Modify: `foreman/skills/board/dispatch.sh:137` (branch name)
- Modify: `foreman/skills/board/sweep.sh:64` (branch match), `:100` and `:199` (evidence ref glob)
- Modify: `foreman/skills/board/evidence.sh:253` (evidence ref)
- Create: `foreman/tests/test-agent-names-are-instance-scoped.sh`

**Interfaces:**
- Consumes: `INSTANCE` from Task 3.
- Produces: `agent_name <ticket> <role> <attempt>` → `foreman/<instance>/<ticket>/<role>-<attempt>`; `TICK_AGENT_NAME` → `foreman/<instance>/tick`; branches → `foreman/<instance>/<ticket>`; worktrees → `$REPO/.claude/worktrees/foreman-<instance>-<ticket>`; evidence refs → `refs/foreman/<instance>/evidence/<pid>`.

- [ ] **Step 1: Write the failing test**

`tests/test-agent-names-are-instance-scoped.sh`:

```bash
#!/usr/bin/env bash
# `claude agents` is ONE flat registry keyed by name, shared by every instance
# on the machine. reconcile.py finds a card's agents by name prefix and
# watch-agents.py by regex, so two instances that share a prefix reap each
# other's agents -- and the ticket keys collide too, since a team key is three
# letters and two projects may both use PRA.
#
# The names below are what keeps them apart. Assert on the SEPARATION, not just
# the format: a test that only checks one instance's names passes on a regex
# that matches both.
set -euo pipefail
# … set up two instances "alpha" and "beta" over two throwaway target repos,
# exactly as tests/test-config-resolves-instance.sh does …

for i in alpha beta; do
  name="$(ask_fn "$i" agent_name PRA-1 build 1)"
  tick="$(ask_var "$i" TICK_AGENT_NAME)"
  wt="$(ask_fn "$i" worktree_path PRA-1)"
  # …
done

check "alpha and beta build agents differ"   # names must not be equal
check "alpha and beta ticks differ"
check "alpha and beta worktrees differ"
check "the tick never matches the dispatched regex"   # via watch-agents.py
check "reconcile's prefix for alpha excludes beta's agents"
check "reconcile's prefix for PRA-1 excludes PRA-10"  # regression: prefix, not substring
```

The last case is a real trap in the current code and must be kept: `board/PRA-1/` as a prefix does not match `board/PRA-10/` only because of the trailing slash. Keep the slash.

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-agent-names-are-instance-scoped.sh && tests/test-agent-names-are-instance-scoped.sh`
Expected: FAIL — alpha and beta produce identical names.

- [ ] **Step 3: Make the edits**

`config.sh`:

```bash
# Every name carries the instance. `claude agents` is one flat registry shared
# by every installation on this machine, matched by prefix in reconcile.py and
# by regex in watch-agents.py; without this segment two instances reap each
# other's agents, and two projects may legitimately both use the team key PRA.
TICK_AGENT_NAME="${TICK_AGENT_NAME:-foreman/$INSTANCE/tick}"
agent_name() { printf 'foreman/%s/%s/%s-%s\n' "$INSTANCE" "$1" "$2" "$3"; }
worktree_path() { printf '%s/.claude/worktrees/foreman-%s-%s\n' "$REPO" "$INSTANCE" "$1"; }
branch_name() { printf 'foreman/%s/%s\n' "$INSTANCE" "$1"; }
evidence_ref() { printf 'refs/foreman/%s/evidence/%s\n' "$INSTANCE" "$1"; }
```

`reconcile.py:129`: `prefix = f"foreman/{INSTANCE}/{ticket}/"` — and add `INSTANCE` to the `keys` tuple in `_load_config` (line 34) so it arrives from `config.sh` rather than being read from the environment a second time.

`watch-agents.py:44`:

```python
# foreman/<instance>/<TICKET>/<role>-<attempt>. The tick is foreman/<instance>/tick,
# which has no fourth segment and therefore never matches.
DISPATCHED = re.compile(r"^foreman/([^/]+)/([A-Z]+-\d+)/(build|review)-(\w+)$")
```

`watch-agents.py` must additionally filter on `INSTANCE`, or one instance's Monitor wakes on another's agents. Read it the same way `reconcile.py` does.

`dispatch.sh:137`: `-B "$(branch_name "$TICKET")"`. `sweep.sh:64`: `foreman/*)`. `sweep.sh:100,199` and `evidence.sh:253`: `refs/foreman/$INSTANCE/evidence/`.

- [ ] **Step 4: Run the tests**

Run: `tests/test-agent-names-are-instance-scoped.sh && tests/test-sweep-reaps-leaked-evidence-refs.sh && tests/test-evidence-reads-are-fresh.sh`
Expected: all pass. The latter two are murmr's own tests and will need their hardcoded `refs/board/evidence/` updated; that is the point of running them.

- [ ] **Step 5: Commit**

```bash
git add skills/board tests/
git commit -m "Name every agent, branch, worktree and ref for its instance"
```

---

### Task 6: A host ceiling, and a preflight that does not race

**Files:**
- Modify: `foreman/skills/board/preflight.py` (`_load_config` keys, a lock around the probes)
- Modify: `foreman/skills/board/reconcile.py` (a `--host-slots` mode)
- Create: `foreman/tests/test-host-ceiling.sh`

**Interfaces:**
- Consumes: `$FOREMAN_HOME` and `INSTANCE_HOME` from Task 3.
- Produces: `reconcile.py --host-slots` printing `{"instances": {...}, "total": N}` counting cards holding a slot across `~/.foreman/instances/*/cards/`; `HOST_MAX_CONCURRENT` in `config.sh` (default 4) which the tick checks before dispatch, in addition to the instance's own `MAX_CONCURRENT`.

- [ ] **Step 1: Write the failing test**

Cases for `tests/test-host-ceiling.sh`:

```
ok  --host-slots counts cards across every instance, not just this one
ok  --host-slots ignores a card whose history says it finished
ok  --host-slots survives an instance directory with no cards/ at all
ok  a second preflight blocks while the first holds the probe lock
ok  the probe lock is released when preflight is killed mid-probe
ok  probe sizes come from the contract, not from a constant
```

The fourth and fifth cases are the reason the lock exists: two instances each writing a gigabyte probe concurrently both observe room that only one of them can have — the same class of error as the quota that killed two consecutive build attempts in murmr, scaled by the number of instances.

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-host-ceiling.sh && tests/test-host-ceiling.sh`
Expected: FAIL — `reconcile.py: unrecognized arguments: --host-slots`.

- [ ] **Step 3: Implement**

Reuse `skills/board/withlock.py` for the probe lock — it already exists and is tested; the lock file is `$FOREMAN_HOME/preflight.lock`. Add `MIN_FREE_TMP_MB`, `MIN_FREE_REPO_MB`, `PROBE_TMP_MB`, `PROBE_REPO_MB`, `QUICK_PROBE_MB` to the contract's `LIMITS` table in `bin/contract.py` (Task 2) so a target with a cheap test suite is not required to reserve a gigabyte.

- [ ] **Step 4: Run the tests**

Run: `tests/test-host-ceiling.sh && tests/test-preflight-fetches-only-to-gate.sh`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add skills/board bin/contract.py tests/test-host-ceiling.sh
git commit -m "Bound the machine, not just the instance, and stop two probes lying to each other"
```

---

### Task 7: The target's own test and bootstrap commands

**Files:**
- Modify: `foreman/skills/board/brief.py` (the `STANDING` prompt and `build()`)
- Modify: `foreman/skills/board/dispatch.sh` (run bootstrap in a fresh worktree)
- Create: `foreman/tests/test-brief-uses-the-contract.sh`

**Interfaces:**
- Consumes: `TEST_COMMAND`, `BOOTSTRAP_COMMAND`, `REQUIRED_DOCS` from Task 2; `INSTANCE` from Task 3.
- Produces: `brief.py build --ticket … --title … --body-file …` emitting a prompt that names the target's test command and required documents and contains no project-specific string; `dispatch.sh` running `BOOTSTRAP_COMMAND` in a new worktree before the agent starts, failing the dispatch if it fails.

- [ ] **Step 1: Write the failing test**

```
ok  the build prompt names the contract's test command
ok  the build prompt lists every docs.required entry
ok  a contract with no bootstrap command dispatches without running one
ok  a failing bootstrap fails the dispatch instead of starting a blind agent
ok  the prompt contains none of: murmr, mango, Praveen, PRA-, just test-all
ok  agent-written text is still wrapped in a tag it cannot close
```

The last case guards `quote_untrusted`, which exists because a finding written by an agent is indistinguishable from the board's own instructions once it is in a prompt. Generalising the prose must not lose it.

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-brief-uses-the-contract.sh && tests/test-brief-uses-the-contract.sh`
Expected: FAIL — the prompt says "the murmr repository" and nothing reads `TEST_COMMAND`.

- [ ] **Step 3: Implement**

`brief.py` reads config the way `reconcile.py` does. `STANDING` becomes:

```python
STANDING = f"""\
Read {docs_sentence} before making non-trivial changes.

Implement the ticket. Run `{TEST_COMMAND}`. Open a pull request whose body links
the ticket.

**Open it ready for review, never as a draft.** A draft cannot be merged, so one
blocks the board after its checks are green and two reviewers have already read
the diff — all of that work sits waiting on a flag.

**Do not merge, and do not enable auto-merge.** Merging deploys, and arming
auto-merge lets the forge merge this diff while it is still being reviewed. Push
the branch, open the pull request, and stop there.
…
"""
```

The paragraph about a failed command being reported rather than worked around stays verbatim, generalised: it is the difference between a repairable machine and a ticket that burns an attempt on a broken environment.

- [ ] **Step 4: Run the tests**

Run: `tests/test-brief-uses-the-contract.sh`
Expected: every line `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/board/brief.py skills/board/dispatch.sh tests/test-brief-uses-the-contract.sh
git commit -m "Ask the target how to build and test it"
```

---

### Task 8: Generalise the prose, and hold it generalised

**Files:**
- Modify: `foreman/skills/board/SKILL.md` (1,028 lines), and the comments in every `skills/board/*.{sh,py}`
- Modify: `foreman/skills/adversarial-reviewer/SKILL.md`
- Create: `foreman/tests/test-no-target-specifics.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/test-no-target-specifics.sh`, which fails the build when a target-specific identifier appears anywhere outside `docs/`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# The prose is the product. It is also where a copied codebase keeps its old
# owner's name, and a stranger cannot evaluate an argument about a machine they
# have never seen. This fails the build on the identifiers that mean "this was
# somebody else's repository".
#
# `docs/` is exempt: the spec records where this came from, and saying so is
# accurate rather than leftover.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
banned='murmr|mango|Praveen|MURMR_|PRA-[0-9]|just test-all|deploy-mango|\.murmr-'
if hits="$(grep -rInE "$banned" "$root" \
     --exclude-dir=.git --exclude-dir=docs --exclude-dir=.claude 2>/dev/null)"; then
  printf 'FAIL target-specific identifiers survive generalisation:\n%s\n' "$hits"
  exit 1
fi
printf 'ok   no target-specific identifiers outside docs/\n'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-no-target-specifics.sh && tests/test-no-target-specifics.sh`
Expected: FAIL, with a long list. That list is this task's work queue.

- [ ] **Step 3: Rewrite each hit as a portable lesson**

Rules, applied consistently:

- A named host becomes its specification: *"mango has 14GB RAM and a 7.3GB tmpfs"* → *"a 14GB host whose `/tmp` is a tmpfs sized at half of RAM"*. The number is what makes the argument checkable; the hostname is not.
- A ticket key becomes the thing that happened: *"two PRA-28 attempts died mid-`just test-all`"* → *"two consecutive attempts on one card died mid-test-run"*.
- The project becomes the target: *"the murmr repository"* → *"the target repository"*.
- The stakes generalise but do not soften: *"deploys against Praveen's real messages, health and finance data within the hour"* → *"merging deploys to production within the hour"*. The reason a rule exists survives; whose data it was does not.

**Nothing is deleted for being a story.** The stories are why the constraints are believed, and a constraint with no argument behind it is the first thing a future reader deletes.

- [ ] **Step 4: Run the test**

Run: `tests/test-no-target-specifics.sh`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Rewrite the incidents as portable lessons, and hold them that way"
```

---

### Task 9: foreman's own contract and CI

**Files:**
- Create: `foreman/board.toml` (replacing Task 2's minimal fixture)
- Create: `foreman/.github/workflows/ci.yml`
- Create: `foreman/tests/run-all.sh`

**Interfaces:**
- Consumes: every test from Tasks 2-8.
- Produces: a CI workflow named `CI` with one job named `Tests`, which is the exact string `board.toml` declares in `checks.required`.

- [ ] **Step 1: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Every test, in one command, so `test.command` in board.toml has something to
# name. Runs them all before reporting: stopping at the first failure hides how
# much is broken, which matters when an agent is the one reading the output.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$here"/test-*.sh; do
  printf '\n== %s\n' "$(basename "$t")"
  bash "$t" || fail=1
done
bash "$(dirname "$here")/bin/check-syntax.sh" || fail=1
exit "$fail"
```

- [ ] **Step 2: Write `board.toml`**

```toml
# foreman builds itself. This is instance #1 and the only proof the contract is
# right: until a card walks from Todo to merged on a repository that is not the
# one this code grew up in, the seam is a hypothesis.
[linear]
team = "PRA"
project = "foreman"

[checks]
required = ["Tests"]
ci_workflow = "CI"

# No [deploy]. foreman deploys nowhere; merged is done. This is deliberate
# coverage of the optional path -- the code that reads deploy evidence must
# tolerate a target that has none, and a target that exercises it is better
# than a test that mocks it.

[risk]
paths = ["skills/board/config.sh", "bin/resolve-ids.py"]

[test]
command = "tests/run-all.sh"

[docs]
required = ["docs/specs/2026-08-27-autonomous-board-runner-design.md"]

[limits]
max_concurrent = 1
```

`risk.paths` parks a diff for a human when it touches the config loader or id resolution. The distinction is reversibility: a bad change elsewhere is a revert, but a board that mis-resolves its own ids moves cards in a project nobody is watching.

- [ ] **Step 3: Write `.github/workflows/ci.yml`**

A single job, `name: Tests`, on `ubuntu-latest`, `python3` and `bash` only, running `tests/run-all.sh`. The workflow's own `name:` must be `CI` to match `checks.ci_workflow`.

- [ ] **Step 4: Verify the check name matches the contract**

Run: `bin/contract.py board.toml | tr '\0' '\n' | grep -A1 REQUIRED_CHECKS`
Expected: `Tests` — and it must equal the `name:` of the job in `ci.yml`. A mismatch here is the failure mode where a board waits forever for a check that will never report.

- [ ] **Step 5: Push and confirm the check reports**

```bash
gh repo create foreman --private --source=. --push
gh run list --limit 1
```
Expected: a run of workflow `CI` with a job named `Tests`, concluding `success`.

- [ ] **Step 6: Commit**

```bash
git add board.toml .github/workflows/ci.yml tests/run-all.sh
git commit -m "foreman declares itself as a target, and its checks report"
```

---

### Task 10: Minimal `boardctl`, and a pinned install

**Files:**
- Create: `foreman/bin/boardctl`
- Create: `foreman/tests/test-boardctl.sh`

**Interfaces:**
- Consumes: `bin/contract.py`, `bin/resolve-ids.py`, `skills/board/config.sh`.
- Produces: `boardctl add <name> --repo <path> --linear-key-file <path>` creating `~/.foreman/instances/<name>/` with `instance.env`, a 0600 `linear.key`, and `ids.env` via `resolve-ids.py`; `boardctl list`; `boardctl status <name>`; `boardctl halt <name>` / `resume <name>` touching and removing `$INSTANCE_HOME/HALT`.

- [ ] **Step 1: Write the failing test**

```
ok  add creates the instance and resolves its ids
ok  add REFUSES an existing instance rather than overwriting its ids
ok  add REFUSES a repo with no board.toml, naming the path
ok  linear.key is mode 0600 and is never echoed
ok  halt creates HALT; resume removes it; status reports which
ok  list names every instance and the repo each serves
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-boardctl.sh && tests/test-boardctl.sh`
Expected: FAIL — `bin/boardctl: No such file or directory`.

- [ ] **Step 3: Write `bin/boardctl`**

Bash, following `config.sh`'s conventions. `add` writes `instance.env` *before* calling `resolve-ids.py`, because resolution needs `REPO` to find `board.toml`, and deletes the instance directory if resolution fails — a half-created instance that a tick later picks up is worse than none.

- [ ] **Step 4: Document the pinned install in the README**

```markdown
## Installing

foreman is installed once and pointed at repositories.

    git clone <url> ~/.foreman/install
    ~/.foreman/install/bin/boardctl add myproject --repo ~/Developer/myproject \
        --linear-key-file ~/.config/linear.key

**The running loop uses the installed clone, never a working tree** — including
when the repository it is building is foreman itself. A board that reads its own
uncommitted code cannot survive merging a broken change to itself: the tick that
would notice is the tick that just replaced itself. `git -C ~/.foreman/install
pull` moves the pin, deliberately by hand.
```

- [ ] **Step 5: Run the tests**

Run: `tests/run-all.sh`
Expected: every test passes.

- [ ] **Step 6: Commit**

```bash
git add bin/boardctl tests/test-boardctl.sh README.md
git commit -m "Create an instance, and pin what the loop runs from"
```

---

### Task 11: Dogfood one card end to end

This task writes no code. It is the only evidence that Layer 1 works, and it is where the contract is actually tested.

**Files:** none.

**Interfaces:**
- Consumes: everything.
- Produces: a verdict, and a list of what the next spec must fix.

- [ ] **Step 1: Create the Linear project and register the instance**

Create project `foreman` in team PRA with the seven states the contract expects. Then:

```bash
~/.foreman/install/bin/boardctl add foreman --repo ~/.foreman/install \
    --linear-key-file ~/.config/linear.key
~/.foreman/install/bin/boardctl status foreman
```
Expected: the instance resolves every id, and `status` reports the repo it serves.

- [ ] **Step 2: Dry-run a tick before anything can move**

```bash
FOREMAN_INSTANCE=foreman BOARD_DRY_RUN=1 claude -p "/board"
```
Expected: `WOULD:` lines only. No Linear write, no `gh` write, no worktree, no agent. If anything mutates, stop and fix it — the dry run is the last gate before an unattended loop runs against a real board.

- [ ] **Step 3: Put one small real card in `Todo`**

A genuine improvement to foreman, small enough to review by hand. Suggested: *"`boardctl status` should report how long the tick has been idle."*

- [ ] **Step 4: Run one tick for real and watch it**

```bash
FOREMAN_INSTANCE=foreman claude -p "/board"
```
Expected: the card moves to `In Progress`, a worktree appears at `foreman-foreman-<TICKET>`, a build agent runs `tests/run-all.sh`, a pull request opens, `Tests` reports, two reviewers read the diff, and the card reaches `Done`.

- [ ] **Step 5: Record what broke**

Every failure here is a contract defect, not a card defect. Write them into `docs/specs/` as the input to the runner spec. Expect at least: the `REQUIRED_DOCS` path being relative to the repo but read from a worktree, and the review prompt referring to skills the target does not have installed.

- [ ] **Step 6: Commit the findings**

```bash
git add docs/
git commit -m "What the first unattended card found"
```

---

## Self-review

**Spec coverage.** Contract → Task 2. Names-to-ids → Task 4. Instance state → Task 3. `REPO` inversion → Task 3. Agent namespacing → Task 5. Host ceiling and preflight lock → Task 6. `test.command`/`bootstrap.command` → Task 7. Prose → Task 8. Tests and CI → Tasks 1, 9. Dogfooding and the pinned install → Tasks 9, 10, 11. Out-of-scope items (the sandboxed judge, `init`, multi-instance systemd) have no tasks, correctly.

**Deviation from the spec.** The contract is `board.toml`, not `board.yaml`, so it parses with stdlib `tomllib` and the "no install step before the config can be read" property survives. Flagged in Global Constraints.

**Gap accepted.** The spec's `paths.halt_file` has no task. `config.sh` already reads a halt path and Task 3 moves it into instance state; a target whose CI writes it needs `boardctl status` to print it, which Task 10 does. No separate task earns its place.
