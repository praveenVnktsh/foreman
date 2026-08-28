#!/usr/bin/env bash
# Read a file as GitHub currently holds it, for verifying a claim about the code.
#
#   evidence.sh main <path>        `<path>` at the tip of origin/main, right now
#   evidence.sh pr <n> <path>      `<path>` at pull request <n>'s head, right now
#   evidence.sh pr <n>             pull request <n>'s diff
#   --text                         emit bytes `grep` would call binary, anyway
#
# Content goes to stdout so it can be piped to `grep`. A provenance line goes to
# stderr naming the ref and the exact SHA the bytes came from -- paste that line
# on the card when you use this to overrule a reviewer, because it is the only
# part of an overrule the next tick can check.
#
# WHY THIS EXISTS RATHER THAN `git show origin/main:<path>`.
#
# `git show origin/main:<path>` does not touch the network. It resolves the
# LOCAL ref `refs/remotes/origin/main`, which nothing moves except a fetch --
# and **no fetch is guaranteed between a merge and a later read**. Step 0's
# preflight no longer fetches at all in `--quick`; `dispatch.sh` fetches, but
# only when a card is actually dispatched, so whether the ref is refreshed
# between pass 1 and pass 3 depends on work that has nothing to do with the
# read. A tick that merges in pass 1 and dispatches nothing after it reads a
# pre-merge `origin/main` for the rest of its life.
#
# That is not a smaller version of the #159 outage. It is the same one:
#
#   12:00  step 0 runs; refs/remotes/origin/main = X
#   12:03  pass 1 merges PR #A, which adds `--exclude='.claude/'` to
#          ops/deploy.sh; GitHub's main is now X+1
#   12:07  pass 3 weighs a blocking finding on PR #B saying the deploy strips
#          `.claude/`, and runs `git show origin/main:ops/deploy.sh`
#   ->     reads blob X, greps nothing, refutes a correct finding, merges
#
# A staleness number on this checkout could not catch it either, which is why
# preflight no longer computes one: `rev-list HEAD..origin/main` measures
# against the same stale ref, so it prints 0 and *confirms* the lie. The first
# version of this card shipped `git show origin/main:` as the sanctioned read on
# the argument that it is "current at the instant of the read". That argument was
# false, and two reviewers found it independently.
#
# So freshness is made a property of the read: this fetches immediately before
# it shows, into a ref private to this process, and shows what that fetch put
# there -- never a shared ref some other fetch may have moved. If the fetch
# fails, this prints no content and exits non-zero. There is deliberately no
# fallback to a local ref: serving stale bytes with a confident provenance line
# is worse than answering nothing, which is the whole lesson of the outage
# above.
#
# NO PATH HERE EMITS CONTENT IT CANNOT ATTRIBUTE. Every read either prints an
# `evidence:` line naming one confirmed SHA and then the bytes, or prints
# nothing at all and exits non-zero. A tick trusts what this prints, so a
# well-formed answer on a failed read is the worst thing this script can do --
# piped as `evidence.sh pr 166 2>/dev/null | grep -c …` the diff is consumed and
# the non-zero exit is invisible.
#
# AND A READ THAT WOULD MAKE `grep` LIE IS A READ THAT REFUSES. Content here can
# legitimately carry a NUL byte -- `show_pr_diff` has the measurement -- and
# there are only three things this could do with one, two of which are the #159
# mechanism wearing a different hat:
#
#   - delete or truncate at it (what `$(...)` did) and print the rest under a
#     provenance line that swears to the whole thing;
#   - print it intact and hand a BINARY STREAM to the documented pipeline. That
#     is not a loud failure, it is a silent "not there": measured on this host,
#     `… 2>/dev/null | grep -n` under GNU grep 3.12 prints nothing to stdout,
#     puts "binary file matches" on the stderr that idiom discards, and exits
#     **0**; and under the ugrep wrapper the agents' Bash tool actually puts on
#     PATH, `-n`, `-c` and `-q` alike print nothing and exit **1**, with no
#     message even when stderr is kept. A tick reads "the mechanism is absent"
#     about bytes containing it, refutes a correct finding, and merges;
#   - print nothing, say why on stderr, and exit non-zero.
#
# Only the third is honest, so it is the default, and `--text` is how a caller
# who has understood the trap asks for the bytes anyway. That keeps the promise
# above exact: what reaches stdout is byte for byte what the server sent, and
# when that is something `grep` cannot be trusted with, nothing reaches stdout.

set -euo pipefail

SKILL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SKILL_DIR/config.sh"

die() { printf 'evidence: %s\n' "$1" >&2; exit 1; }

