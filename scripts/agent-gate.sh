#!/usr/bin/env bash
# agent-gate.sh - Query the OPA policy bundle with a normalized action input.
#
# Stdin or argv: a JSON object describing the proposed action.
#   {
#     "agent":   {"id": "...", "role": "..."},
#     "user":    {"id": "..."},
#     "tool":    {"name": "shell|filesystem|network|secrets|dependencies|git|deployment|review"},
#     "request": { ... tool-specific ... },
#     "context": {"environment": "dev|staging|production", "human_approved": false}
#   }
#
# Stdout: a JSON decision object.
#   { "allow": <bool>, "require_approval": <bool>, "reason": "<str>", "matched": [...] }
#
# Exit code:
#   0  decision rendered (regardless of allow/deny)
#   2  no opa binary available
#   3  malformed input or audit-log path outside project
#   4  policy directory missing
#
# Env:
#   AGENT_GATE_POLICY      Path to the policy directory. Default: auto-detect
#                          (policy/ if present, else governance/policy/).
#   AGENT_GATE_QUERY       Override the query expression. Default: data.agent.decide
#   AGENT_GATE_AUDIT_LOG   Append-only path to log decisions. Default: audits/gate.log
#                          Must resolve to a path inside $PROJECT_DIR.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

# Auto-detect the policy directory: target projects use policy/ (created by
# governance-init); the bundle dev tree itself uses governance/policy/.
if [ -n "${AGENT_GATE_POLICY:-}" ]; then
    POLICY_DIR="$AGENT_GATE_POLICY"
elif [ -d "policy" ]; then
    POLICY_DIR="policy"
elif [ -d "governance/policy" ]; then
    POLICY_DIR="governance/policy"
else
    POLICY_DIR="policy"
fi
QUERY="${AGENT_GATE_QUERY:-data.agent.decide}"
AUDIT_LOG="${AGENT_GATE_AUDIT_LOG:-audits/gate.log}"

EXPLAIN=false
case "${1:-}" in
    --explain) EXPLAIN=true; shift ;;
esac

if ! command -v opa >/dev/null 2>&1; then
    printf '{"allow": false, "require_approval": false, "reason": "opa binary not installed", "matched": []}\n'
    exit 2
fi

if [ ! -d "$POLICY_DIR" ]; then
    printf '{"allow": false, "require_approval": false, "reason": "policy directory %s missing", "matched": []}\n' "$POLICY_DIR" >&2
    exit 4
fi

# Constrain the audit log path to PROJECT_DIR. Reject path-traversal attempts.
LOG_PARENT="$(dirname "$AUDIT_LOG")"
mkdir -p "$LOG_PARENT" 2>/dev/null || true
LOG_RESOLVED="$(cd "$LOG_PARENT" 2>/dev/null && pwd -P)/$(basename "$AUDIT_LOG")"
PROJECT_RESOLVED="$(cd "$PROJECT_DIR" && pwd -P)"
case "$LOG_RESOLVED" in
    "$PROJECT_RESOLVED"/*) ;;
    *)
        printf '{"allow": false, "require_approval": false, "reason": "audit log path resolves outside project: %s", "matched": []}\n' "$LOG_RESOLVED" >&2
        exit 3
        ;;
esac

if [ "$#" -gt 0 ] && [ -f "$1" ]; then
    INPUT_JSON="$(cat "$1")"
else
    INPUT_JSON="$(cat)"
fi

if ! echo "$INPUT_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1; then
    printf '{"allow": false, "require_approval": false, "reason": "input is not valid JSON", "matched": []}\n' >&2
    exit 3
fi

if [ "$EXPLAIN" = "true" ]; then
    # Debugging mode: emit the OPA trace so humans can see which rules
    # fired and in what order. Useful for "why was my safe command blocked?".
    echo "$INPUT_JSON" | opa eval --format=pretty --stdin-input --explain full \
        --data "$POLICY_DIR" "$QUERY" 2>&1
    exit 0
fi

DECISION="$(echo "$INPUT_JSON" | opa eval --format=json --stdin-input --data "$POLICY_DIR" "$QUERY" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    val = r['result'][0]['expressions'][0]['value']
    print(json.dumps(val))
except Exception as e:
    print(json.dumps({'allow': False, 'require_approval': False, 'reason': f'opa eval error: {e}', 'matched': []}))
")"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INPUT_HASH="$(echo "$INPUT_JSON" | sha256sum | awk '{print $1}')"
printf '%s\t%s\t%s\n' "$TS" "$INPUT_HASH" "$DECISION" >> "$LOG_RESOLVED"

echo "$DECISION"
