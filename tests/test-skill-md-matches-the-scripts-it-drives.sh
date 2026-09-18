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
for f in config.sh dispatch.sh withlock.py brief.py plancomments.py reconcile.py fallback.py; do
  ln -s "$board_dir/$f" "$shim/$f"
done
# installation.py is read by config.sh before anything else, and load-pairs.sh
# is what config.sh sources to read it -- both from THIS root's bin/, so a
# shim without either refuses at config.sh's first line.
for f in contract.py boards.py installation.py load-pairs.sh tmp-dir.sh check-plan-graph.py; do
  ln -s "$root/bin/$f" "$shim_root/bin/$f"
done
# config.sh checks that the adapter for this installation's harness is
# executable under this root and refuses there rather than at the spawn. The
# WHOLE directory, so a fourth harness needs no second edit here.
ln -s "$board_dir/harness" "$shim/harness"
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

# The ids brief.py cleanup pastes into the prompt it writes. bin/resolve-ids.py
# reads these out of Linear, which nothing in this suite may reach, so the four
# the cleanup brief needs are written here instead. brief.py refuses an empty
# LINEAR_PROJECT_ID, STATE_IN_PLAN or LABEL_CLEANUP rather than dispatching an
# agent that would file its card nowhere -- so an ids.env without them is a
# cleanup block that refuses, not one this test would catch saying the wrong
# thing.
cat > "$home/.foreman/instances/demo/ids.env" <<'IDS'
LINEAR_PROJECT_ID=project-demo
STATE_IN_PLAN=state-in-plan
LABEL_CLEANUP=label-cleanup
LABEL_NEEDS_PLAN=label-needs-plan
IDS

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
#
# `/tmp/` goes FIRST, and that ordering is load-bearing rather than cosmetic.
# Every other replacement here is an absolute path inside the scratch
# directory, and on Linux that directory is itself under `/tmp/` -- so a
# `/tmp/` rule applied last rewrites the paths this table just inserted,
# turning /tmp/tmp.X/install into /tmp/tmp.X/tmp.X/install and pointing every
# command at a directory that does not exist. Running it first means only
# the `/tmp/` scratch paths SKILL.md itself writes are touched, which is
# for. The bug hid on macOS, where mktemp answers under /var/folders and no
# substituted path contains `/tmp/` at all: green locally, red on the runner.
subs = [
    ("/tmp/", work + "/"),
    ("~/.foreman/<installation>/install/skills/board", shim),
    ("<ticket-body>", body),
    ("<headRefOid>", sha),
    ("<TICKET>", ticket),
    ("<board>", "demo"),
    ("<title>", "Make the widget do the thing"),
    ("<T>", ticket),
    ("<n>", "1"),
    ("<r>", "1"),
    ("<N>", "1"),
]

# `fix` is here because review now runs ONCE: a blocking finding buys exactly
# one fix, and that fix merges on its own checks with no second reviewer. That
# resume is the last thing any agent does to the diff before it merges, so a
# document that only describes it in a sentence is a dispatch nothing runs.
KINDS = ["plan", "build", "replan", "review", "fix", "cleanup"]
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
# FOREMAN_HOME is exported here and named in every other run below. config.sh
# no longer derives it from $HOME: it asks bin/installation.py, which reads the
# home as the parent of the install root -- the shim under $work, which holds
# no boards.toml. An explicit home is what that derivation yields to.
run_block() {
  ( set -e
    export HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      PATH="$stub_bin:$PATH"
    # shellcheck disable=SC1090
    . "$shim/config.sh"
    B="$shim"
    eval "$(cat "$1")" )
}

