#!/usr/bin/env bash
# uninstall.sh - Remove claude_preflight from a project.
#
# Usage: /tmp/claude_preflight/uninstall.sh
#   or:  cd your-project && path/to/uninstall.sh
#
# Removes: cron job, startup script, .bashrc entry, graphify hooks.
# Does NOT remove: scripts/, .graphifyignore, graphify-out/ (your data).

set -euo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

echo "Uninstalling claude_preflight from: $PROJECT_DIR"
echo ""

# Remove cron entry
if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "$PROJECT_DIR/scripts/graphify-sync.sh" | \
        grep -v "claude_preflight sync: $PROJECT_NAME" | crontab -
    echo "  Removed cron job"
fi

# Kill sync daemon
if [ -f "$PROJECT_DIR/graphify-out/.sync.pid" ]; then
    kill "$(cat "$PROJECT_DIR/graphify-out/.sync.pid")" 2>/dev/null || true
    rm -f "$PROJECT_DIR/graphify-out/.sync.pid"
    echo "  Stopped sync daemon"
fi

# Remove startup script
STARTUP="$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"
[ -f "$STARTUP" ] && rm -f "$STARTUP" && echo "  Removed startup script"

# Remove .bashrc entry
MARKER="# claude_preflight: $PROJECT_NAME"
if grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    grep -vF "$MARKER" "$HOME/.bashrc" | grep -vF "$STARTUP" > "$HOME/.bashrc.tmp"
    mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
    echo "  Removed .bashrc entry"
fi

# Remove graphify hooks (optional)
echo ""
echo "  Graphify hooks and scripts/ are left in place."
echo "  To fully remove graphify:"
echo "    graphify claude uninstall"
echo "    graphify hook uninstall"
echo "    rm -rf graphify-out/ scripts/graphify-*.sh scripts/preflight.sh"
echo ""
echo "Done."
