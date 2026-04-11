#!/usr/bin/env bash
# tests/test-fresh.sh
source "$(dirname "$0")/lib.sh"

BUNDLE="${BUNDLE:-/home/claude_preflight}"
echo "fresh.sh"

REPO="$(make_test_repo)"
trap "cleanup_repo $REPO" EXIT
cd "$REPO"
mkdir -p scripts
cp "$BUNDLE/scripts/snapshot.sh" "$BUNDLE/scripts/fresh.sh" scripts/
chmod +x scripts/snapshot.sh scripts/fresh.sh

it "runs without unset-variable crash under set -u"
set +e
echo "n" | bash -u ./scripts/fresh.sh --no-reinstall >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 1 ] && _record pass "" || _record fail "fresh.sh crashed (rc=$RC)"

it "snapshot directory created"
SNAPS=$(ls -1d archive/snapshot-*/ 2>/dev/null | wc -l)
[ "$SNAPS" -ge 1 ] && _record pass "" || _record fail "no snapshot created"

print_summary