# The same block, with NO `set -e` around it. The tick's own shell has none:
# SKILL.md is prose an agent follows, and nothing wraps the commands it shows.
# `run_block`'s `set -e` therefore stops a block at its first failing line under
# bash 3.2, which is the one thing a block that chains nothing must not be
# credited with -- the guard has to be in the document, not in this runner.
run_block_unguarded() {
  ( export HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
      PATH="$stub_bin:$PATH"
    # shellcheck disable=SC1090
    . "$shim/config.sh"
    B="$shim"
    eval "$(cat "$1")" )
}

# `--cleanup-due` as the tick asks it, printing the reason on either exit code.
cleanup_due() {
  env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo \
    PATH="$stub_bin:$PATH" "$shim/reconcile.py" --cleanup-due demo 2>&1
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

# This home declares no installation.toml, so bin/installation.py reads it as
# the lone Claude installation with legacy names: no installation segment.
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
env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo "$shim/plancomments.py" \
  < "$work/comments.json" > "$work/plan.json"

# Judged on what the block SAID, not on the status it returned. `run_block`
# evals the extracted lines under `set -e`, and the runner's bash 5 does not
# abort that eval when a middle line exits non-zero the way bash 3.2 does -- so
# the status reads 0 on one machine and 1 on the other for the very same
# refused block. The refusal text is the same on both, and it is the evidence
# the case actually wants.
out="$(run_block "$blocks/replan.sh" 2>&1)" || true
case "$out" in
  *"foreman: "*)
    bad "SKILL.md's replan block does not run as written:
$out" ;;
  *)
    ok "SKILL.md's replan block runs: it resumes the agent the plan block spawned" ;;
esac

# The role in that block is load-bearing, not decoration: dispatch.sh builds
# the agent name it resumes out of `--role`, so `--role build` there hunts for
# an agent no plan dispatch ever spawned. Proving the block fails when the role
# is wrong is what makes the case above evidence rather than a coincidence.
sed 's/--role plan/--role build/' "$blocks/replan.sh" > "$work/replan-wrong-role.sh"
# Same rule as the case above: read the refusal, never the status.
out="$(run_block "$work/replan-wrong-role.sh" 2>&1)" || true
if [[ -z "$out" ]]; then
  bad "the replan block still runs with --role build, so its --role plan proves nothing"
else
  case "$out" in
    # Either refusal proves it, and which one fires is dispatch.sh's own
    # ordering. The session lookup now lives inside the harness adapter, which
    # needs a `--cwd` that exists, so the worktree check runs first. What both
    # messages must name is the BUILD identity: with `--role build` the block
    # resolves a different agent and a different worktree, and neither of them
    # is anything a plan dispatch ever created.
    *"no agent named"*build-1*|*"cannot resume"*build-1*)
      ok "the same block with --role build is refused: no such agent to resume" ;;
    *) bad "the block with --role build failed, but not on the build role's own identity:
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

# --- 4b. The fix resume ----------------------------------------------------
#
# The card's ONE fix. A blocking finding sends the build agent back once, and
# whatever it pushes merges on its own checks with no second reviewer -- so this
# resume is the last dispatch any diff gets before it lands. It is also the only
# one whose prompt splices text another agent wrote into a session holding real
# git and gh credentials, which is what brief.py's fencing is for.
reviews_dir="$home/.foreman/instances/demo/cards/$TICKET/reviews"
mkdir -p "$reviews_dir"
cat > "$reviews_dir/1a.json" <<'JSON'
{"findings": [
  {"severity": "blocking", "file": "widget.py", "line": 12,
   "summary": "the empty queue is never handled",
   "failure": "widget.py crashes on the first tick after a drain"},
  {"severity": "note", "file": "widget.py", "summary": "spelling"}
]}
JSON

if out="$(run_block "$blocks/fix.sh" 2>&1)"; then
  ok "SKILL.md's fix block runs: brief.py fix and dispatch.sh --resume both accept it"
else
  bad "SKILL.md's fix block does not run as written:
$out"
fi

if grep -q 'the empty queue is never handled' "$work/f.md" 2>/dev/null \
   && grep -q '<review-finding>' "$work/f.md" 2>/dev/null; then
  ok "the fix prompt carries the blocking finding, fenced as another agent's words"
