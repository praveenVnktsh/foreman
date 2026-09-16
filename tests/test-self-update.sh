#!/usr/bin/env bash
# Claim: bin/self-update.sh fast-forwards an installation's clone and restarts
# its tick, and refuses -- changing nothing -- in every case where a
# fast-forward is not what the operator would have done by hand.
#
# It drives the real script against a real git clone of a real upstream, and
# stubs only at the external boundary: skills/board/supervise.sh and
# bin/install-skills.sh are recorders, because what matters here is WHETHER
# they were run, and both have their own tests.
#
# The case that justifies the whole file is "nothing to do". A timer fires
# every five minutes forever, so a script that restarted the tick on a fire
# that changed nothing would kill and respawn the tick all day, and a board
# whose tick is always seconds old looks healthy while getting nothing done.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/instance-fixture.sh
source "$repo_root/tests/lib/instance-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }

# UPSTREAM: what origin/main is. It carries the real bin/ so the script under
# test is the real one, and stub skills so nothing spawns an agent.
upstream="$work_dir/upstream"
mkdir -p "$upstream/bin" "$upstream/skills/board"
cp "$repo_root/bin/self-update.sh" "$repo_root/bin/load-pairs.sh" \
   "$repo_root/bin/installation.py" "$upstream/bin/"

cat > "$upstream/bin/install-skills.sh" <<'STUB'
#!/usr/bin/env bash
printf 'relink\n' >> "${RECORD_DIR:?}/install-skills.log"
STUB
cat > "$upstream/skills/board/supervise.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RECORD_DIR:?}/supervise.log"
STUB
chmod +x "$upstream/bin/install-skills.sh" "$upstream/skills/board/supervise.sh" \
         "$upstream/bin/self-update.sh"

git_q "$upstream" init -q -b main
git_q "$upstream" add -A
git_q "$upstream" commit -q -m "first"

# THE INSTALLATION. installation.py reads the home as the PARENT of the clone,
# so the clone must sit at <home>/install for the derivation under test to be
# the real one.
py_home="$work_dir/home"
mkdir -p "$py_home"
fixture_add_installation "$py_home" demo claude
install_home="$py_home/.foreman/demo"
install="$install_home/install"
git_q "$work_dir" clone -q "$upstream" "$install"

record="$work_dir/record"; mkdir -p "$record"
run_update() {
  HOME="$py_home" FOREMAN_HOME="$install_home" RECORD_DIR="$record" \
    "$install/bin/self-update.sh" "$@" 2>&1
}
head_of() { git -C "$install" rev-parse HEAD; }
restarts() { [[ -f "$record/supervise.log" ]] && grep -c -- '--restart' "$record/supervise.log" || echo 0; }
relinks() { [[ -f "$record/install-skills.log" ]] && grep -c relink "$record/install-skills.log" || echo 0; }

# --- nothing to do: no restart, no relink, exit 0
before="$(head_of)"
out="$(run_update)" || bad "an up-to-date clone exited non-zero: $out"
if grep -q "already at" <<<"$out" && [[ "$(restarts)" == 0 && "$(head_of)" == "$before" ]]; then
  ok "an up-to-date clone changes nothing and does not restart the tick"
else
  bad "up-to-date clone -> restarts=$(restarts) out=$out"
fi

# --- unknown argument is refused, not run
if out="$(run_update --restrat 2>&1)"; then
  bad "a mistyped flag was accepted: $out"
else
  code=$?
  [[ "$code" == 2 ]] && grep -q "unrecognised argument" <<<"$out" \
    && ok "a mistyped flag exits 2 and names itself" \
    || bad "mistyped flag -> exit $code: $out"
fi

# --- a new upstream commit, touching no skill directory
printf 'x\n' > "$upstream/README.md"
git_q "$upstream" add -A
git_q "$upstream" commit -q -m "second"
new_sha="$(git -C "$upstream" rev-parse HEAD)"

# --dry-run first: it must reach the decision and change nothing.
before="$(head_of)"
out="$(run_update --dry-run)" || bad "--dry-run exited non-zero: $out"
if grep -q "would fast-forward" <<<"$out" && [[ "$(head_of)" == "$before" && "$(restarts)" == 0 ]]; then
  ok "--dry-run reports the fast-forward it would do and changes nothing"
else
  bad "dry run -> head moved=$([[ "$(head_of)" != "$before" ]] && echo yes || echo no) restarts=$(restarts): $out"
fi

out="$(run_update)" || bad "the update exited non-zero: $out"
if [[ "$(head_of)" == "$new_sha" && "$(restarts)" == 1 && "$(relinks)" == 0 ]]; then
  ok "a new commit is fast-forwarded, the tick restarted, skills left alone"
else
  bad "update -> head=$(head_of) want=$new_sha restarts=$(restarts) relinks=$(relinks): $out"
fi

# --- a commit that ADDS a skill directory must relink; a symlink cannot
#     follow a name that did not exist when it was made.
mkdir -p "$upstream/skills/newskill"
printf '# s\n' > "$upstream/skills/newskill/SKILL.md"
git_q "$upstream" add -A
git_q "$upstream" commit -q -m "third: a new skill"
out="$(run_update)" || bad "the skill-adding update exited non-zero: $out"
if [[ "$(relinks)" == 1 && "$(restarts)" == 2 ]]; then
  ok "a new skill directory relinks skills, then restarts the tick"
else
  bad "skill-adding update -> relinks=$(relinks) restarts=$(restarts): $out"
fi

# --- a dirty clone is refused, and nothing is discarded
printf 'operator edit\n' > "$install/README.md"
printf 'y\n' > "$upstream/other.txt"
git_q "$upstream" add -A; git_q "$upstream" commit -q -m "fourth"
before="$(head_of)"; r_before="$(restarts)"
if out="$(run_update 2>&1)"; then
  bad "a dirty clone was updated anyway: $out"
else
  if grep -q "local modifications" <<<"$out" \
     && [[ "$(head_of)" == "$before" && "$(restarts)" == "$r_before" ]] \
     && grep -q "operator edit" "$install/README.md"; then
    ok "a dirty clone is refused, its edit kept, and the tick left alone"
  else
    bad "dirty clone -> $out"
  fi
fi
git -C "$install" checkout -q -- README.md

# --- a clone parked on another branch is refused
git_q "$install" checkout -q -b investigating
before="$(head_of)"
if out="$(run_update 2>&1)"; then
  bad "a clone off main was updated anyway: $out"
else
  grep -q "expected main" <<<"$out" && [[ "$(head_of)" == "$before" ]] \
    && ok "a clone that is not on main is refused, naming what was expected" \
    || bad "off-main clone -> $out"
fi
git_q "$install" checkout -q main

# --- a force-pushed origin is refused rather than reset
git_q "$upstream" checkout -q --detach
git_q "$upstream" branch -q -D main
git_q "$upstream" checkout -q -b main HEAD~3
printf 'rewritten\n' > "$upstream/divergent.txt"
git_q "$upstream" add -A; git_q "$upstream" commit -q -m "rewritten history"
before="$(head_of)"; r_before="$(restarts)"
if out="$(run_update 2>&1)"; then
  bad "a non-fast-forward was applied: $out"
else
  grep -q "not a descendant" <<<"$out" \
    && [[ "$(head_of)" == "$before" && "$(restarts)" == "$r_before" ]] \
    && ok "a force-pushed origin is refused; the clone is not reset" \
    || bad "force-push -> $out"
fi

[[ "$fail" -eq 0 ]] && printf 'PASS: self-update fast-forwards or refuses, and never restarts for nothing\n'
exit "$fail"
