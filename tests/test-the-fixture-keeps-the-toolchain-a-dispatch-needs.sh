#!/usr/bin/env bash
# The fixture keeps EVERY name the toolchain needs, not just the one name a
# hand-maintained list happened to have written down.
#
# The old version of this test stood up a python3 that refuses without
# LD_LIBRARY_PATH -- the one name PRA-276's allowlist had recorded -- so it
# would have stayed green even if dispatch_fixture_run went back to a fixed
# list and dropped every other name. It proved one instance, not the class.
# This version proves the class by asking two different programs, needing two
# different and otherwise-unrelated names, and checking that both survive.
#
# `dispatch_fixture_run` builds the dispatch's environment with `env -i` and
# an allowlist, so a variable nobody allowlisted is gone. That is the point
# for PLAN_MODEL. It is a bug for a name a real interpreter or a real `git`
# needs to start, because a dispatch given one such name without the other it
# depends on gets a toolchain that cannot run.
#
# python3, kept from the original incident: this happened on CI, and cost a
# full round. `actions/setup-python` puts a `python3` on PATH that dies with
# `error while loading shared libraries: libpython3.12.so.1.0` when
# LD_LIBRARY_PATH is stripped. Every dispatch died at its first python3 call
# -- the contract load -- and every test driving the fixture reported the
# same thing: "the dispatch never reached `claude --bg`". None of them named
# python3, because the dispatch's output went to /dev/null.
#
# git, added for PRA-349: a second shim, refusing without a SECOND variable,
# picked so that nothing in this repository has written its name down before
# this test runs. A real git variable -- GIT_EXEC_PATH, say -- would not
# prove the claim: it could pass this test by having already been listed in
# dispatch-fixture.sh's allowlist, the same way the old single-name test
# passed by asking for the one name already there. DISPATCH_FIXTURE_GIT_CANARY
# is invented and grepped for nowhere else in this repository, so the only
# way it reaches the shim is _dispatch_derive_toolchain finding it by running
# git and watching git refuse, not by anyone having typed the name in advance.
#
# The git shim answers `--version` WHATEVER its variable says, and refuses
# every other argv without it. That is the second thing this test proves, and
# it is the shape of every real toolchain program that keeps a launcher: `env
# PYTHONHOME=/nonexistent python3 --version` prints a version and exits 0
# while `python3 -c 'import json'` dies at `init_fs_encoding`, and a git whose
# subcommands live under a moved GIT_EXEC_PATH still reports its version. A
# derivation that asks `--version` records such a program as needing nothing,
# strips the name it needed, and hands the dispatch a toolchain that dies at
# its first real call -- the failure this whole card is about, rebuilt by the
# thing meant to remove it. So the probe has to do a dispatch's own work, and
# this shim is what holds it to that.
#
# Both shims below are the smallest form that reproduces a toolchain program
# that cannot work: each refuses unless its variable is set, and is otherwise
# the real program. No real broken library or git build is involved, so the
# test does not need a broken CI runner to prove CI's failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dispatch-fixture.sh
source "$repo_root/tests/lib/dispatch-fixture.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

real_python3="$(command -v python3)"
real_git="$(command -v git)"
shim_bin="$work_dir/toolchain-bin"
mkdir -p "$shim_bin"

cat > "$shim_bin/python3" <<PY
#!/usr/bin/env bash
if [[ -z "\${LD_LIBRARY_PATH:-}" ]]; then
  echo "python3: error while loading shared libraries: libpython3.12.so.1.0: cannot open shared object file: No such file or directory" >&2
  exit 127
fi
exec "$real_python3" "\$@"
PY
chmod +x "$shim_bin/python3"

# DISPATCH_FIXTURE_GIT_CANARY has no meaning to git. It is invented for this
# test alone, so that its presence in $DISPATCH_RUN_LOG's environment can only
# come from _dispatch_derive_toolchain finding it by probing, never from a
# maintainer having copied a real git variable into an allowlist somewhere.
cat > "$shim_bin/git" <<SH
#!/usr/bin/env bash
# --version first, and unconditionally: this shim reports a version on an
# environment it cannot do any other work under.
if [[ "\$1" == "--version" ]]; then
  exec "$real_git" --version
fi
if [[ -z "\${DISPATCH_FIXTURE_GIT_CANARY:-}" ]]; then
  echo "git: DISPATCH_FIXTURE_GIT_CANARY is not set" >&2
  exit 1
fi
exec "$real_git" "\$@"
SH
chmod +x "$shim_bin/git"

# Set before dispatch_fixture_setup, because setup runs git itself to seed the
# origin and the target. The derivation has no such requirement -- it runs
# before each dispatch and re-runs when its answer stops holding -- but a shim
# that refuses during setup takes the fixture down before any of that.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-$work_dir/lib}"
export DISPATCH_FIXTURE_GIT_CANARY=1
export PATH="$shim_bin:$PATH"

dispatch_fixture_setup "$work_dir" "$repo_root"
dispatch_fixture_run --ticket PRA-1 --role plan --attempt 1

got="$(dispatch_fixture_model)"
if [[ "$got" == "'fable'" ]]; then
  ok "a dispatch reaches \`claude --bg\` under a python3 that needs LD_LIBRARY_PATH and a git that needs DISPATCH_FIXTURE_GIT_CANARY"
else
  bad "a dispatch reaches \`claude --bg\` under a python3 that needs LD_LIBRARY_PATH and a git that needs DISPATCH_FIXTURE_GIT_CANARY: got ${got:-nothing}"
  dispatch_fixture_show_run_log
fi

[[ "$fail" -eq 0 ]] &&
  printf 'PASS: the fixture keeps the toolchain a dispatch needs\n'
exit "$fail"
