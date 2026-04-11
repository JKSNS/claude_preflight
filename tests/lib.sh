#!/usr/bin/env bash
# tests/lib.sh - Tiny test helper. No external deps. Source from each test.
#
# Usage in a test file:
#   source "$(dirname "$0")/lib.sh"
#   it "does the thing" && {
#       result="$(some_command)"
#       assert_eq "$result" "expected" "result mismatch"
#   }
set -uo pipefail

PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=${FAIL_COUNT:-0}
CURRENT_TEST=""

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

it() {
    CURRENT_TEST="$1"
    return 0
}

# A finished assertion writes a single PASS or FAIL line.
_record() {
    local status="$1" msg="$2"
    if [ "$status" = "pass" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "    ${GREEN}✓${NC} ${CURRENT_TEST}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "    ${RED}✗${NC} ${CURRENT_TEST} — ${msg}"
    fi
}

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [ "$actual" = "$expected" ]; then
        _record pass ""
    else
        _record fail "expected '${expected}' got '${actual}' ${msg}"
    fi
}

assert_exit() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [ "$actual" = "$expected" ]; then
        _record pass ""
    else
        _record fail "expected exit ${expected} got ${actual} ${msg}"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if echo "$haystack" | grep -qF -- "$needle"; then
        _record pass ""
    else
        _record fail "expected to contain '${needle}' ${msg}"
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [ -e "$path" ]; then
        _record pass ""
    else
        _record fail "expected file '${path}' to exist ${msg}"
    fi
}

assert_file_missing() {
    local path="$1" msg="${2:-}"
    if [ ! -e "$path" ]; then
        _record pass ""
    else
        _record fail "expected file '${path}' to NOT exist ${msg}"
    fi
}

# Make a clean throwaway repo for each test, register cleanup.
make_test_repo() {
    local d; d="$(mktemp -d)"
    ( cd "$d" && git init -q && git commit -q --allow-empty -m "init" )
    echo "$d"
}

cleanup_repo() {
    [ -n "${1:-}" ] && [ -d "$1" ] && rm -rf "$1"
}

# Final summary, used by run-all.sh and individual files when run standalone.
print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT))
    echo ""
    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "  ${GREEN}${PASS_COUNT}/${total} passed${NC}"
        return 0
    else
        echo -e "  ${RED}${FAIL_COUNT}/${total} failed${NC}"
        return 1
    fi
}
