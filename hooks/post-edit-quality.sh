#!/usr/bin/env bash
# post-edit-quality.sh - Auto-format the edited file IF the project adopts
# the formatter. Runs as a Claude Code PostToolUse hook on Edit/Write calls.
#
# Behavior change in 0.7.0:
#   - Only runs ruff when the project actually adopts ruff
#     ([tool.ruff] in pyproject.toml, or .ruff.toml / ruff.toml present).
#   - Only runs prettier when the project actually adopts prettier
#     (.prettierrc / .prettierrc.* / prettier in package.json).
#   - Targets ONLY the file that was just edited, not the whole project.
#   - No-ops when the file's extension is not handled by the available
#     formatters.
set -uo pipefail

# Drain stdin and try to extract the edited file path from the payload.
PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

FILE="$(echo "$PAYLOAD" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = p.get("tool_input", {}) or {}
print(ti.get("file_path", ti.get("notebook_path", "")))
' 2>/dev/null)"

[ -z "$FILE" ] && exit 0
[ -e "$FILE" ] || exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Adoption detection.
adopts_ruff() {
    [ -f "$PROJECT_DIR/.ruff.toml" ] && return 0
    [ -f "$PROJECT_DIR/ruff.toml" ] && return 0
    [ -f "$PROJECT_DIR/pyproject.toml" ] && grep -q '^\[tool.ruff' "$PROJECT_DIR/pyproject.toml" 2>/dev/null && return 0
    return 1
}

adopts_prettier() {
    for f in .prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml \
             .prettierrc.js .prettierrc.cjs .prettierrc.mjs prettier.config.js \
             prettier.config.cjs prettier.config.mjs .prettierrc.toml; do
        [ -f "$PROJECT_DIR/$f" ] && return 0
    done
    [ -f "$PROJECT_DIR/package.json" ] && grep -q '"prettier"' "$PROJECT_DIR/package.json" 2>/dev/null && return 0
    return 1
}

EXT="${FILE##*.}"
case "$EXT" in
    py)
        if adopts_ruff && command -v ruff >/dev/null 2>&1; then
            ruff check --fix "$FILE" 2>/dev/null || true
            ruff format "$FILE" 2>/dev/null || true
        fi
        ;;
    js|jsx|ts|tsx|mjs|cjs|json|css|scss|html|md|yaml|yml)
        if adopts_prettier && command -v npx >/dev/null 2>&1; then
            npx --no-install prettier -w "$FILE" 2>/dev/null || true
        fi
        ;;
esac

exit 0
