#!/usr/bin/env bash
# tests/run-all.sh - Run every test-*.sh and report pass/fail per file.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$DIR/.." && pwd)"
export BUNDLE

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

PASSED=0
FAILED=0
FAILING_FILES=()

echo ""
echo -e "${CYAN}claude_preflight test suite${NC}"
echo -e "${CYAN}bundle: ${BUNDLE}${NC}"
echo ""

for t in "$DIR"/test-*.sh; do
    [ -x "$t" ] || chmod +x "$t"
    name="$(basename "$t" .sh)"
    if bash "$t"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILING_FILES+=("$name")
    fi
done

echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}all ${PASSED} test file(s) passed${NC}"
    exit 0
else
    echo -e "${RED}${FAILED} test file(s) failed:${NC} ${FAILING_FILES[*]}"
    exit 1
fi
