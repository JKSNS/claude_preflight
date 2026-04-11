#!/usr/bin/env bash
# self-update.sh - Pull latest claude_preflight and reinstall.
# Usage: ./scripts/self-update.sh [--check]
#   --check   Just check for updates, don't install
set -euo pipefail

REPO_URL="https://github.com/JKSNS/claude_preflight.git"
RAW_URL="https://raw.githubusercontent.com/JKSNS/claude_preflight/main"
CACHE_DIR="${TMPDIR:-/tmp}/claude_preflight"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[preflight]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

# Get installed version
INSTALLED_VERSION="unknown"
if [ -f scripts/.preflight_version ]; then
    INSTALLED_VERSION=$(cat scripts/.preflight_version)
fi

# Get remote version
REMOTE_VERSION=$(curl -sfL "$RAW_URL/VERSION" 2>/dev/null || echo "unknown")

log "Installed: v${INSTALLED_VERSION}  Remote: v${REMOTE_VERSION}"

if [ "$INSTALLED_VERSION" = "$REMOTE_VERSION" ]; then
    ok "Already up to date."
    exit 0
fi

if [ "${1:-}" = "--check" ]; then
    warn "Update available: v${INSTALLED_VERSION} → v${REMOTE_VERSION}"
    echo "  Run: ./scripts/self-update.sh"
    exit 0
fi

log "Updating v${INSTALLED_VERSION} → v${REMOTE_VERSION}..."

# Clone or update cache
if [ -d "$CACHE_DIR/.git" ]; then
    cd "$CACHE_DIR" && git pull -q 2>/dev/null && cd - >/dev/null
else
    rm -rf "$CACHE_DIR"
    git clone -q "$REPO_URL" "$CACHE_DIR"
fi

# Re-run installer with --force to overwrite existing files
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"
bash "$CACHE_DIR/install.sh" --force

# Stamp the version
echo "$REMOTE_VERSION" > scripts/.preflight_version
ok "Updated to v${REMOTE_VERSION}"