else
  bad "the fix prompt does not carry the finding inside a review-finding tag:
$(cat "$work/f.md" 2>/dev/null)"
fi

# The resume, not a fresh spawn: the build agent keeps the worktree that holds
# the branch the fix has to land on. dispatch.sh logs the name it resumed.
if grep -q "\"name\":\"foreman/demo/$TICKET/build-1\"" \
     "$home/.foreman/instances/demo/cards/$TICKET/history.jsonl"; then
  ok "the fix block resumes the card's own build agent"
else
  bad "no resume of foreman/demo/$TICKET/build-1 in the card's history:
$(cat "$home/.foreman/instances/demo/cards/$TICKET/history.jsonl")"
fi

# --- 5. The scheduled cleanup block ----------------------------------------
#
# SKILL.md asks at the END of a slice, on capacity the cards did not need -- so
# the card this slice worked has to have released its slot first. Without that,
# demo holds its one MAX_CONCURRENT slot, `--cleanup-due` correctly answers "not
# due", and every assertion below would be green about a block that never ran.
#
# That "without that" is a fact about the cadence and not an artefact of this
# fixture, so it is asserted before it is arranged away: the board has never had
# a cleanup, its stamp is missing, and CLEANUP_EVERY_DAYS is still 3 -- and it is
# STILL not due, because one card is in flight. CLEANUP_EVERY_DAYS is a floor on
# the interval and the config table has to say so, or an operator reads a board
# that cleans up every third day out of a knob that promises nothing of the kind.
due_out="$(cleanup_due)"; due_status=$?
case "$due_status:$due_out" in
  1:*"of its 1 card slot"*)
    ok "a board whose one slot holds a card is not due a cleanup, stale stamp or not" ;;
  *)
    bad "expected --cleanup-due to refuse on the held slot, got exit $due_status:
$due_out" ;;
esac

cat > "$work/release.sh" <<EOF
card_log "$TICKET" '{"action":"released","reason":"done"}'
EOF
if ! out="$(run_block "$work/release.sh" 2>&1)"; then
  bad "could not release the card's slot before the cleanup block:
$out"
fi

# The agent a cleanup pass spawns is named from the literal ticket `cleanup` and
# an attempt that is a UTC minute, so it is matched by shape rather than by a
# fixed string -- the attempt is whatever `date` said when the block ran.
cleanup_spawns() { grep -cE '^foreman/demo/cleanup/cleanup-[0-9]+$' "$argv_log"; }

if out="$(run_block "$blocks/cleanup.sh" 2>&1)"; then
  ok "SKILL.md's cleanup block runs: reconcile.py, brief.py cleanup and dispatch.sh all accept it"
else
  bad "SKILL.md's cleanup block does not run as written:
$out"
fi

if [[ "$(cleanup_spawns)" == 1 ]]; then
  ok "the cleanup block spawns a cleanup agent for the board"
else
  bad "the cleanup block spawned no agent named foreman/demo/cleanup/cleanup-<digits>:
$(cat "$argv_log")"
fi

if [[ -s "$home/.foreman/instances/demo/last-cleanup" ]]; then
  ok "the cleanup block stamps last-cleanup before it dispatches"
else
  bad "no last-cleanup stamp under $home/.foreman/instances/demo"
fi

# The one thing the whole pass is bounded by. A prompt that does not say it is a
# cleanup agent free to file as many cards as it finds work for.
if grep -q 'at most one' "$work/c.md" 2>/dev/null; then
  ok "the cleanup prompt caps the pass at one card"
else
  bad "the cleanup prompt does not cap the pass at one card:
$(cat "$work/c.md" 2>/dev/null)"
fi

