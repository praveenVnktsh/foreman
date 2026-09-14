# The one reader of this project's NUL-separated KEY, VALUE wire format.
#
# SOURCE this file, never run it: `. "<install root>/bin/load-pairs.sh"`. It
# defines one function, runs nothing, and sets no shell option -- a `set` here
# would hand flags to whichever script sourced it, and every caller has already
# chosen its own.
#
# ONE FACT, ONE PLACE. Five loops used to read this format and four carried a
# verbatim copy of the temp-file paragraph below: skills/board/config.sh,
# bin/install.sh, bin/install-skills.sh, bin/install-service.sh and
# bin/boardctl. Two reviewers found the copies on 2026-09-14. Five copies of a
# bash 3.2 rule are corrected in one place or in none.
#
# Read one of this installation's loaders -- bin/installation.py, bin/boards.py,
# bin/contract.py -- into this shell. All three emit NUL-separated KEY, VALUE
# pairs and always emit every key.
#
# Through a TEMP FILE, never a `$(...)` capture: bash 3.2 silently discards NUL
# bytes in command substitution (measured on this machine -- `printf 'a\0b\0'`
# captured through `$(...)` comes back 2 bytes, not 4), which would make every
# key end up unset with a zero exit status. A file preserves the NUL delimiters
# and lets the read loop and the exit-status check both work.
#
# The locals are lowercase and the key regex is uppercase-only, so a loader can
# never emit a key that overwrites this function's own state.
#
# THE ENVIRONMENT WINS over the file, for every key. A caller that needs the
# installation's own value instead unsets that key before the call and says so
# there -- bin/boardctl and the three installers all do.
_foreman_load_pairs() { # <what> <loader> [args...]
  local what="$1"; shift
  local file key value
  file="$(mktemp)" || {
    printf 'foreman: mktemp failed; cannot read %s\n' "$what" >&2
    return 1
  }
  if ! "$@" >"$file"; then
    rm -f "$file"
    printf 'foreman: %s did not load (see above)\n' "$what" >&2
    return 1
  fi
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Environment wins. `-` and not `:-`: an explicitly empty override must
    # mean empty, the same distinction HIGH_RISK_PATHS depends on.
    eval "$key=\"\${$key-\$value}\""
  done <"$file"
  rm -f "$file"
}
