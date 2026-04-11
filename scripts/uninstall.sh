#!/usr/bin/env bash
# uninstall.sh - Project-aware removal of claude_preflight integration.
#
# Less destructive than scripts/fresh.sh: only removes the per-project
# integration (cron entry, startup script, .bashrc lines, sync daemon).
# Leaves graphify-out, governance/, policy/, scripts/ in place — those are
# project artifacts the user may want to keep.
#
# Usage:
#   ./scripts/uninstall.sh           # interactive, default-N each step
#   ./scripts/uninstall.sh --yes     # accept all
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

YES=false
for arg in "$@"; do
    case "$arg" in --yes|-y) YES=true ;; esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${CYAN}[uninstall]${NC} $*"; }
ok()  { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; }

ask() {
    [ "$YES" = true ] && return 0
    read -r -p "  $1 (y/N) " ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

log "Uninstalling per-project integration for $PROJECT_NAME"
log "  (graphify-out, governance/, policy/, scripts/ are kept — use scripts/fresh.sh for a full purge)"
echo ""

# Stop the sync daemon (project-scoped).
if [ -f graphify-out/.sync.pid ]; then
    PID="$(cat graphify-out/.sync.pid 2>/dev/null)"
    if ps -p "$PID" >/dev/null 2>&1; then
        if ask "Stop the sync daemon (PID $PID)?"; then
            kill "$PID" 2>/dev/null && rm -f graphify-out/.sync.pid && ok "stopped sync daemon"
        fi
    fi
fi

# Remove this project's cron entry.
if command -v crontab >/dev/null 2>&1; then
    if crontab -l 2>/dev/null | grep -qE "(claude_preflight: $PROJECT_NAME|$PROJECT_DIR/scripts/graphify-sync)"; then
        if ask "Remove this project's cron entries?"; then
            crontab -l 2>/dev/null \
                | grep -v "claude_preflight: $PROJECT_NAME" \
                | grep -v "$PROJECT_DIR/scripts/graphify-sync.sh" \
                | crontab - && ok "removed cron entries"
        fi
    fi
fi

# Remove the startup script.
STARTUP_SCRIPT="$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"
if [ -f "$STARTUP_SCRIPT" ]; then
    if ask "Remove startup script $STARTUP_SCRIPT?"; then
        rm -f "$STARTUP_SCRIPT" && ok "removed startup script"
    fi
fi

# Remove this project's .bashrc lines.
if grep -qE "(claude_preflight: $PROJECT_NAME|sync-${PROJECT_NAME}\.sh)" "$HOME/.bashrc" 2>/dev/null; then
    if ask "Remove this project's .bashrc lines?"; then
        grep -v "claude_preflight: $PROJECT_NAME" "$HOME/.bashrc" \
            | grep -v "sync-${PROJECT_NAME}.sh" > "$HOME/.bashrc.tmp" \
            && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc" \
            && ok "cleaned .bashrc"
    fi
fi

echo ""
log "uninstall complete. To remove the rest, use scripts/fresh.sh."
