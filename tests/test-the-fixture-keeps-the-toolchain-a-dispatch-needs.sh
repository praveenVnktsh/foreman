#!/usr/bin/env bash
# The fixture blocks the operator's knobs, and keeps the toolchain that makes
# the suite's own interpreters runnable.
#
# `dispatch_fixture_run` builds the dispatch's environment with `env -i` and an
# allowlist, so a variable nobody allowlisted is gone. That is the point for
# PLAN_MODEL. It is a bug for LD_LIBRARY_PATH: PATH says where `python3` lives
# and LD_LIBRARY_PATH says where its shared libraries live, so a dispatch given
# one without the other gets an interpreter that cannot start.
#
# This happened on CI, and cost a full round. `actions/setup-python` puts a
# `python3` on PATH that dies with `error while loading shared libraries:
# libpython3.12.so.1.0` when LD_LIBRARY_PATH is stripped. Every dispatch died
# at its first python3 call -- the contract load -- and every test driving the
# fixture reported the same thing: "the dispatch never reached `claude --bg`".
# None of them named python3, because the dispatch's output went to /dev/null.
#
# The `python3` below is that interpreter, in the smallest form that
# reproduces it: it refuses unless LD_LIBRARY_PATH is set, and is otherwise the
# real one. No real library is involved, so the test does not need CI's Python
# to prove CI's failure.
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

# Set before the fixture reads either. LD_LIBRARY_PATH is what the runner
# exports beside its PATH; the shim is what that PATH resolves `python3` to.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-$work_dir/lib}"
export PATH="$shim_bin:$PATH"

dispatch_fixture_setup "$work_dir" "$repo_root"
dispatch_fixture_run --ticket PRA-1 --role plan --attempt 1

got="$(dispatch_fixture_model)"
if [[ "$got" == "'fable'" ]]; then
  ok "a dispatch reaches \`claude --bg\` under a python3 that needs LD_LIBRARY_PATH"
else
  bad "a dispatch reaches \`claude --bg\` under a python3 that needs LD_LIBRARY_PATH: got ${got:-nothing}"
  printf -- '----- %s -----\n' "$DISPATCH_RUN_LOG" >&2
  cat "$DISPATCH_RUN_LOG" >&2
  printf -- '--------------------\n' >&2
fi

[[ "$fail" -eq 0 ]] &&
  printf 'PASS: the fixture keeps the toolchain a dispatch needs\n'
exit "$fail"
