#!/usr/bin/env bash
# SKILL.md is not documentation about the board. It IS the board: the tick agent
# reads it and runs the commands it shows, so a flag that moved, a subcommand
# that gained a required argument, or a column the resolver does not create is
# not a stale paragraph -- it is a dispatch that dies at argparse, on a card,
# with an attempt already charged for it.
#
# Nothing catches that. `bin/check-syntax.sh` does not read markdown, and the
# scripts have no idea a document is quoting them. The one time this bit, the
# document was right about a path that had moved everywhere else
# (test-skill-md-install-path.sh); this file covers the other half, which is the
# commands themselves.
#
# So this test runs SKILL.md's own bash blocks. It EXTRACTS them from the file
# rather than restating them here -- a test that retypes the command it checks
# stays green while the document says something else, which is the defect, not
# the check. Only the placeholders (`<T>`, `<n>`, `/tmp/...`, the install root)
# are substituted; every flag, subcommand and role is whatever the document
# says today. `brief.py`, `plancomments.py`, `config.sh` and `dispatch.sh` all
# run for real, against a real git origin, with `claude` stubbed at the external
# boundary the way tests/lib/dispatch-fixture.sh stubs it -- so what passes here
# is evidence about a live dispatch and not about a fixture.
#
# It also pins the two claims about the document that no script can make on its
# own: that every board-failed exit sends its card to `Needs Human` and not back
# to `Backlog`, and that the states table names exactly the columns
# `bin/resolve-ids.py` resolves. A card sent to a column nobody resolves an id
# for is a card the board cannot move at all.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname -- "$here")"
skill="$root/skills/board/SKILL.md"
board_dir="$root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$here/lib/instance-fixture.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

TICKET="ACME-7"

git_q() {
  git -c user.name="Skill Md Test" -c user.email="skill-md-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# --- The fixture -----------------------------------------------------------
#
# A shim install root: the real skill directory, with preflight.py replaced.
# Same two-level shape config.sh's contract loader needs (skills/board/ beside
# bin/), the same technique tests/lib/dispatch-fixture.sh uses. preflight.py is
# stubbed because it wants an authenticated `gh` this suite may not assume;
# everything else here is the real file, reached through a symlink.
shim_root="$work/install"
mkdir -p "$shim_root/bin" "$shim_root/skills/board"
shim="$shim_root/skills/board"
for f in config.sh dispatch.sh withlock.py brief.py plancomments.py reconcile.py; do
  ln -s "$board_dir/$f" "$shim/$f"
done
for f in contract.py boards.py tmp-dir.sh check-plan-graph.py; do
  ln -s "$root/bin/$f" "$shim_root/bin/$f"
done
cat > "$shim/preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
chmod +x "$shim/preflight.py"

origin="$work/origin.git"
target="$work/target"
git_q init -q --bare "$origin"
git_q init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git_q -C "$target" add -A
git_q -C "$target" commit -q -m Seed
git_q -C "$target" remote add origin "$origin"
git_q -C "$target" push -q origin main
seed_sha="$(git_q -C "$target" rev-parse HEAD)"

home="$work/home"
fixture_add_instance "$home" demo "$target"

# A `claude` that keeps a registry. dispatch.sh spawns with `--name` and then
# asks `claude agents` whether the agent registered, and refuses when it did
# not -- so a stub that always answers `[]` makes every fresh dispatch exit
# non-zero and every `--resume` refuse. Both are exactly what this test asserts
# about, so the stub records what it was asked to spawn and answers with it.
stub_bin="$work/bin"
registry="$work/agents.json"
argv_log="$work/argv.log"
echo '[]' > "$registry"
mkdir -p "$stub_bin"
cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$@" >> "$argv_log"
  python3 - "$registry" "\$@" <<'PY'
import json, sys
path, argv = sys.argv[1], sys.argv[2:]
name = argv[argv.index("--name") + 1] if "--name" in argv else "unnamed"
agents = json.load(open(path))
agents.append({"name": name, "sessionId": "stub-" + str(len(agents)),
               "startedAt": len(agents) + 1})
json.dump(agents, open(path, "w"))
PY
  echo "stub-session"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  cat "$registry"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/claude"

# --- Pull the blocks out of SKILL.md ---------------------------------------
#
# One file per block, named for the brief.py subcommand it drives. A block that
# drives brief.py or dispatch.sh and matches no name below is an error rather
# than a skip: a documented dispatch this test does not run is a documented
# dispatch nothing checks, and silence would report coverage it does not have.
blocks="$work/blocks"
mkdir -p "$blocks"
body_file="$work/ticket-body.md"
printf 'Make the widget do the thing.\n' > "$body_file"

if ! extract_out="$(python3 - "$skill" "$blocks" "$TICKET" "$work" "$shim" \
                     "$seed_sha" "$body_file" 2>&1 <<'PY'
import pathlib, sys

skill, out, ticket, work, shim, sha, body = sys.argv[1:8]
lines = pathlib.Path(skill).read_text().split("\n")

blocks, cur, indent = [], None, 0
for line in lines:
    stripped = line.strip()
    if cur is None:
        if stripped == "```bash":
            cur, indent = [], len(line) - len(line.lstrip())
        continue
    if stripped == "```":
        blocks.append("\n".join(cur))
        cur = None
        continue
    cur.append(line[indent:] if line[:indent].strip() == "" else line.lstrip())

# Placeholders, longest-first where one contains another, so `<ticket-body>`
# is never half-substituted by `<T>`.
subs = [
    ("~/.foreman/install/skills/board", shim),
    ("<ticket-body>", body),
    ("<headRefOid>", sha),
    ("<TICKET>", ticket),
    ("<title>", "Make the widget do the thing"),
    ("<T>", ticket),
    ("<n>", "1"),
    ("<r>", "1"),
    ("<N>", "1"),
    ("/tmp/", work + "/"),
]

KINDS = ["plan", "build", "replan", "review"]
seen = {}
for block in blocks:
    if "brief.py " not in block and "dispatch.sh " not in block:
        continue
    kind = next((k for k in KINDS if f"brief.py {k} " in block), None)
    if kind is None:
        sys.exit("a block drives brief.py or dispatch.sh and this test does not "
                 "run it; give it a case or stop documenting it:\n" + block)
    if kind in seen:
        sys.exit(f"two blocks drive `brief.py {kind}`; this test would run only "
                 "one of them:\n" + seen[kind] + "\n---\n" + block)
    seen[kind] = block
    for old, new in subs:
        block = block.replace(old, new)
    pathlib.Path(out, kind + ".sh").write_text(block + "\n")

missing = [k for k in KINDS if k not in seen]
if missing:
    sys.exit("SKILL.md shows no bash block driving: " + ", ".join(missing))
print("extracted " + ", ".join(KINDS))
PY
)"; then
  bad "could not extract SKILL.md's dispatch blocks: $extract_out"
  exit "$fail"
