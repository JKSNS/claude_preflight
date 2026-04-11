#!/usr/bin/env bash
# protect-critical-files.sh - Prevent writes to sensitive files.
# Installed by claude_preflight. Runs as a PreToolUse hook on Edit/Write calls.
set -euo pipefail

PROTECTED_PATTERNS=(
  ".env"
  "credentials"
  "api_keys"
  "secrets/"
  ".pem"
  ".key"
)

INPUT=$(cat)

# Extract file_path — prefer jq, fall back to python3
if command -v jq >/dev/null 2>&1; then
    FILE=$(echo "$INPUT" | jq -r '.file_path // empty')
else
    FILE=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('file_path',''))" 2>/dev/null || echo "")
fi

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$FILE" == *"$pattern"* ]]; then
    echo "BLOCKED: Write to protected file: $FILE" >&2
    exit 2
  fi
done
exit 0