# Twice in one slice is what the stamp exists to stop, and the stamp the first
# run wrote is now minutes old against a cadence counted in days. Running the
# same block again must dispatch nothing at all.
if out="$(run_block "$blocks/cleanup.sh" 2>&1)"; then
  ok "SKILL.md's cleanup block runs again without failing"
else
  bad "SKILL.md's cleanup block failed on a board that is not due:
$out"
fi
if [[ "$(cleanup_spawns)" == 1 ]]; then
  ok "a second cleanup is not dispatched: the stamp the first one wrote is fresh"
else
  bad "the cleanup block dispatched a second pass over a fresh stamp:
$(cat "$argv_log")"
fi

# --- 5b. The finished cleanup pass still holds the board's only slot --------
#
# The stamp is what the cadence turns on, so removing it is `boardctl cleanup`:
# the operator asking for a pass now. What answers instead is the slot the pass
# that just ran is still holding, through `cards/cleanup/history.jsonl`, because
# nothing has swept it. At MAX_CONCURRENT 1 that is a board that dispatches
# nothing at all -- not one cleanup and not one card -- until
# HOST_SLOT_STALE_MINUTES expires, which is twelve hours.
#
# reconcile.py names that case in the reason line it prints, and the reason line
# is the only thing the operator sees. So step 8 has to carry the same sentence:
# a reason nobody can look up is a board that reads as idle.
rm -f "$home/.foreman/instances/demo/last-cleanup"
held_out="$(cleanup_due)"; held_status=$?
if [[ "$held_status" == 1 && "$held_out" == *"cards/cleanup"* ]]; then
  ok "a finished cleanup pass keeps holding the board's slot, and --cleanup-due says so"
else
  bad "expected --cleanup-due to name the unswept cleanup slot, got exit $held_status:
$held_out"
fi

if ! reason_out="$(python3 - "$skill" "$held_out" 2>&1 <<'PY'
import pathlib, re, sys

skill, reason = sys.argv[1], sys.argv[2]

# Everything after the first semicolon is the part about the cleanup slot
# itself; the clause before it names the board and its count, which SKILL.md
# must not hardcode. Backticks and line breaks differ between a terminal line
# and a wrapped markdown paragraph and nothing else may.
#
# NO APOSTROPHE AND NO BACKTICK below reaches the here-doc: the whole block runs
# inside a command substitution, which bash tokenises before the quoted here-doc
# protects anything.
tail = reason.split("; ", 1)[1] if "; " in reason else reason
flat = lambda s: re.sub(r"\s+", " ", s.replace(chr(96), "")).strip()

lines = pathlib.Path(skill).read_text().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("### 8."))
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("### ")),
           len(lines))
section = flat("\n".join(lines[start:end]))

if flat(tail) not in section:
    sys.exit("step 8 does not carry the reason --cleanup-due prints for a board "
             "whose only slot is a finished cleanup, so an operator reading that "
             "line has nowhere to look it up.\n"
             "  reconcile.py says: " + flat(tail) + "\n"
             "  step 8 says nothing that contains it")
print("step 8 quotes the reason line verbatim")
PY
)"; then
  bad "$reason_out"
else
  ok "step 8 explains the reason --cleanup-due prints for an unswept cleanup ($reason_out)"
fi

# --- 5c. A failing step 8 must not reach the dispatch ----------------------
#
# The sweep step 8 documents is what frees that slot; `card_log` is the marker
# it writes, and writing it here is what puts the board back in the state the
# next case is about.
cat > "$work/release-cleanup.sh" <<'EOF'
card_log cleanup '{"action":"released","reason":"swept"}'
EOF
if ! out="$(run_block "$work/release-cleanup.sh" 2>&1)"; then
  bad "could not release the finished cleanup's slot:
$out"
fi

