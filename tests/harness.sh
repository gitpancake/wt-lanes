#!/usr/bin/env bash
# Shared assertions for the wt-lanes test suite. Source from each test file.
# Zero dependencies beyond bash 3.2 + git. Each test file runs standalone:
#   bash tests/test-dag-parse.sh
# Whole suite: tests/run.sh

set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-lanes-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

PASSES=0
FAILS=0

pass() { PASSES=$((PASSES + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# assert_eq <name> <got> <expected>
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "'$3' not found in: $2"; fi
}

# assert_rc <name> <got> <expected>
assert_rc() {
  if [[ "$2" -eq "$3" ]]; then pass "$1"; else fail "$1" "expected rc $3, got rc $2"; fi
}

assert_dir()    { if [[ -d "$2" ]]; then pass "$1"; else fail "$1" "missing dir: $2"; fi; }
assert_no_dir() { if [[ ! -d "$2" ]]; then pass "$1"; else fail "$1" "dir still exists: $2"; fi; }

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSES" "$FAILS"
  (( FAILS == 0 ))
}
