#!/usr/bin/env bash
# self-update.sh - Pull latest claude_preflight and reinstall.
#
# Behavior change in 0.7.0: per-file diff check before overwrite. If a file
# you have customized differs from the upstream version, we ASK before
# clobbering it (prior behavior was silent --force overwrite).
#
# Usage:
#   ./scripts/self-update.sh             # interactive: prompt on each diff
#   ./scripts/self-update.sh --check     # just check for updates, don't install
#   ./scripts/self-update.sh --yes       # accept all overwrites (old --force behavior)
#   ./scripts/self-update.sh --diff-only # show diffs and exit (no writes)
set -euo pipefail

REPO_URL="https://github.com/JKSNS/claude_preflight.git"
RAW_URL="https://raw.githubusercontent.com/JKSNS/claude_preflight/main"
CACHE_DIR="${TMPDIR:-/tmp}/claude_preflight"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[preflight]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

MODE="interactive"
for arg in "$@"; do
    case "$arg" in
        --check)     MODE="check" ;;
        --yes|-y)    MODE="yes" ;;
        --diff-only) MODE="diff-only" ;;
    esac
done

# Get installed and remote versions.
INSTALLED_VERSION="unknown"
[ -f scripts/.preflight_version ] && INSTALLED_VERSION=$(cat scripts/.preflight_version)
REMOTE_VERSION=$(curl -sfL "$RAW_URL/VERSION" 2>/dev/null || echo "unknown")

log "Installed: v${INSTALLED_VERSION}  Remote: v${REMOTE_VERSION}"

if [ "$INSTALLED_VERSION" = "$REMOTE_VERSION" ] && [ "$MODE" = "check" ]; then
    ok "Already up to date."
    exit 0
fi

if [ "$MODE" = "check" ]; then
    warn "Update available: v${INSTALLED_VERSION} → v${REMOTE_VERSION}"
    echo "  Run: ./scripts/self-update.sh"
    exit 0
fi

# Refresh the bundle cache.
if [ -d "$CACHE_DIR/.git" ]; then
    log "Pulling latest into $CACHE_DIR ..."
    ( cd "$CACHE_DIR" && git pull -q )
else
    log "Cloning into $CACHE_DIR ..."
    rm -rf "$CACHE_DIR"
    git clone -q "$REPO_URL" "$CACHE_DIR"
fi

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

# Snapshot before any overwrite so a regretted update has a one-line rollback.
if [ -x scripts/snapshot.sh ]; then
    ./scripts/snapshot.sh create --trigger self-update >/dev/null
    log "snapshot captured before update — rollback if needed via ./scripts/snapshot.sh restore <dir>"
fi

# Per-file diff and prompt for any locally-customized files.
log "Checking for local customizations under scripts/ and hooks/..."
DIVERGED=()
for src in "$CACHE_DIR/scripts/"*.sh "$CACHE_DIR/hooks/"*.sh "$CACHE_DIR/templates/"*; do
    [ -f "$src" ] || continue
    rel="${src#$CACHE_DIR/}"
    local_path="$rel"
    # The hooks live globally, not in this project. Skip hooks/ for the
    # local-divergence check; install.sh handles hooks via $HOME/.claude/hooks/.
    case "$rel" in hooks/*) continue ;; esac
    if [ -f "$local_path" ] && ! cmp -s "$src" "$local_path"; then
        DIVERGED+=("$rel")
    fi
done

if [ "${#DIVERGED[@]}" -eq 0 ]; then
    log "No local customizations detected; safe to update."
elif [ "$MODE" = "diff-only" ]; then
    warn "Diverged files (showing diff against upstream):"
    for f in "${DIVERGED[@]}"; do
        echo ""
        echo "── $f ──"
        diff -u "$f" "$CACHE_DIR/$f" | head -40
    done
    exit 0
else
    warn "${#DIVERGED[@]} file(s) diverge from upstream:"
    for f in "${DIVERGED[@]}"; do echo "    $f"; done
    echo ""
    if [ "$MODE" != "yes" ]; then
        for f in "${DIVERGED[@]}"; do
            echo ""
            echo "── $f ──"
            diff -u "$f" "$CACHE_DIR/$f" | head -20
            read -r -p "  Overwrite $f with upstream? (y/N) " ans
            case "$ans" in
                y|Y|yes|YES) cp "$CACHE_DIR/$f" "$f" && ok "overwrote $f" ;;
                *) warn "kept local $f"; touch "/tmp/.preflight-self-update-skip-$$"; KEEP_LOCAL=1 ;;
            esac
        done
    fi
fi

# Run installer in non-force mode so it does not re-clobber files we kept.
# Anything we already overwrote above is in the right place; install.sh
# will skip-with-OK on those (its non-force path).
log "Running install.sh (no --force; user-kept files preserved) ..."
bash "$CACHE_DIR/install.sh"

echo "$REMOTE_VERSION" > scripts/.preflight_version
ok "Updated to v${REMOTE_VERSION}"