# brief.py refuses without LABEL_CLEANUP rather than telling an agent to file a
# card with no label -- and the shell has already truncated the prompt file by
# then, because `>` opens it before brief.py runs. Unchained, the next command
# is dispatch.sh, reading a prompt that is now empty. The stamp is already
# written at that point, so the board is not due again for CLEANUP_EVERY_DAYS
# days and nothing ran.
sed 's/^LABEL_CLEANUP=.*/LABEL_CLEANUP=/' \
  "$home/.foreman/instances/demo/ids.env" > "$work/ids.env"
cp "$work/ids.env" "$home/.foreman/instances/demo/ids.env"

guard_out="$(run_block_unguarded "$blocks/cleanup.sh" 2>&1)"
case "$guard_out" in
  *"ids.env has no LABEL_CLEANUP"*) : ;;
  *) bad "the cleanup block did not reach brief.py's refusal, so this case proves nothing:
$guard_out" ;;
esac
case "$guard_out" in
  *"prompt file is empty"*)
    bad "step 8's block ran dispatch.sh after brief.py failed; chain the commands so a
failure stops before the dispatch:
$guard_out" ;;
  *)
    ok "step 8's block stops at the failure and never reaches dispatch.sh" ;;
esac
if [[ "$(cleanup_spawns)" == 1 ]]; then
  ok "no cleanup agent is spawned when the prompt was never written"
else
  bad "a cleanup agent was spawned from a prompt brief.py refused to write:
$(cat "$argv_log")"
fi

# --- 6. Every board-failed exit lands in Needs Human -----------------------
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

# --- 7. The states table names the columns the resolver resolves -----------
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

# --- 8. The config table's snippet prints knobs config.sh sets -------------
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
    if ! env HOME="$home" FOREMAN_HOME="$home/.foreman" FOREMAN_INSTANCE=demo bash -c \
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

# --- 9. Step 3 names every verdict reconcile.py can return, and no other ---
#
# The tick does not compute this: reconcile.py does, and step 3 is the dispatch
# table the tick reads it against. A verdict with no bullet is a tick with no
# instruction for an answer it will be handed -- it improvises, on a card, with
# a merge at the end of it. A bullet for a verdict that no longer exists is the
# same defect pointing the other way.
#
# Read out of the function with ast rather than by grepping strings, so a
# verdict spelled inside a conditional expression still counts.
if ! verdicts_out="$(python3 - "$skill" "$board_dir/reconcile.py" 2>&1 <<'PY'
import ast, pathlib, re, sys

skill = pathlib.Path(sys.argv[1]).read_text()
source = pathlib.Path(sys.argv[2]).read_text()

fn = next(n for n in ast.walk(ast.parse(source))
          if isinstance(n, ast.FunctionDef) and n.name == "review_verdict")

returned = set()
for node in ast.walk(fn):
    values = []
    if isinstance(node, ast.keyword) and node.arg == "verdict":
        values.append(node.value)
    if isinstance(node, ast.Dict):
        for key, value in zip(node.keys, node.values):
            if isinstance(key, ast.Constant) and key.value == "verdict":
                values.append(value)
    for value in values:
        for leaf in ast.walk(value):
            if isinstance(leaf, ast.Constant) and isinstance(leaf.value, str):
                returned.add(leaf.value)

# Step 3 down to its first subsection. Each verdict is a bullet opening with the
# name in bold code, and nothing else in that range is written that way.
bt = chr(96)
lines = skill.split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("### 3."))
end = next((i for i in range(start + 1, len(lines))
            if lines[i].startswith("### ") or lines[i].startswith("#### ")),
           len(lines))
body = "\n".join(lines[start:end])
documented = set(re.findall(r"\*\*" + bt + r"([a-z][a-z-]*)" + bt + r"\*\*", body))

problems = []
for name in sorted(returned - documented):
    problems.append("reconcile.py answers " + name + " and step 3 has no bullet "
                    "for it: the tick is handed a verdict with no instruction")
for name in sorted(documented - returned):
    problems.append("step 3 documents " + name + ", which review_verdict never "
                    "returns: the tick waits for an answer nothing sends")
