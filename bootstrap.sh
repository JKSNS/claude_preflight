#!/usr/bin/env bash
# bootstrap.sh - One-shot install + governance scaffold + project ingest.
#
# For agents: this is the single command to run when you've just been handed
# the bundle and need to integrate it into a project. It chains install →
# governance-init → project-ingest, so by the end you have:
#   - all preflight scripts + hooks installed (./install.sh)
#   - OPA installed if missing (./install.sh)
#   - governance scaffold at the requested tier
#   - .agent/project-ingest.md ready for you to read
#
# Then it prints a pointer to AGENT_HANDOFF.md so you know what to do next.
#
# Usage (from inside the target project):
#   curl -fsSL https://raw.githubusercontent.com/JKSNS/claude_preflight/main/bootstrap.sh | bash
#
# Or after cloning:
#   /tmp/claude_preflight/bootstrap.sh [--tier 0|1|2|3]
set -uo pipefail

TIER=1
for arg in "$@"; do
    case "$arg" in
        --tier) shift; TIER="${1:-1}" ;;
        --tier=*) TIER="${arg#--tier=}" ;;
    esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${CYAN}[bootstrap]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

log "bootstrapping claude_preflight into $PROJECT_DIR (tier $TIER)"
echo ""

log "step 1/3: install.sh"
"$SCRIPT_DIR/install.sh" || warn "install.sh exited non-zero — see output above"
echo ""

log "step 2/3: governance-init --tier $TIER"
if [ -x scripts/governance-init.sh ]; then
    PREFLIGHT_HOME="$SCRIPT_DIR" ./scripts/governance-init.sh --tier "$TIER" || \
        warn "governance-init exited non-zero — see output above"
else
    warn "scripts/governance-init.sh missing — install.sh did not place it"
fi
echo ""

log "step 3/3: project-ingest"
if [ -x scripts/project-ingest.sh ]; then
    ./scripts/project-ingest.sh
else
    warn "scripts/project-ingest.sh missing — re-run install.sh"
fi
echo ""

log "bootstrap complete"
echo ""
ok "Project tier:   $TIER"
ok "Project ingest: .agent/project-ingest.md"
ok "Governance:     governance/CONSTITUTION.md, AGENTS.md, policy/, etc."
echo ""
log "AGENTS: read these in order before taking any action:"
echo "  1. $SCRIPT_DIR/AGENT_HANDOFF.md      (the bundle's session-start contract)"
echo "  2. .agent/project-ingest.md          (this project's full context index)"
echo "  3. CLAUDE.md if present              (this project's existing agent doctrine)"
echo "  4. governance/CONSTITUTION.md        (this project's formal doctrine)"
echo ""
log "then write back to the user with your synthesis (see AGENT_HANDOFF.md step 5)"
