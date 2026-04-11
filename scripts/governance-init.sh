#!/usr/bin/env bash
# governance-init.sh - Scaffold the governance layer into a project.
#
# Copies templates from the claude_preflight bundle into the current project:
#   docs:     governance/CONSTITUTION.md, GOVERNANCE.md, AGENTS.md, ...
#   memory:   memory/inbox.md, memory/index.md, memory/{active,promoted,...}/
#   policy:   policy/*.rego, policy/tests/*_test.rego
#   config:   .agent/{project-tier,review-gates,audit-agents}.yaml
#
# Idempotent. Skips files that already exist unless --force is passed.
#
# Usage:
#   ./scripts/governance-init.sh             # install missing files
#   ./scripts/governance-init.sh --force     # overwrite existing files
#   ./scripts/governance-init.sh --tier 2    # set the tier in .agent/project-tier.yaml
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

FORCE=false
TIER=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --tier) shift; TIER="${1:-}" ;;
        --tier=*) TIER="${arg#--tier=}" ;;
    esac
done

# Resolve the bundle directory. Prefer a sibling install of claude_preflight,
# then PREFLIGHT_HOME, then a checkout under /tmp.
locate_bundle() {
    local candidates=(
        "${PREFLIGHT_HOME:-}"
        "${HOME}/.claude/preflight-bundle"
        "/tmp/claude_preflight"
        "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.."
    )
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -d "$c/governance/templates" ] && [ -d "$c/governance/policy" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

BUNDLE="$(locate_bundle || true)"
if [ -z "$BUNDLE" ]; then
    echo "governance-init: cannot locate the claude_preflight bundle." >&2
    echo "  Set PREFLIGHT_HOME, or clone https://github.com/JKSNS/claude_preflight to /tmp/claude_preflight" >&2
    exit 2
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $*"; }
log()  { echo -e "${CYAN}[govern]${NC} $*"; }

install_file() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then return 0; fi
    local dir; dir="$(dirname "$dst")"
    mkdir -p "$dir"
    if [ -e "$dst" ] && [ "$FORCE" = false ]; then
        skip "$dst (exists; --force to overwrite)"
        return 0
    fi
    if cp -R "$src" "$dst" 2>/dev/null; then
        ok "$dst"
    else
        echo "  install failed: $dst" >&2
    fi
}

log "Installing governance into $PROJECT_DIR  (tier ${TIER:-1})"

# Snapshot before --force overwrites any local edits to canonical docs.
if [ "$FORCE" = true ] && [ -x scripts/snapshot.sh ]; then
    ./scripts/snapshot.sh create --trigger governance-init-force >/dev/null
    echo "  [snapshot] state captured before --force overwrite"
fi

# Tier 0 is the minimum-viable scaffold: 4 files. Tier 1+ adds the rest.
# This avoids dumping 30 placeholder files into projects that just want
# basic doctrine.
TIER_FOR_INSTALL="${TIER:-1}"

# Always install (every tier).
install_file "$BUNDLE/governance/templates/CONSTITUTION.md"           "governance/CONSTITUTION.md"
install_file "$BUNDLE/governance/templates/AGENTS.md"                 "governance/AGENTS.md"

# Tier 1+: full doctrine + governance lifecycle.
if [ "$TIER_FOR_INSTALL" != "0" ]; then
    install_file "$BUNDLE/governance/templates/GOVERNANCE.md"             "governance/GOVERNANCE.md"
    install_file "$BUNDLE/governance/templates/INTERACTION_STANDARDS.md"  "governance/INTERACTION_STANDARDS.md"
    install_file "$BUNDLE/governance/templates/ANTI_PATTERNS.md"          "governance/ANTI_PATTERNS.md"
    install_file "$BUNDLE/governance/templates/PROJECT_MEMORY_CONTRACT.md" "governance/PROJECT_MEMORY_CONTRACT.md"
    install_file "$BUNDLE/governance/templates/PROMOTION_QUEUE.md"        "governance/PROMOTION_QUEUE.md"
    install_file "$BUNDLE/governance/templates/policy-map.md"             "governance/policy-map.md"
    install_file "$BUNDLE/governance/templates/idea_log.md"               "governance/idea_log.md"