if problems:
    sys.exit("\n".join(problems))
print(str(len(returned)) + " verdicts")
PY
)"; then
  bad "step 3 and reconcile.py disagree about the review verdicts:
$verdicts_out"
else
  ok "step 3 documents exactly the verdicts review_verdict returns ($verdicts_out)"
fi

# --- 10. The claims about this document nothing else can check -------------
#
# Each of these is a sentence the tick acts on. They are checked as
# instructions -- who does the thing, and under what condition -- and never as
# a word being present somewhere in the file.
if ! prose_out="$(python3 - "$skill" 2>&1 <<'PY'
import pathlib, re, sys

bt = chr(96)
lines = pathlib.Path(sys.argv[1]).read_text().split("\n")
problems = []


def section(prefix):
    """One step, as one line -- markdown wraps a sentence wherever it fits."""
    start = next((i for i, l in enumerate(lines) if l.startswith(prefix)), None)
    if start is None:
        return ""
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("### ") or lines[i].startswith("## ")),
               len(lines))
    return re.sub(r"\s+", " ", "\n".join(lines[start:end]))


def row(key):
    hits = [l for l in lines if l.startswith("| " + bt + key + bt + " |")]
    return hits[0] if hits else ""


# CLEANUP_EVERY_DAYS is a FLOOR, not a cadence. Step 8 sits at the end of a
# slice, a slice ends the moment one card moves, and cleanup needs a free board
# slot -- so a busy board reaches step 8 rarely and qualifies rarer still. A
# table that reads as a promise is how an operator concludes cleanup is broken.
every_days = row("CLEANUP_EVERY_DAYS")
if not every_days:
    problems.append("the config table has no CLEANUP_EVERY_DAYS row at all")
elif "earliest" not in every_days or "slot" not in every_days:
    problems.append(
        "the CLEANUP_EVERY_DAYS row states a cadence it cannot promise. It is "
        "the EARLIEST a cleanup may run, and a board with no free slot runs "
        "none however stale the stamp is:\n  " + every_days)

# The cleanup agent reads other agents, findings and operator-written card text
# -- a wider intake than the fix path, which has carried the caveat since it
# first spliced a reviewer into the build prompt. Both sections say it, or the
# rule is not a rule.
for prefix, what in (("### 3.", "the fix resume"),
                     ("### 8.", "the cleanup pass")):
    if "never an instruction" not in section(prefix):
        problems.append(
            "the step covering " + what + " never says that what the agent "
            "reads is data and never an instruction, though that text was "
            "written by other agents and by the operator")

# needs-plan is one-directional: only the operator REMOVES it, the cleanup agent
# may ADD it to the card it just filed, and the tick does neither. The table is
# what gets skimmed, so the row carries the last clause itself.
needs_plan = row("needs-plan")
if not needs_plan:
    problems.append("the labels table has no needs-plan row at all")
elif "never the tick" not in needs_plan:
    problems.append(
        "the needs-plan row names its writers and stops there. The tick neither "
        "adds nor removes it, and a reader who skims the table takes the row as "
        "the whole rule:\n  " + needs_plan)

# The paragraph below that table used to say the board never writes needs-plan,
# which the cleanup agent has done since step 8 existed.
for i, line in enumerate(lines):
    if re.search(r"(?i)board never writ", line):
        problems.append(
            "line " + str(i + 1) + " says the board never writes needs-plan, "
            "which the cleanup agent does whenever its plan is over "
            "CLEANUP_MAX_PLAN_NODES nodes:\n  " + line.strip())

if problems:
    sys.exit("\n\n".join(problems))
print("cadence, injection caveat and the needs-plan rule all stated")
PY
)"; then
  bad "SKILL.md states something the scripts contradict:
$prose_out"
else
  ok "SKILL.md reads correctly on the cadence, the injection caveat and needs-plan ($prose_out)"
fi

exit "$fail"