fi
ok "SKILL.md shows one bash block per dispatched role, and no unrun extras"

# Run one extracted block the way the tick would: this board's environment,
# config.sh sourced (so `card_log` and `$BOARD_HOME` are the real ones), and
# `$B` pointing at the install root.
run_block() {
  ( set -e
    export HOME="$home" FOREMAN_INSTANCE=demo PATH="$stub_bin:$PATH"
    # shellcheck disable=SC1090
    . "$shim/config.sh"
    B="$shim"
    eval "$(cat "$1")" )
}

spawned() { # <agent name> -- did the stub record a spawn under this name?
  grep -qxF "$1" "$argv_log"
}

# --- 1. The plan dispatch --------------------------------------------------
#
# A card nobody has commented on. plancomments.py answers `round=1 consumed=`
# for it, and that empty list is the footer the plan agent must sign with.
echo '[]' > "$work/comments.json"

if out="$(run_block "$blocks/plan.sh" 2>&1)"; then
  ok "SKILL.md's plan block runs: plancomments.py, brief.py plan and dispatch.sh all accept it"
else
  bad "SKILL.md's plan block does not run as written:
$out"
fi

if spawned "foreman/demo/$TICKET/plan-1"; then
  ok "the plan block spawns a plan agent for the card"
else
  bad "the plan block spawned no agent named foreman/demo/$TICKET/plan-1"
fi

if [[ -f "$work/p.md" ]] && grep -q 'foreman:plan round=1 consumed=' "$work/p.md"; then
  ok "the plan prompt carries the footer plancomments.py printed"
else
  bad "the plan prompt does not carry plancomments.py's footer:
$(cat "$work/p.md" 2>/dev/null)"
fi

# The plan agent must be told to stop at the card. A prompt that says to open a
# pull request is the split not having happened, however green this file looks.
if grep -qi 'push nothing' "$work/p.md" 2>/dev/null; then
  ok "the plan prompt tells the agent it pushes nothing"
