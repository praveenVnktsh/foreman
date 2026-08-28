#!/usr/bin/env bash
# The specific strings that used to leak into every dispatched agent's prompt,
# before `brief.py` became contract-driven (see
# test-brief-uses-the-contract.sh, which sources this and asserts none of them
# survive in a generated prompt).
#
# Kept in their own one-line file, sourced rather than inlined, so that
# tests/test-no-target-specifics.sh's scan can exclude exactly this file and
# nothing else: these words are a standing regression check, not leftover
# prose describing whose infrastructure this was. Everything else in
# tests/test-brief-uses-the-contract.sh -- 370-odd lines of it -- stays
# covered by that scan.
LEGACY_LEAKED_STRINGS=("murmr" "mango" "Praveen" "PRA-" "just test-all")
