#!/usr/bin/env bash
# pre-bash-firewall.sh - Block truly destructive shell commands.
# Installed by claude_preflight. Runs as a PreToolUse hook on Bash calls.
#
# Set PREFLIGHT_UNSAFE=1 in your environment to bypass for CTF/security research.

INPUT=$(cat)

# Bypass mode for CTF challenges and security research
if [ "${PREFLIGHT_UNSAFE:-0}" = "1" ]; then
    exit 0
fi

# Extract command field — prefer jq, fall back to python3
if command -v jq >/dev/null 2>&1; then
    CMD=$(echo "$INPUT" | jq -r '.command // empty' 2>/dev/null || echo "")
else
    CMD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command',''))" 2>/dev/null || echo "")
fi

[ -z "$CMD" ] && exit 0

# Hard blocks — catastrophic, no legitimate use case in a dev session
BLOCKED_PATTERNS=(
  "rm\s+-rf\s+/(\s|$)"
  "rm\s+-rf\s+~(\s|$)"
  "rm\s+-rf\s+\.(\s|$)"
  "mkfs\."
  "dd\s+if=.*\s+of=/dev/[sh]d"
  ">\s*/dev/sd"
  "DROP\s+DATABASE\b"
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$CMD" | grep -qE "$pattern"; then
        echo "BLOCKED: Dangerous command matched pattern '$pattern'" >&2
        exit 2
    fi
done

exit 0
