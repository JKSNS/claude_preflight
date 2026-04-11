#!/usr/bin/env bash
# tests/test-policy-gate.sh
source "$(dirname "$0")/lib.sh"

BUNDLE="${BUNDLE:-/home/claude_preflight}"
echo "pre-tool-policy-gate.sh"

# Skip if opa unavailable.
if ! command -v opa >/dev/null 2>&1; then
    echo "    (skipped — opa not on PATH)"
    print_summary
    exit 0
fi

REPO="$(make_test_repo)"
trap "cleanup_repo $REPO" EXIT
cd "$REPO"
PREFLIGHT_HOME="$BUNDLE" "$BUNDLE/scripts/governance-init.sh" --tier 1 >/dev/null 2>&1

it "rm -rf / is hard-blocked with exit 2"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    | "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "2"

it "deny is not bypassable by PREFLIGHT_GATE_APPROVE=1"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    | PREFLIGHT_GATE_APPROVE=1 "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "2" "deny should not bypass even with approval"

it "pip install (require_approval) hard-blocks WITHOUT approval"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"pip install foo"}}' \
    | "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "2" "approval-required should block by default"

it "pip install bypasses cleanly WITH PREFLIGHT_GATE_APPROVE=1"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"pip install foo"}}' \
    | PREFLIGHT_GATE_APPROVE=1 "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0" "explicit approval should bypass"

it "ls allows with exit 0"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    | "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0"

it "ungated tool (TaskCreate) passes through"
set +e
echo '{"tool_name":"TaskCreate","tool_input":{"subject":"x"}}' \
    | "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0"

# Critical regression: when OPA is MISSING, the gate must NOT lock out the
# agent. It runs in advisory mode (warn + allow) so the agent can still
# install OPA. A previous revision fail-closed here and bricked the session.
it "missing OPA degrades to advisory mode (exit 0), does not lock out"
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    | PATH=/usr/bin:/bin "$BUNDLE/hooks/pre-tool-policy-gate.sh" >/dev/null 2>&1
RC=$?
set -e
assert_exit "$RC" "0" "missing OPA must not block (advisory mode)"

print_summary
