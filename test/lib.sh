#!/usr/bin/env bash
# Shared test helper functions
# Source this file at the top of every test script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Guard against double-sourcing
if [[ "${_TEST_LIB_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_TEST_LIB_LOADED=1

# REPO_DIR defaults to the parent of the test/ directory
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echof() { echo "== $* =="; }
pass()  { echo "PASS: $*"; }
die()   { echo "FAIL: $*" >&2; exit 1; }
skip()  { echo "SKIP: $*"; }
warn()  { echo "WARN: $*"; }

make_executable() { chmod +x "$1"; }