else
  bad "the plan prompt never tells the plan agent to push nothing:
$(cat "$work/p.md" 2>/dev/null)"
fi

plan_worktree="$target/.claude/worktrees/foreman-demo-$TICKET-plan-1"
if [[ -d "$plan_worktree" ]]; then
  ok "the plan block cuts the worktree dispatch.sh names for a plan agent"
else
  bad "no plan worktree at $plan_worktree"
fi

# --- 2. The replan resume --------------------------------------------------
#
# The operator has answered, so plancomments.py now has something unconsumed.
# Built by running the real plancomments.py over a real thread, because that
# file is what SKILL.md tells the tick to pass verbatim.
cat > "$work/comments.json" <<'JSON'
[
  {"id": "c1", "body": "```mermaid\nflowchart TD\n  a[\"do it\"]\n```\n<!-- foreman:plan round=1 consumed= -->"},
  {"id": "c2", "body": "What happens when the queue is empty?"}
]
JSON
env HOME="$home" FOREMAN_INSTANCE=demo "$shim/plancomments.py" \
  < "$work/comments.json" > "$work/plan.json"

if out="$(run_block "$blocks/replan.sh" 2>&1)"; then
  ok "SKILL.md's replan block runs: it resumes the agent the plan block spawned"
else
  bad "SKILL.md's replan block does not run as written:
$out"
fi

# The role in that block is load-bearing, not decoration: dispatch.sh builds
# the agent name it resumes out of `--role`, so `--role build` there hunts for
# an agent no plan dispatch ever spawned. Proving the block fails when the role
# is wrong is what makes the case above evidence rather than a coincidence.
sed 's/--role plan/--role build/' "$blocks/replan.sh" > "$work/replan-wrong-role.sh"
if out="$(run_block "$work/replan-wrong-role.sh" 2>&1)"; then
  bad "the replan block still runs with --role build, so its --role plan proves nothing"
else
  case "$out" in
    *"no agent named"*) ok "the same block with --role build is refused: no such agent to resume" ;;
    *) bad "the block with --role build failed, but not at the agent lookup:
$out" ;;
  esac
fi

if grep -q '"role":"plan"' "$home/.foreman/instances/demo/cards/$TICKET/history.jsonl"; then
  ok "the replan block logs the plan round MAX_PLAN_ROUNDS is counted from"
else
  bad "no {\"role\":\"plan\"} entry in the card's history after the replan block:
$(cat "$home/.foreman/instances/demo/cards/$TICKET/history.jsonl")"
fi

# --- 3. The build dispatch -------------------------------------------------
#
# The plan reaches the build agent through a file, not through a branch. This
# is the whole point of the change: `--plan-file` holds the body of the comment
# the plan agent posted, and the build prompt has to contain it.
cat > "$work/plan.md" <<'MD'
```mermaid
flowchart TD
  n1["<b>n1 · widget.py</b> · CHANGE<br/>frobnicates on demand"]
  n2["<b>n2 · test_widget.py</b> · ADD<br/>covers the empty case"]
  n1 -->|feeds| n2
```
<!-- foreman:plan round=1 consumed= -->
MD

if out="$(run_block "$blocks/build.sh" 2>&1)"; then
  ok "SKILL.md's build block runs: brief.py build and dispatch.sh both accept it"
else
  bad "SKILL.md's build block does not run as written:
$out"
fi

if spawned "foreman/demo/$TICKET/build-1"; then
  ok "the build block spawns a build agent for the card"
else
  bad "the build block spawned no agent named foreman/demo/$TICKET/build-1"
fi

if grep -q 'frobnicates on demand' "$work/b.md" 2>/dev/null; then
  ok "the build prompt carries the plan the card holds"
else
  bad "the build prompt does not contain the plan passed to --plan-file:
$(cat "$work/b.md" 2>/dev/null)"
fi

# --- 4. The review dispatch ------------------------------------------------
if out="$(run_block "$blocks/review.sh" 2>&1)"; then
  ok "SKILL.md's review block runs unchanged by all of this"
else
  bad "SKILL.md's review block does not run as written:
$out"
fi