fi

# Memory tree.
install_file "$BUNDLE/governance/templates/memory/inbox.md"   "memory/inbox.md"
install_file "$BUNDLE/governance/templates/memory/index.md"   "memory/index.md"
for sub in active promoted stale rejected; do
    mkdir -p "memory/$sub"
    [ -e "memory/$sub/.gitkeep" ] || touch "memory/$sub/.gitkeep"
done

# Amendments.
mkdir -p "governance/amendments"
[ -e "governance/amendments/.gitkeep" ] || touch "governance/amendments/.gitkeep"

# .agent config — tier-aware. project-tier.yaml is always installed; the
# review-gates / audit-agents files only matter once you have policies and
# audits, so they are tier 1+.
install_file "$BUNDLE/governance/templates/.agent/project-tier.yaml"  ".agent/project-tier.yaml"
if [ "$TIER_FOR_INSTALL" != "0" ]; then
    install_file "$BUNDLE/governance/templates/.agent/review-gates.yaml"  ".agent/review-gates.yaml"
    install_file "$BUNDLE/governance/templates/.agent/audit-agents.yaml"  ".agent/audit-agents.yaml"
fi

# Policies + tests + runtime scripts: tier 1+ only. Tier 0 is "doctrine only".
if [ "$TIER_FOR_INSTALL" != "0" ]; then
    # Policies + tests.
    mkdir -p policy/tests
    for src in "$BUNDLE/governance/policy/"*.rego; do
        [ -f "$src" ] || continue
        install_file "$src" "policy/$(basename "$src")"
    done
    for src in "$BUNDLE/governance/policy/tests/"*.rego; do
        [ -f "$src" ] || continue
        install_file "$src" "policy/tests/$(basename "$src")"
    done

    # Runtime scripts. governance-init must be self-sufficient: users who
    # scaffold governance manually (without going through install.sh) still
    # need agent-gate, governance-check, memory-promote, etc. to work.
    mkdir -p scripts
    for s in agent-gate.sh governance-check.sh memory-promote.sh adversarial-audit.sh \
             cross-project-ingest.sh session-synthesize.sh govern-onboard.sh \
             context-pack.sh snapshot.sh project-ingest.sh idea-log.sh council.sh; do
        install_file "$BUNDLE/scripts/$s" "scripts/$s"
    done

    # Onboarding question bank (read by govern-onboard.sh).
    mkdir -p governance/onboarding
    install_file "$BUNDLE/governance/onboarding/questions.md" "governance/onboarding/questions.md"
fi

# Audit findings tree (tier 1+).
if [ "$TIER_FOR_INSTALL" != "0" ]; then
    mkdir -p audits/findings audits/playbooks audits/reports
    for state in open accepted rejected false-positives; do
        f="audits/findings/${state}.md"
        [ -e "$f" ] || printf "# %s findings\n\n> Append findings as they arrive from scripts/adversarial-audit.sh.\n" "$state" > "$f"
    done

    # Adversarial audit playbooks (referenced from .agent/audit-agents.yaml).
    for pb in devil-advocate.md security-auditor.md regression-hunter.md; do
        install_file "$BUNDLE/governance/templates/audits/playbooks/$pb" "audits/playbooks/$pb"
    done

    # Council playbooks (used by scripts/council.sh for high-stakes decision audits).
    mkdir -p audits/playbooks/council governance/councils
    for cpb in contrarian.md first-principles.md expansionist.md outsider.md executor.md peer-review.md chairman.md; do
        install_file "$BUNDLE/governance/templates/audits/playbooks/council/$cpb" "audits/playbooks/council/$cpb"
    done
fi

