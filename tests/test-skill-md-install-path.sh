#!/usr/bin/env bash
# SKILL.md is what the tick agent actually reads and runs commands from --
# not README.md. It used to hardcode `B=~/.claude/skills/board` (and 14 other
# spots) as the installation root, left over from before this project had an
# instance model at all. README.md's actual, and only documented, install
# instruction is `git clone <url> ~/.foreman/install`, giving
# `~/.foreman/install/skills/board/config.sh`. config.sh derives
# `bin/contract.py`'s path as two directories up from its OWN location
# (`skills/board/config.sh` -> `bin/contract.py`), which resolves correctly
# for `~/.foreman/install/...` but not for a tick agent that `cd`s into
# `~/.claude/skills/board` on SKILL.md's say-so and finds no `bin/` two
# levels up at all -- silently, since nothing here raises on a wrong path
# fed to config.sh by hand; it just fails to find `~/.claude/bin/contract.py`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# Both spellings. The tilde form was the only one checked, and the cron line in
# this same file said `$HOME/.claude/skills/board/supervise.sh` for months
# underneath a passing test -- a documented watchdog path that does not exist
# under the documented install.
if grep -qE '(~|\$HOME)/\.claude/skills/board' "$repo_root/skills/board/SKILL.md"; then
  bad "SKILL.md still tells the tick agent to use ~/.claude/skills/board -- README.md's only documented install path is ~/.foreman/install"
else
  ok "SKILL.md no longer hardcodes ~/.claude/skills/board"
fi

# Named at all, and no OTHER install root named beside it.
#
# This used to assert "at least 10 references". A count is not a behaviour: it
# fails when somebody legitimately adds an eleventh, passes when ten of them are
# wrong, and tells a reader nothing about what must be true. What must be true
# is that SKILL.md names one install root and it is the documented one.
if grep -q '~/.foreman/install/skills/board' "$repo_root/skills/board/SKILL.md"; then
  ok "SKILL.md names the documented install root"
else
  bad "SKILL.md never references ~/.foreman/install/skills/board"
fi

others="$(grep -oE '(~|\$HOME)/[A-Za-z0-9._/-]*/skills/board' "$repo_root/skills/board/SKILL.md" \
  | sed 's|^[$]HOME|~|' | sort -u | grep -v '^~/.foreman/install/skills/board$' || true)"
if [[ -z "$others" ]]; then
  ok "SKILL.md names no other install root"
else
  bad "SKILL.md also names: $others"
fi

# The end-to-end proof: build the EXACT layout SKILL.md now tells the tick
# agent to use -- <root>/skills/board/config.sh next to <root>/bin/contract.py
# -- and show config.sh finds its contract loader through it, the same
# derivation test-config-resolves-instance.sh already exercises generically.
# Here it is anchored specifically to what SKILL.md's own prose says the root
# is, so a future edit that moves SKILL.md's paths without moving config.sh's
# derivation (or vice versa) fails here even if the generic test still passes.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

install_root="$work_dir/dot-foreman-install"
mkdir -p "$install_root/skills/board" "$install_root/bin"
cp "$repo_root/skills/board/config.sh" "$install_root/skills/board/config.sh"
cp "$repo_root/bin/contract.py" "$install_root/bin/contract.py"
cp "$repo_root/bin/boards.py" "$install_root/bin/boards.py"
cp "$repo_root/bin/tmp-dir.sh" "$install_root/bin/tmp-dir.sh"
chmod +x "$install_root/bin/tmp-dir.sh"

target="$work_dir/target"
mkdir -p "$target"
git -C "$target" init -q -b main
cat >"$target/board.toml" <<'TOML'
[linear]
team = "PRA"
project = "example"
[checks]
required = ["Tests"]
ci_workflow = "CI"
[test]
command = "true"
TOML

foreman_home="$work_dir/foreman-home"
inst="$foreman_home/instances/demo"
mkdir -p "$inst"
# A board is declared in one file now, not as a directory holding
# instance.env. The runtime directory still exists; it just no longer
# carries the declaration.
printf '[boards.demo]\nrepo = "%s"\n' "$target" >"$foreman_home/boards.toml"

if out="$(env FOREMAN_HOME="$foreman_home" FOREMAN_INSTANCE=demo bash -c \
     ". '$install_root/skills/board/config.sh'; printf '%s' \"\$TEST_COMMAND\"" 2>&1)"; then
  if [[ "$out" == "true" ]]; then
    ok "config.sh at the path SKILL.md now names finds bin/contract.py and loads the target's contract"
  else
    bad "config.sh loaded but produced the wrong value: $out"
  fi
else
  bad "config.sh at ~/.foreman/install/skills/board/config.sh could not load the contract: $out"
fi

exit "$fail"