# --- 5. Every board-failed exit lands in Needs Human -----------------------
#
# The exits are found by their released marker rather than by prose, because
# that marker is the one string every one of them must write. Each is read with
# the lines around it: a bullet that says `board-failed` and `Backlog` in the
# same breath is the old destination surviving one exit at a time.
if ! exits_out="$(python3 - "$skill" 2>&1 <<'PY'
import pathlib, re, sys

lines = pathlib.Path(sys.argv[1]).read_text().split("\n")
marker = '"reason":"board-failed:'
hits = [i for i, line in enumerate(lines) if marker in line]
if not hits:
    sys.exit("SKILL.md documents no board-failed exit at all; every one of them "
             "writes a released marker, so this test is now checking nothing")

problems = []
for i in hits:
    window = "\n".join(lines[max(0, i - 8):i + 9])
    reason = re.search(r'board-failed: ([^"]*)', lines[i]).group(1)
    if "Backlog" in window:
        problems.append(f"the `{reason}` exit still names Backlog:\n{window}")
    elif "Needs Human" not in window:
        problems.append(f"the `{reason}` exit names no destination:\n{window}")
if problems:
    sys.exit("\n\n".join(problems))
print(f"{len(hits)} board-failed exits, all of them into Needs Human")
PY
)"; then
  bad "a board-failed exit does not send its card to Needs Human:
$exits_out"
else
  ok "every board-failed exit SKILL.md documents moves the card to Needs Human ($exits_out)"
fi

# --- 6. The states table names the columns the resolver resolves -----------
#
# Both directions. A column in the table that resolve-ids.py never resolves is
# an id the tick will not find in ids.env; a column the resolver requires and
# the table omits is a column an operator is never told to create, and every
# board on the machine refuses until they do.
if ! states_out="$(python3 - "$skill" "$root/bin/resolve-ids.py" 2>&1 <<'PY'
import pathlib, re, sys

skill = pathlib.Path(sys.argv[1]).read_text()
resolver = pathlib.Path(sys.argv[2]).read_text()

# The backtick is built rather than typed: this whole block reaches bash
# inside a `$( )`, which tokenises a literal backtick even in a quoted
# heredoc, and the file then dies at parse time with no test having run.
bt = chr(96)
row = r"\|\s*" + bt + r"(STATE_[A-Z_]+)" + bt + r"\s*\|\s*" + bt + r"([^" + bt + r"]+)" + bt + r"\s*\|"
documented = set(re.findall(row, skill))
roles = re.search(r"STATE_ROLES = \[(.*?)\]", resolver, re.DOTALL).group(1)
resolved = set(re.findall(r'\("(STATE_[A-Z_]+)",\s*"([^"]+)"\)', roles))

if documented != resolved:
    only_doc = sorted(documented - resolved)
    only_res = sorted(resolved - documented)
    sys.exit("SKILL.md's states table and bin/resolve-ids.py disagree.\n"
             f"  only in SKILL.md: {only_doc}\n"
             f"  only in resolve-ids.py: {only_res}")
print(f"{len(resolved)} states")
PY
)"; then
  bad "$states_out"
else
  ok "SKILL.md's states table names exactly the columns bin/resolve-ids.py resolves ($states_out)"
fi

# --- 7. The config table's snippet prints knobs config.sh sets -------------
#
# SKILL.md deliberately refuses to write the values down -- they drifted once
# and the table advertised a fan-out seven times the real one -- so the snippet
# that prints them is the only thing standing between a reader and a guess. A
# knob named there and not set by config.sh prints an empty line under `set -u`
# or kills the subshell outright.
knobs="$(grep -oE '[A-Z][A-Z0-9_]* "\$[A-Z][A-Z0-9_]*"' "$skill" \
  | awk -F' ' '{ gsub(/[$"]/, "", $2); if ($1 == $2) print $1 }' | sort -u)"
if [[ -z "$knobs" ]]; then
  bad "found no knobs in SKILL.md's config snippet; the extraction is broken"
else
  unset_knobs=""
  for knob in $knobs; do
    if ! env HOME="$home" FOREMAN_INSTANCE=demo bash -c \
         ". '$shim/config.sh'; eval \"v=\\\${$knob+set}\"; [[ -n \"\$v\" ]]"; then
      unset_knobs="$unset_knobs $knob"
    fi
  done
  if [[ -z "$unset_knobs" ]]; then
    ok "config.sh sets every knob SKILL.md's config snippet prints"
  else
    bad "SKILL.md prints knobs config.sh never sets:$unset_knobs"
  fi
fi

exit "$fail"
