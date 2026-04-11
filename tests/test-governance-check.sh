#!/usr/bin/env bash
# tests/test-governance-check.sh
source "$(dirname "$0")/lib.sh"

BUNDLE="${BUNDLE:-/home/claude_preflight}"
echo "governance-check.sh"

REPO="$(make_test_repo)"
trap "cleanup_repo $REPO" EXIT
cd "$REPO"

it "tier 0 init+check round-trip without failures"
PREFLIGHT_HOME="$BUNDLE" "$BUNDLE/scripts/governance-init.sh" --tier 0 >/dev/null 2>&1
set +e
"$BUNDLE/scripts/governance-check.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0" "tier 0 should pass governance-check"

it "tier 1 init+check round-trip without failures"
rm -rf governance memory .agent policy audits docs STATUS.md PLAN.md README.md
PREFLIGHT_HOME="$BUNDLE" "$BUNDLE/scripts/governance-init.sh" --tier 1 >/dev/null 2>&1
set +e
"$BUNDLE/scripts/governance-check.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0" "tier 1 should pass (warnings ok)"

it "--format json emits parseable JSON with non-empty findings"
JSON="$("$BUNDLE/scripts/governance-check.sh" --format json 2>&1)"
assert_contains "$JSON" '"pass":'
COUNT="$(echo "$JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))')"
[ "$COUNT" -gt 0 ] && _record pass "" || _record fail "findings array empty (count=$COUNT)"

it "duplicate captures are flagged as defect"
"$BUNDLE/scripts/memory-promote.sh" capture "always test before merge" >/dev/null
"$BUNDLE/scripts/memory-promote.sh" capture "Always test before merge" >/dev/null
set +e
OUT="$("$BUNDLE/scripts/governance-check.sh" 2>&1)"
RC=$?
set -e
assert_contains "$OUT" "duplicate"
assert_exit "$RC" "1" "duplicate captures must fail the check"

print_summary
