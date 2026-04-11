#!/usr/bin/env bash
# tests/test-staleness.sh
source "$(dirname "$0")/lib.sh"

BUNDLE="${BUNDLE:-/home/claude_preflight}"
echo "staleness-scan.sh"

REPO="$(make_test_repo)"
trap "cleanup_repo $REPO" EXIT
cd "$REPO"

it "does not flag package-lock.json (always-keep)"
mkdir -p src
echo "x" > src/used.py
echo "y" > package-lock.json
echo "from src.used import f" > main.py
git add -A && git commit -q -m x
"$BUNDLE/scripts/staleness-scan.sh" --signals 1 --age 0 >/dev/null 2>&1
if [ -f staleness-report.md ]; then
    grep -q "package-lock.json" staleness-report.md && \
        _record fail "package-lock.json was flagged but should be in always-keep" || \
        _record pass ""
else
    _record fail "no staleness-report.md produced"
fi

it "uses import-pattern matching, not bare substring"
# src/used.py is referenced via 'from src.used import f' in main.py. With
# --signals 2 (the default), the file should NOT make the cut: it has at
# most 1 signal (age), and the import-pattern detector correctly classifies
# it as referenced. With --signals 1 the age signal alone would surface
# every file regardless of references — that's expected and not a bug.
"$BUNDLE/scripts/staleness-scan.sh" --signals 2 --age 0 >/dev/null 2>&1
grep -q "src/used.py" staleness-report.md && \
    _record fail "src/used.py flagged at signals=2 despite being imported" || \
    _record pass ""

it "produces a report file"
assert_file_exists staleness-report.md

print_summary
