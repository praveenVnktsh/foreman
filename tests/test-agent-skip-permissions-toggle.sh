#!/usr/bin/env bash
# AGENT_SKIP_PERMISSIONS used to have no off switch at all.
#
# config.sh read it with `${AGENT_SKIP_PERMISSIONS:-1}` -- `:-`, so an
# explicitly empty override (`AGENT_SKIP_PERMISSIONS=`) was silently
# reinstated to "1", the same class of bug HOST_SLOT_STALE_MINUTES had. And
# dispatch.sh tested it with a plain `[[ -n "$AGENT_SKIP_PERMISSIONS" ]]`,
# which reads the STRING "0" as non-empty -- true, i.e. "on" -- exactly the
# value an operator would type expecting it to mean off.
# `AGENT_SKIP_PERMISSIONS=` and `AGENT_SKIP_PERMISSIONS=0` must both now
# select `--permission-mode acceptEdits` instead of
# `--dangerously-skip-permissions`, and the unset default must still be on.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board_dir="$repo_root/skills/board"

# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A shim skill dir, identical to the real one except preflight.py -- which
# needs an authenticated `gh` this suite may not assume it has, and is not
# what this file is about. Same two-level shape config.sh's contract loader
# depends on (skills/board/ next to bin/), the same technique
# test-brief-uses-the-contract.sh uses for the same reason.
shim_root="$work_dir/shim-repo"
mkdir -p "$shim_root/bin" "$shim_root/skills/board"
ln -s "$repo_root/bin/contract.py" "$shim_root/bin/contract.py"
ln -s "$repo_root/bin/boards.py" "$shim_root/bin/boards.py"
ln -s "$repo_root/bin/tmp-dir.sh" "$shim_root/bin/tmp-dir.sh"
shim="$shim_root/skills/board"
ln -s "$board_dir/config.sh" "$shim/config.sh"
ln -s "$board_dir/dispatch.sh" "$shim/dispatch.sh"
ln -s "$board_dir/withlock.py" "$shim/withlock.py"
cat > "$shim/preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
chmod +x "$shim/preflight.py"
dispatch="$shim/dispatch.sh"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

git_q() {
  git -c user.name="Toggle Test" -c user.email="toggle-test@example.com" \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

origin="$work_dir/origin.git"
target="$work_dir/target"
git_q init -q --bare "$origin"
git_q init -q -b main "$target"
fixture_board_toml "$target"
echo seed > "$target/seed.txt"
git_q -C "$target" add -A
git_q -C "$target" commit -q -m Seed
git_q -C "$target" remote add origin "$origin"
git_q -C "$target" push -q origin main

home="$work_dir/home"
fixture_add_instance "$home" demo "$target"

argv_log="$work_dir/argv.log"
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--bg" ]]; then
  printf '%s\n' "\$*" >"$argv_log"
  echo "stub-session-\$\$"
  exit 0
fi
if [[ "\$1" == "agents" ]]; then
  echo '[]'
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/claude"

prompt_file="$work_dir/prompt.md"
echo "do the thing" > "$prompt_file"

run_dispatch() { # AGENT_SKIP_PERMISSIONS=<value or unset via ''-marker>, ticket
  local value="$1" ticket="$2"
  : >"$argv_log"
  if [[ "$value" == "__unset__" ]]; then
    env -u AGENT_SKIP_PERMISSIONS HOME="$home" FOREMAN_INSTANCE=demo PATH="$stub_dir:$PATH" \
      "$dispatch" --ticket "$ticket" --role build --attempt 1 --prompt-file "$prompt_file" \
      >/dev/null 2>&1 || true
  else
    env AGENT_SKIP_PERMISSIONS="$value" HOME="$home" FOREMAN_INSTANCE=demo PATH="$stub_dir:$PATH" \
      "$dispatch" --ticket "$ticket" --role build --attempt 1 --prompt-file "$prompt_file" \
      >/dev/null 2>&1 || true
  fi
}

check_flag() { # description ticket expect-skip(0|1)
  local desc="$1" ticket="$2" expect_skip="$3"
  local argv; argv="$(cat "$argv_log" 2>/dev/null || true)"
  if [[ -z "$argv" ]]; then
    bad "$desc: dispatch.sh never reached claude --bg"
    return
  fi
  local has_skip=0 has_accept=0
  [[ "$argv" == *"--dangerously-skip-permissions"* ]] && has_skip=1
  [[ "$argv" == *"--permission-mode acceptEdits"* ]] && has_accept=1
  if [[ "$expect_skip" == "1" ]]; then
    if [[ "$has_skip" == "1" && "$has_accept" == "0" ]]; then
      ok "$desc: --dangerously-skip-permissions"
    else
      bad "$desc: expected --dangerously-skip-permissions, got: $argv"
    fi
  else
    if [[ "$has_accept" == "1" && "$has_skip" == "0" ]]; then
      ok "$desc: --permission-mode acceptEdits"
    else
      bad "$desc: expected --permission-mode acceptEdits, got: $argv"
    fi
  fi
}

run_dispatch "__unset__" PRA-1
check_flag "unset AGENT_SKIP_PERMISSIONS defaults to on" PRA-1 1

run_dispatch "" PRA-2
check_flag "explicitly empty AGENT_SKIP_PERMISSIONS turns it off" PRA-2 0

run_dispatch "0" PRA-3
check_flag "AGENT_SKIP_PERMISSIONS=0 turns it off" PRA-3 0

run_dispatch "1" PRA-4
check_flag "AGENT_SKIP_PERMISSIONS=1 keeps it on" PRA-4 1

[[ "$fail" -eq 0 ]] && printf 'PASS: AGENT_SKIP_PERMISSIONS has a working off switch\n'
exit "$fail"