# Stamp the tier (if --tier was passed) BEFORE scaffolding tier-gated docs,
# so the tier check below sees the requested value.
if [ -n "$TIER" ] && [ -f .agent/project-tier.yaml ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$TIER" <<'PY'
import sys, re, pathlib
tier = sys.argv[1]
p = pathlib.Path(".agent/project-tier.yaml")
text = p.read_text()
new = re.sub(r"^tier:.*$", f"tier: {tier}", text, count=1, flags=re.M)
p.write_text(new)
print(f"  set tier: {tier}")
PY
    fi
fi

# Standard project docs. Only scaffold what's missing; never overwrite. Tier
# gates which docs are scaffolded: tier 0/1 get the basics; tier 2+ also gets
# RISKS and THREAT_MODEL.
mkdir -p docs
TIER_INSTALLED="${TIER:-1}"
if [ -f .agent/project-tier.yaml ]; then
    TIER_INSTALLED="$(awk -F': *' '/^tier:/ {print $2; exit}' .agent/project-tier.yaml | tr -d '"' | tr -d ' ')"
    [ -z "$TIER_INSTALLED" ] && TIER_INSTALLED="1"
fi

scaffold_doc() {
    local src="$1" dst="$2"
    if [ -e "$dst" ]; then
        skip "$dst (exists)"
        return
    fi
    if [ -f "$src" ]; then
        cp "$src" "$dst" && ok "$dst"
    fi
}

scaffold_doc "$BUNDLE/governance/templates/docs/STATUS.md"        "STATUS.md"
scaffold_doc "$BUNDLE/governance/templates/docs/PLAN.md"          "PLAN.md"
scaffold_doc "$BUNDLE/governance/templates/docs/ARCHITECTURE.md"  "docs/ARCHITECTURE.md"

if [ "$TIER_INSTALLED" -ge 2 ] 2>/dev/null; then
    scaffold_doc "$BUNDLE/governance/templates/docs/RISKS.md"        "docs/RISKS.md"
    scaffold_doc "$BUNDLE/governance/templates/docs/THREAT_MODEL.md" "docs/THREAT_MODEL.md"
fi

# README.md gets a minimal stub only if there is no README at all (do NOT
# overwrite a real README — the project owner controls that file).
if [ ! -f README.md ] && [ ! -f README.rst ] && [ ! -f README ]; then
    PROJ="$(basename "$PROJECT_DIR")"
    cat > README.md <<EOF
# $PROJ

> Replace this stub with a real description.

## Governance

This project follows the agentic governance layer. See:

- \`governance/CONSTITUTION.md\` — project doctrine
- \`governance/AGENTS.md\` — agent behavior contract
- \`governance/policy-map.md\` — rule → enforcement table
- \`docs/ARCHITECTURE.md\` — how this system is built
- \`STATUS.md\` — what is true now
- \`PLAN.md\` — what's planned next

Run \`./scripts/governance-check.sh\` to audit governance state.
EOF
    ok "README.md (stub)"
fi

# Make .gitignore aware of audit logs.
if [ -f .gitignore ]; then
    for entry in "audits/reports/" "audits/findings/.lock"; do
        grep -qF "$entry" .gitignore 2>/dev/null || echo "$entry" >> .gitignore
    done
fi

log "Governance scaffolded."

# Auto-run the project ingest. This is what stops the agent from drafting
# CONSTITUTION.md from session context. The ingest report at
# .agent/project-ingest.md is the agent's required reading before drafting
# any doctrine in this project.
if [ -x scripts/project-ingest.sh ]; then
    log "Building project ingest (every .md, knowledge graph, memory) ..."
    ./scripts/project-ingest.sh --quiet >/dev/null 2>&1
    if [ -f .agent/project-ingest.md ]; then
        ok ".agent/project-ingest.md ready ($(wc -l < .agent/project-ingest.md) lines)"
        ok "AGENTS: read this BEFORE drafting any governance doc"
    fi
fi

echo ""
echo "  Next:"
echo "    Read   .agent/project-ingest.md          (REQUIRED before drafting CONSTITUTION/AGENTS/etc.)"
echo "    Run    ./scripts/governance-check.sh     (audit governance state)"
echo "    Run    ./scripts/memory-promote.sh       (walk the promotion queue)"
echo "    Run    opa test policy/                  (policy tests; requires opa)"
echo ""
