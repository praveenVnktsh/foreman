#!/usr/bin/env bash
# Claim: bin/install.sh writes <home>/foreman.toml, where the home is the
# parent of the clone it runs from, declaring the harness, the four stage
# models and the fallback defaults. Run again, it refuses and leaves the file
# byte for byte as it was, so an operator's own edits -- a [fallback.floor],
# say -- survive a second install.
#
# The failure it prevents: foreman.toml decides which subscription every card
# spends. An install that rewrote it on a re-run would silently drop the
# floors an operator set to keep a stage off a weak model.
#
# The real install.sh and installation.py run from a copy of bin/ placed at
# <home>/install, the layout docs/INSTALLING.md describes. Nothing is stubbed:
# install.sh calls no external service.
set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolved: installation.py reports the home through realpath, and on macOS
# the temporary directory sits behind the /var -> /private/var symlink.
work="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# A fresh home per case, with the clone at <home>/install.
new_home() { # <name> -- prints the home
  local home="$work/$1/.foreman"
  mkdir -p "$home/install"
  cp -R "$root/bin" "$home/install/bin"
  printf '%s' "$home"
}

# FOREMAN_HOME and HARNESS unset: identity comes from the path, and a stray
# value in the caller's shell must not decide which home is written.
install() { # <home> [args...]
  local home="$1"; shift
  env -u FOREMAN_HOME -u HARNESS -u FOREMAN_ROOT HOME="$work" \
    bash "$home/install/bin/install.sh" "$@" 2>&1
}

# --- codex: every model named, written into the clone's parent
home="$(new_home codex)"
out="$(install "$home" --harness codex --model-tick t1 --model-plan p1 \
         --model-build b1 --model-review r1)"
rc=$?
toml="$home/foreman.toml"
if [[ $rc -eq 0 && -f "$toml" ]] \
   && [[ "$out" == *"foreman declared in $home/foreman.toml"* ]]; then
  ok "writes foreman.toml into the parent of the clone and says where"
else
  bad "codex install rc=$rc: $out"
fi

want="$(cat <<'TOML'
harness = "codex"

[models]
tick = "t1"
plan = "p1"
build = "b1"
review = "r1"

[fallback]
tiers = []
cooldown_minutes = 60
TOML
)"
got="$(grep -v '^#' "$toml" 2>/dev/null | sed '/./,$!d')"
[[ "$got" == "$want" ]] \
  && ok "declares the harness, the four models, and no tiers for codex" \
  || bad "codex foreman.toml is: $got"

[[ "$out" == *"install-skills.sh"* && "$out" == *"boardctl add"* ]] \
  && ok "names the next two steps" \
  || bad "no next steps printed: $out"

# --- claude: no models named, so Claude's defaults and tiers
home="$(new_home claude)"
out="$(install "$home" --harness claude)" || bad "claude install failed: $out"
toml="$home/foreman.toml"
grep -qx 'harness = "claude"' "$toml" \
  && grep -qx 'build = "opus"' "$toml" \
  && grep -qx 'tiers = \["fable", "opus", "sonnet", "haiku"\]' "$toml" \
  && ok "claude gets its default models and fallback tiers" \
  || bad "claude foreman.toml is: $(cat "$toml")"

# --- a second run changes nothing
before="$(cat "$toml")"
if out="$(install "$home" --harness claude)"; then
  bad "a second install succeeded, so it may have rewritten the file: $out"
else
  [[ "$out" == *"already exists"* && "$(cat "$toml")" == "$before" ]] \
    && ok "a second install refuses and leaves the file identical" \
    || bad "second install -> $out"
fi

# --- an operator's floor survives a re-install, even one naming another harness
printf '\n[fallback.floor]\nplan = "opus"\n' >>"$toml"
before="$(cat "$toml")"
out="$(install "$home" --harness codex --model-tick a --model-plan b \
         --model-build c --model-review d)"
if [[ "$(cat "$toml")" == "$before" ]] && [[ "$out" == *"already exists"* ]]; then
  ok "an operator's [fallback.floor] survives a re-install"
else
  bad "re-install touched the operator's file: $out; now: $(cat "$toml")"
fi

# --- refusals write nothing
home="$(new_home refusals)"
out="$(install "$home" --harness codex --model-tick t1)"
[[ $? -ne 0 && ! -e "$home/foreman.toml" && "$out" == *"no plan model"* ]] \
  && ok "codex with a model unset is refused and writes nothing" \
  || bad "codex missing a model -> $out"

out="$(install "$home" --harness claude --colour blue)"
[[ $? -ne 0 && ! -e "$home/foreman.toml" && "$out" == *"unknown argument: --colour"* ]] \
  && ok "an unknown flag is refused and writes nothing" \
  || bad "unknown flag -> $out"

out="$(install "$home")"
[[ $? -ne 0 && ! -e "$home/foreman.toml" && "$out" == *"needs --harness"* ]] \
  && ok "no --harness is refused and writes nothing" \
  || bad "no harness -> $out"

exit "$fail"
