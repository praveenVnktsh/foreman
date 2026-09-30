#!/usr/bin/env bash
# Claim: bin/self-update.sh finishes an update whose restart failed, never
# trusts a leaked FOREMAN_SELF_UPDATE_ROOT, leaves a clone that is ahead of
# its source alone, and restarts the dashboard with the tick.
#
# The failures each case prevents:
#   - The fast-forward comes before the restart. When install-skills.sh or
#     supervise.sh --restart failed, HEAD was already at the target, so every
#     later fire said "nothing to do" and the tick ran the old code for ever.
#   - FOREMAN_SELF_UPDATE_ROOT reached the tick through supervise.sh. A later
#     run in that environment skipped the copy-out, ran from the clone, and
#     its EXIT trap deleted bin/self-update.sh.
#   - A clone ahead of the latest release failed every fire as "not a
#     descendant", a permanently red timer over nothing.
#   - The dashboard kept serving the old code after an update.
#
# The real script, the real git and the real fast-forward run. supervise.sh,
# install-skills.sh and systemctl are the external boundary and are recorders.
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

upstream="$work_dir/upstream"
mkdir -p "$upstream/bin" "$upstream/skills/board"
cp "$repo_root/bin/self-update.sh" "$repo_root/bin/load-pairs.sh" \
   "$repo_root/bin/installation.py" "$upstream/bin/"
cat >"$upstream/bin/install-skills.sh" <<'STUB'
#!/usr/bin/env bash
printf 'relink\n' >> "${RECORD_DIR:?}/install-skills.log"
STUB
# Fails while $RECORD_DIR/fail-restart exists, standing in for a restart that
# could not replace the tick. Records the environment it was given.
cat >"$upstream/skills/board/supervise.sh" <<'STUB'
#!/usr/bin/env bash
env >"${RECORD_DIR:?}/supervise.env"
[[ -e "$RECORD_DIR/fail-restart" ]] && { echo "restart failed" >&2; exit 1; }
printf '%s\n' "$*" >> "$RECORD_DIR/supervise.log"
STUB
chmod +x "$upstream/bin/install-skills.sh" "$upstream/skills/board/supervise.sh" \
         "$upstream/bin/self-update.sh"
git_q "$upstream" init -q -b main
git_q "$upstream" add -A
git_q "$upstream" commit -q -m first

py_home="$work_dir/home"
mkdir -p "$py_home"
fixture_add_installation "$py_home" demo claude
install_home="$py_home/.foreman/demo"
install="$install_home/install"
git_q "$work_dir" clone -q "$upstream" "$install"

record="$work_dir/record"; mkdir -p "$record"

# systemctl: the dashboard unit reports installed, and a restart is recorded.
stub="$work_dir/stub"; mkdir -p "$stub"
cat >"$stub/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *is-enabled*foreman-dashboard.service*) exit 0 ;;
  *restart*foreman-dashboard.service*) printf 'dashboard\n' >> "${RECORD_DIR:?}/systemctl.log"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$stub/systemctl"

run_update() {
  HOME="$py_home" FOREMAN_HOME="$install_home" RECORD_DIR="$record" \
    FOREMAN_UPDATE_REF="origin/main" PATH="$stub:$PATH" \
    "$install/bin/self-update.sh" "$@" 2>&1
}
head_of() { git -C "$install" rev-parse HEAD; }
count() { [[ -f "$record/$1" ]] && grep -c . "$record/$1" || echo 0; }
new_upstream_commit() {
  printf '%s\n' "$1" >"$upstream/$1.txt"
  git_q "$upstream" add -A
  git_q "$upstream" commit -q -m "$1"
}
pending="$install_home/self-update-pending"

# =============================================================================
# Case: a failed restart is finished on the next fire
# =============================================================================
new_upstream_commit second
want="$(git -C "$upstream" rev-parse HEAD)"
touch "$record/fail-restart"
if out="$(run_update)"; then
  bad "an update whose restart failed exited 0: $out"
elif [[ "$(head_of)" == "$want" ]] && [[ -f "$pending" ]] && [[ "$(count supervise.log)" == 0 ]]; then
  ok "a failed restart leaves the pending marker behind the fast-forward"
else
  bad "failed restart -> head=$(head_of) pending=$([[ -f "$pending" ]] && echo yes || echo no): $out"
fi

rm -f "$record/fail-restart"
out="$(run_update)" || bad "the finishing fire exited non-zero: $out"
if grep -q "did not finish" <<<"$out" && [[ "$(count supervise.log)" == 1 ]] && [[ ! -f "$pending" ]]; then
  ok "the next fire finishes the restart even though HEAD is already at the target"
else
  bad "finishing fire -> restarts=$(count supervise.log) pending=$([[ -f "$pending" ]] && echo yes || echo no): $out"
fi

out="$(run_update)" || bad "the fire after finishing exited non-zero: $out"
if grep -q "nothing to do" <<<"$out" && [[ "$(count supervise.log)" == 1 ]]; then
  ok "once finished, the next fire is nothing to do again"
else
  bad "after finishing -> restarts=$(count supervise.log): $out"
fi

# =============================================================================
# Case: the dashboard is restarted with the tick
# =============================================================================
# Each attempt restarts it before the tick, so the failed attempt and the one
# that finished both count.
if [[ "$(count systemctl.log)" -ge 1 ]]; then
  ok "an installed dashboard is restarted by the update"
else
  bad "dashboard restarts=$(count systemctl.log)"
fi

# =============================================================================
# Case: a leaked FOREMAN_SELF_UPDATE_ROOT is not trusted
# =============================================================================
if ! grep -q '^FOREMAN_SELF_UPDATE' "$record/supervise.env"; then
  ok "the restart is not handed FOREMAN_SELF_UPDATE_ROOT or its proof"
else
  bad "the tick inherits: $(grep '^FOREMAN_SELF_UPDATE' "$record/supervise.env")"
fi

new_upstream_commit third
want="$(git -C "$upstream" rev-parse HEAD)"
out="$(FOREMAN_SELF_UPDATE_ROOT="$install" run_update)" || bad "an update under a leaked root exited non-zero: $out"
if [[ -f "$install/bin/self-update.sh" ]] && [[ "$(head_of)" == "$want" ]] \
   && [[ -z "$(git -C "$install" status --porcelain)" ]]; then
  ok "a leaked root still copies out, and the clone keeps bin/self-update.sh"
else
  bad "leaked root -> self-update.sh present=$([[ -f "$install/bin/self-update.sh" ]] && echo yes || echo no): $out"
fi

# =============================================================================
# Case: a clone ahead of its source is nothing to do
# =============================================================================
git_q "$install" commit -q --allow-empty -m "local, ahead of origin"
ahead="$(head_of)"
out="$(run_update)" || bad "a clone ahead of its source exited non-zero: $out"
if grep -q "is ahead of" <<<"$out" && [[ "$(head_of)" == "$ahead" ]]; then
  ok "a clone ahead of its source reports nothing to do and exits 0"
else
  bad "ahead -> $out"
fi

if [[ $fail -eq 0 ]]; then
  printf '\nPASS\n'
else
  printf '\nFAIL: see above\n' >&2
fi
exit "$fail"
