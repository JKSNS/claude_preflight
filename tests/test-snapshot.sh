#!/usr/bin/env bash
# tests/test-snapshot.sh
source "$(dirname "$0")/lib.sh"

BUNDLE="${BUNDLE:-/home/claude_preflight}"
echo "snapshot.sh"

REPO="$(make_test_repo)"
trap "cleanup_repo $REPO" EXIT
cd "$REPO"
mkdir -p scripts
cp "$BUNDLE/scripts/snapshot.sh" scripts/
chmod +x scripts/snapshot.sh

it "create returns the snapshot path"
SNAP="$(./scripts/snapshot.sh create --quiet --trigger test 2>&1 | tail -1)"
assert_contains "$SNAP" "archive/snapshot-"

it "snapshot dir exists after create"
assert_file_exists "$SNAP/meta.json"

it "manifest.txt is non-empty"
assert_eq "$([ -s "$SNAP/manifest.txt" ] && echo yes || echo no)" "yes"

it "trigger is captured in meta.json"
META="$(cat "$SNAP/meta.json")"
assert_contains "$META" '"trigger": "test"'

it "back-to-back snapshots produce distinct paths"
SNAP2="$(./scripts/snapshot.sh create --quiet --trigger test2 2>&1 | tail -1)"
SNAP3="$(./scripts/snapshot.sh create --quiet --trigger test3 2>&1 | tail -1)"
[ "$SNAP" != "$SNAP2" ] && [ "$SNAP2" != "$SNAP3" ] && _record pass "" || _record fail "snapshots collided"

it "list shows all three"
LIST="$(./scripts/snapshot.sh list 2>&1)"
assert_contains "$LIST" "test"

it "prune --keep 1 drops older snapshots"
./scripts/snapshot.sh prune --keep 1 --quiet >/dev/null
REMAINING=$(ls -1d archive/snapshot-*/ 2>/dev/null | wc -l)
assert_eq "$REMAINING" "1" "prune did not reduce to 1"

print_summary
