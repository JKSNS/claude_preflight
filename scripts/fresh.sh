#!/usr/bin/env bash
# fresh.sh - Purge claude_preflight state from the current project, then reinstall.
#
# Per the project memory rule: capture EVERY piece of state to
# archive/fresh-<timestamp>/ BEFORE removing anything. The user can recover
# any of: cron lines, startup script, .bashrc lines, graphify-out tarball.
#
# Per-component prompts (default N for each remove). Use --yes to accept all.
#
# Usage:
#   ./scripts/fresh.sh                # interactive, default-N each step
#   ./scripts/fresh.sh --yes          # accept all
#   ./scripts/fresh.sh --no-reinstall # purge only, do not reinstall
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
STARTUP_SCRIPT="$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"

YES=false
REINSTALL=true
for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=true ;;
        --no-reinstall) REINSTALL=false ;;
    esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[fresh]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "  ${RED}[ERR]${NC} $*"; }

ask() {
    [ "$YES" = true ] && return 0
    local prompt="$1"
    read -r -p "  $prompt (y/N) " ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Snapshot via the unified snapshot script — captures git state, working
# tree, ~/.claude/settings.json, this project's cron + .bashrc + startup
# script, and a manifest. The graphify-out tarball is taken separately below
# because the unified snapshot deliberately excludes regenerable trees.
ARCHIVE=""
if [ -x scripts/snapshot.sh ]; then
    ARCHIVE="$(./scripts/snapshot.sh create --trigger fresh --quiet)"
    log "Snapshot via scripts/snapshot.sh → $ARCHIVE"
else
    ARCHIVE="archive/fresh-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$ARCHIVE"
    log "snapshot.sh not present; using bare $ARCHIVE"
fi

# graphify-out is regenerable but expensive (10s of minutes of Ollama work),
# so we tar it separately for fresh's specific use case.
if [ -d graphify-out ]; then
    tar -czf "$ARCHIVE/graphify-out.tar.gz" graphify-out 2>/dev/null && \
        ok "captured graphify-out ($(du -sh graphify-out | awk '{print $1}')) → $ARCHIVE/graphify-out.tar.gz"
fi

# .graphifyignore — outside the unified snapshot's scope.
[ -f .graphifyignore ] && cp .graphifyignore "$ARCHIVE/.graphifyignore" && \
    ok "captured .graphifyignore"

log "Snapshot complete. Now per-component removal."
echo ""

# per-component removal, gated

# Sync daemon
if [ -f graphify-out/.sync.pid ]; then
    PID="$(cat graphify-out/.sync.pid 2>/dev/null)"
    if ps -p "$PID" >/dev/null 2>&1; then
        if ask "Stop sync daemon (PID $PID)?"; then
            kill "$PID" 2>/dev/null && ok "stopped sync daemon"
        fi
    fi
fi

# Cron
if [ -s "$ARCHIVE/crontab.lines" ]; then
    if ask "Remove this project's cron entries?"; then
        crontab -l 2>/dev/null \
            | grep -v "claude_preflight: $PROJECT_NAME" \
            | grep -v "$PROJECT_DIR/scripts/graphify-sync.sh" \
            | crontab - && ok "removed cron entries"
    fi
fi

# Startup script
if [ -f "$STARTUP_SCRIPT" ]; then
    if ask "Remove startup script $STARTUP_SCRIPT?"; then
        rm -f "$STARTUP_SCRIPT" && ok "removed startup script"
    fi
fi

# .bashrc
if [ -s "$ARCHIVE/bashrc.lines" ]; then
    if ask "Remove this project's .bashrc lines?"; then
        grep -v "claude_preflight: $PROJECT_NAME" "$HOME/.bashrc" \
            | grep -v "sync-${PROJECT_NAME}.sh" > "$HOME/.bashrc.tmp" \
            && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc" \
            && ok "cleaned .bashrc"
    fi
fi

# graphify-out
if [ -d graphify-out ]; then
    if ask "Delete graphify-out/ (snapshotted to archive — recoverable)?"; then
        rm -rf graphify-out && ok "removed graphify-out"
    fi
fi

# Installed scripts (the snapshot is in archive)
if ask "Remove installed preflight scripts under scripts/ (snapshot in archive)?"; then
    for s in preflight.sh graphify-rebuild.sh graphify-sync.sh \
             governance-init.sh governance-check.sh memory-promote.sh agent-gate.sh \
             adversarial-audit.sh cross-project-ingest.sh session-synthesize.sh \
             govern-onboard.sh model-profile.sh self-update.sh soft-references.sh \
             staleness-scan.sh uninstall.sh fresh.sh; do
        rm -f "scripts/$s" 2>/dev/null
    done
    ok "removed installed scripts"
fi

# .graphifyignore
if [ -f .graphifyignore ]; then
    if ask "Remove .graphifyignore (snapshot in archive)?"; then
        rm -f .graphifyignore && ok "removed .graphifyignore"
    fi
fi

# Graphify hooks
if command -v graphify >/dev/null 2>&1; then
    if ask "Uninstall graphify Claude hook + git hooks?"; then
        graphify claude uninstall 2>/dev/null
        graphify hook uninstall 2>/dev/null
        ok "removed graphify hooks"
    fi
fi

echo ""
log "Snapshot directory: $ARCHIVE"
log "  One-line rollback (interactive, walks each restore step):"
log "    ./scripts/snapshot.sh restore $ARCHIVE"
log "  Or just the graphify-out tarball:"
log "    tar -xzf $ARCHIVE/graphify-out.tar.gz"

if [ "$REINSTALL" = true ]; then
    if ask "Reinstall now via the bundled install.sh?"; then
        BUNDLE="${PREFLIGHT_HOME:-/tmp/claude_preflight}"
        if [ -x "$BUNDLE/install.sh" ]; then
            "$BUNDLE/install.sh"
        else
            warn "no install.sh at $BUNDLE — set PREFLIGHT_HOME and re-run, or run /preflight install"
        fi
    fi
fi

log "fresh complete."