# `--text` accepted in any position, and stripped before the positional forms
# below are counted -- so `pr <n> --text` stays a two-argument read rather than
# looking like `pr <n> <path>` with a path named `--text`.
ALLOW_BINARY=0
evidence_args=()
for arg in "$@"; do
  case "$arg" in
    --text) ALLOW_BINARY=1 ;;
    *) evidence_args+=("$arg") ;;
  esac
done
set -- ${evidence_args[@]+"${evidence_args[@]}"}

usage() {
  sed -n '3,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The private ref must not outlive this process.
#
# It is deleted on the happy path too; this trap is for the ways out that are
# not a `return`. `claude stop` on a stalled tick and a tick's own budget
# expiring both land here, and the window they land in is the fetch, which is
# the slow part -- so the leak is not a rare interleaving, it is the common way
# this script is killed. Nothing else reaps that namespace: sweep.sh handles
# worktrees and board branches, dispatch.sh prunes worktrees, and
# `git fetch --prune` does not touch `refs/foreman/`. A leaked ref is permanent,
# and it pins every object the fetch brought with it -- `git gc --prune=now`
# keeps the lot.
#
# SIGKILL cannot be trapped, so this is half the fix. The other half is
# `sweep.sh`, which reaps `refs/foreman/<instance>/evidence/<pid>` for any pid
# that is no longer alive.
EVIDENCE_REF=""
# The read buffer, for the microseconds in which it still has a name. See
# `open_buffer`: once it is unlinked the kernel owns its lifetime and this is
# empty again.
EVIDENCE_BUFFER=""
cleanup() {
  [[ -z "$EVIDENCE_REF" ]] \
    || git -C "$REPO" update-ref -d "$EVIDENCE_REF" 2>/dev/null || true
  [[ -z "$EVIDENCE_BUFFER" ]] || rm -f "$EVIDENCE_BUFFER" || true
}
trap cleanup EXIT
# bash 5 does run the EXIT trap for an uncaught HUP, INT or TERM, so the line
# above nearly stands alone -- but an uncaught SIGINT then exits **0** (measured
# on 5.3.9), and a read that was interrupted must never report success to a
# caller that checks only the status. Naming the signals makes both the cleanup
# and a 128+n exit explicit rather than a property of whichever bash this is.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# THE BUFFER IS A FILE NOBODY CAN NAME, and both reads go through it.
#
# Nothing may reach stdout before the bytes are all in hand and have been looked
# at: `fetch_and_show` used to stream `git show` straight out, so a blob that
# failed to read halfway printed half a file under a provenance line, and
# neither path could tell whether what it was about to print was safe to hand a
# pipeline. Buffering first makes "print the lot or print nothing" a property of
# the code rather than of how far a command got.
#
# The first version of `show_pr_diff` held its diff in `$(...)` and argued that
# the two things command substitution does to bytes were both harmless: it
# strips trailing newlines, and a unified diff ends in exactly one; and it drops
# NUL bytes, which a diff cannot contain "because git calls any file holding one
# binary". That second claim is false. Git decides binary-ness by scanning the
# FIRST 8000 BYTES for a NUL, so a file that is ordinary text for 8KB and
# carries a NUL after it gets an ordinary TEXT diff with the NUL in it --
# measured, not reasoned about. What `$(...)` then does to that byte depends on
# the bash: 5.3.9 deletes it and warns on stderr, which is where the provenance
# line lives and where a caller running `2>/dev/null | grep` cannot see it; bash
# before 4.4 truncates the diff there and says nothing at all. The
# trailing-newline half was true, and the `printf '%s\n'` that repaired it was
# itself a corruption: it restored exactly one newline whether the server sent
# one, none, or three.
#
# A file was rejected the first time round because "it would need somewhere to
# live and something to reap it, which is a second leak of exactly the kind the
# trap above exists to close". It needs neither once it has no name. This opens
# descriptors for writing and for reading and unlinks the path immediately, so
# the bytes are reachable only through those descriptors and the kernel frees
# them when this process dies -- SIGKILL included, which is more than the ref
# above manages. The only window in which a name exists is the two lines between
# `mktemp` and `rm`, and `cleanup` covers that; the file is opened and unlinked
# BEFORE anything is asked to write into it, so the one leak left -- a SIGKILL
# inside those two lines, which no trap can catch and no sweep reaps -- leaves
# an empty file behind, never content.
#
# It lives under the board scratch root rather than `/tmp` for the reason
# `ops/tmp-dir.sh` exists: `/tmp` on the dev host is a RAM-backed tmpfs under a
# per-user quota, and buffering there competes for memory with the agents doing
# the work.
#
# Two read descriptors, not one, because the bytes are read twice and a
# descriptor cannot be rewound: once to count NUL bytes, once to emit. Reopening
# by name is what the unlink just made impossible, on purpose.
BUF_W=""
BUF_SCAN=""
BUF_R=""
open_buffer() {
  local buffer
  mkdir -p "$AGENT_TMP_ROOT" \
    || die "could not create $AGENT_TMP_ROOT to buffer this read in"
  buffer="$(mktemp "$AGENT_TMP_ROOT/evidence-buffer.$$.XXXXXX")" \
    || die "could not open a buffer for this read under $AGENT_TMP_ROOT"
  EVIDENCE_BUFFER="$buffer"
  # bash 3.2 has no `{VAR}>` fd-allocation syntax -- that is a bash 4.1+
  # feature and the dev host's only bash is 3.2.57. The descriptors are fixed
  # literal numbers instead of dynamically allocated ones; 8/9/10 are free
  # because nothing else in this script (or anything it execs) opens a
  # descriptor above 2. The variables still carry the numbers so every other
  # use site below (`>&"$BUF_W"`, `<&"$BUF_SCAN"`, `<&"$BUF_R"`) is unchanged.
  BUF_W=8 BUF_SCAN=9 BUF_R=10
  exec 8>"$buffer" 9<"$buffer" 10<"$buffer"
  rm -f "$buffer"
  EVIDENCE_BUFFER=""
}

# The provenance line and the bytes, or neither of them.
#
# The NUL count decides which, and it is counted rather than grepped for: bash
# cannot hold a NUL in a string, and `grep` is the very tool whose handling of
# one is the problem. `tr -dc` keeps only NULs, so `wc -c` is their count in a
# single pass over the scan descriptor.
attest_and_emit() {
  local provenance="$1" what="$2" nuls
  # Literal fd 8, matching the literal 8 that opened it in open_buffer -- see
  # the note there on why this is not `{BUF_W}<&-` (bash 3.2).
  exec 8>&-
  BUF_W=""

  nuls="$(tr -dc '\000' <&"$BUF_SCAN" | wc -c)" \
    || die "could not scan the buffered $what before printing it"
  exec 9<&-
  BUF_SCAN=""

  if (( nuls > 0 )) && (( ! ALLOW_BINARY )); then
    die "$what carries $nuls NUL byte(s), so a pipeline would read it as binary
  and answer 'not there' about bytes that are there -- with a clean exit under
  GNU grep and a 1 under the ugrep wrapper on the agents' PATH, and with the
  'binary file matches' notice on the stderr the documented idiom discards.
  Nothing was printed. This is a real diff or a real file, not a failure: re-run
  the same command with --text to get the bytes, and search them with 'grep -a'
  (or 'grep --text'), which matches on them normally."
  fi

  printf 'evidence: %s\n' "$provenance" >&2
  if (( nuls > 0 )); then
    printf 'evidence: --text was given, so %s NUL byte(s) are on stdout; plain grep will
  read this as binary and report no match. Use grep -a.\n' "$nuls" >&2
  fi
  cat <&"$BUF_R"
  exec 10<&-
  BUF_R=""
}

# One fetch, one blob, one provenance line.
#
# The fetch lands in a ref PRIVATE TO THIS PROCESS, and that is load-bearing.
# `FETCH_HEAD` looks like the obvious answer and is a shared mutable file: it is
# per-worktree, `config.sh` resolves `REPO` through `--git-common-dir`, and so
# every board process -- each `evidence.sh`, each `preflight.py`, `dispatch.sh`
# -- writes the one file `$REPO/.git/FETCH_HEAD`. Git takes no lock on it. Two
# concurrent calls and the loser reads the winner's SHA, exit 0, nothing on
# stderr.
#
# That is not a smaller bug than the one this script exists to fix, it is a
# worse one. `evidence.sh pr 7 deploy.sh` racing `evidence.sh main deploy.sh`
# returns main's bytes under a provenance line that says "PR #7 head" and quotes
# a real, current SHA -- so the audit record the card is required to carry is
# internally consistent and wrong, and the freshness question it exists to let
# the next tick ask ("was this newer than the merge it needed to see?") answers
# yes. Measured 15 out of 15 parallel pairs before this was a private ref.
fetch_and_show() {
  local refspec="$1" label="$2" path="$3" sha
  EVIDENCE_REF="$(evidence_ref "$$")"

  # `+` to force, since a re-run in the same shell would otherwise refuse a
  # non-fast-forward onto its own leftover ref.
  git -C "$REPO" fetch --quiet --no-tags origin "+$refspec:$EVIDENCE_REF" \
    || die "could not fetch $refspec from origin -- refusing to answer from a
  local ref, which is what made #159 look refuted. Note that origin is HTTPS
  with gh as the credential helper here, so a fetch that cannot authenticate
  usually means every gh call is about to fail too."

  sha="$(git -C "$REPO" rev-parse "$EVIDENCE_REF")"
  # Deleted before the read, not after: the blob is reachable from the object
  # store either way, and a `die` between here and the end must not leak a ref.
  git -C "$REPO" update-ref -d "$EVIDENCE_REF"
  EVIDENCE_REF=""

  # Named separately from the read so a path that does not exist at that ref is
  # reported as "not at this ref", not as an empty file. An empty answer reading
  # as an absent mechanism is exactly how the #159 grep lied.
  git -C "$REPO" cat-file -e "$sha:$path" 2>/dev/null \
    || die "$path does not exist at $label ($sha). That is an answer, but it is
  'the file is not there', not 'the mechanism is not there' -- check the path."

  local provenance
  printf -v provenance '%s @ %s (%s) fetched just now' "$path" "$label" "$sha"
  open_buffer
  git -C "$REPO" show "$sha:$path" >&"$BUF_W" \
    || die "could not read $path at $label ($sha) -- the blob is there, the read
  of it failed, and nothing was printed rather than half a file."
  attest_and_emit "$provenance" "$path at $label"
}

# The diff form. `gh pr diff` is already a server-side read, so it needs nothing
# from here except a provenance line and the same refusal to be stale.
#
# THE DIFF IS BUFFERED, NOT STREAMED, and the order is the whole point. Written
# the obvious way -- read the head, `gh pr diff` straight to stdout, re-read the
# head, die if it moved -- the one failing path emitted a complete, well-formed
# diff attributable to NEITHER SHA and then complained about it on stderr, which
# is the exact inversion of what `fetch_and_show` guarantees and what
# `test-evidence-reads-are-fresh.sh` pins for it. A resumed build agent pushing
# while the tick works the card is all it takes.
show_pr_diff() {
  local number="$1" head after provenance
  # gh infers the repository from its working directory, and every other form
  # here is anchored with `git -C "$REPO"`. Without this, an agent that had cd'd
  # elsewhere would be told "could not read pull request N from GitHub" for what
  # is really "you are not standing in a checkout".
  #
  # GNU `env --chdir` (and its `-C` short form) is not available on the BSD
  # `env` this runs under on the dev host, and even on Linux `-C` was only
  # added to coreutils in 2018 -- older GNU env doesn't have it either. A
  # subshell that cd's before running gh needs no flag from either userland,
  # so it is anchored the same way on every platform this has to run on.
  in_repo() ( cd "$REPO" && gh "$@" )

  head="$(in_repo pr view "$number" --json headRefOid -q .headRefOid)" \
    || die "could not read pull request $number from GitHub"

  open_buffer
  in_repo pr diff "$number" >&"$BUF_W" \
    || die "could not read the diff of PR $number"

  # Two calls, so the head could have moved between them and the provenance line
  # would then attribute this diff to a SHA that did not produce it. Say so
  # rather than sign for bytes nobody can check -- and say it having printed
  # nothing, so a caller that only reads stdout gets no answer rather than an
  # unattributable one.
  after="$(in_repo pr view "$number" --json headRefOid -q .headRefOid)" \
    || die "could not re-read pull request $number to confirm its head"
  [[ "$head" == "$after" ]] \
    || die "PR $number was pushed to while this ran ($head -> $after); the diff
  was read but not printed, because it is attributable to neither SHA. Run this
  again."

  # The bytes GitHub sent, and only those: no encoding hop, no re-added newline.
  printf -v provenance 'diff of PR #%s @ head %s fetched just now' "$number" "$head"
  attest_and_emit "$provenance" "the diff of PR #$number"
}

case "${1:-}" in
  main)
    [[ $# -eq 2 ]] || usage
    fetch_and_show "main" "origin/main" "$2"
    ;;
  pr)
    [[ $# -eq 2 || $# -eq 3 ]] || usage
    number="$2"
    [[ "$number" =~ ^[0-9]+$ ]] || die "pull request number must be numeric, got '$number'"
    if [[ $# -eq 2 ]]; then
      show_pr_diff "$number"
    else
      # `pull/<n>/head` rather than the branch name: a fork's branch is not on
      # this remote, and the head SHA may not be fetchable on its own.
      fetch_and_show "pull/$number/head" "PR #$number head" "$3"
    fi
    ;;
  *)
    usage
    ;;
esac
