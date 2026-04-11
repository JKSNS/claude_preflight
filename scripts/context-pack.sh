#!/usr/bin/env bash
# context-pack.sh - Generate .agent/context-packs/current.md from doctrine + memory + status.
#
# AGENTS.md tells agents to read 8 files at session start. That doesn't scale
# and isn't enforceable. This script aggregates the high-signal lines from
# each canonical source into one file the agent loads via a single Read.
#
# Sources, in priority order:
#   1. governance/CONSTITUTION.md     — core invariants, override clauses
#   2. governance/AGENTS.md           — required + forbidden behavior
#   3. governance/INTERACTION_STANDARDS.md — communication preferences
#   4. governance/ANTI_PATTERNS.md    — known failure modes
#   5. memory/index.md                — pointers to active memories
#   6. memory/active/*.md             — bodies of active memories
#   7. STATUS.md                      — current truth (most recent block)
#   8. governance/PROMOTION_QUEUE.md  — open candidates (count only)
#   9. audits/findings/open.md        — open audit findings (count only)
#  10. governance/policy-map.md       — rule → enforcement summary
#
# Output: .agent/context-packs/current.md
#
# Auto-fires after /govern check and /govern promote. Manually: /govern context-pack.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

QUIET=false
for arg in "$@"; do
    case "$arg" in --quiet) QUIET=true ;; esac
done

OUT_DIR=".agent/context-packs"
OUT="${OUT_DIR}/current.md"
mkdir -p "$OUT_DIR"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { [ "$QUIET" = true ] || echo -e "${CYAN}[context-pack]${NC} $*"; }
ok()  { [ "$QUIET" = true ] || echo -e "  ${GREEN}[OK]${NC} $*"; }

# Read a section of a file with a line cap so the pack stays scannable.
section() {
    local label="$1" path="$2" cap="${3:-40}"
    [ -f "$path" ] || return 0
    echo "## ${label}"
    echo ""
    echo "_source: \`${path}\`_"
    echo ""
    head -n "$cap" "$path" | sed 's/^/    /'
    echo ""
}

count_pattern() {
    local path="$1" pattern="$2" n
    [ -f "$path" ] || { echo 0; return; }
    n=$(grep -cE "$pattern" "$path" 2>/dev/null || true)
    echo "${n:-0}"
}

PROJ="$(basename "$PROJECT_DIR")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
    cat <<EOF
# Context Pack — ${PROJ}

Generated: ${TS}
Source: \`scripts/context-pack.sh\` aggregates doctrine + active memory + status into this single file.
Agents should read THIS file at session start instead of opening 8 files individually.

---

## At a glance

EOF

    # Counts that matter at-a-glance.
    PENDING=$(count_pattern governance/PROMOTION_QUEUE.md '^Status: +candidate[[:space:]]*$')
    OPEN_FINDINGS=$(grep -cE '^## [0-9]{8}T' audits/findings/open.md 2>/dev/null || true); OPEN_FINDINGS=${OPEN_FINDINGS:-0}
    INBOX=$(grep -cE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}' memory/inbox.md 2>/dev/null || true); INBOX=${INBOX:-0}
    TIER="$(awk -F': *' '/^tier:/ {print $2; exit}' .agent/project-tier.yaml 2>/dev/null | tr -d '"' | tr -d ' ')"
    [ -z "$TIER" ] && TIER="?"

    cat <<EOF
- Tier:                  ${TIER}
- Open candidates:       ${PENDING}  (in governance/PROMOTION_QUEUE.md)
- Open audit findings:   ${OPEN_FINDINGS}
- Inbox entries pending: ${INBOX}

---

EOF

    section "Constitution (head)"           governance/CONSTITUTION.md           60
    section "Agent contract (head)"          governance/AGENTS.md                 60
    section "Interaction standards (head)"   governance/INTERACTION_STANDARDS.md  40
    section "Anti-patterns (head)"           governance/ANTI_PATTERNS.md          50

    # Active memories: list + bodies of small ones.
    if [ -d memory/active ] && [ -n "$(ls -A memory/active 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
        echo "## Active memories"
        echo ""
        for m in memory/active/*.md; do
            [ -f "$m" ] || continue
            echo "### $(basename "$m")"
            head -20 "$m" | sed 's/^/    /'
            echo ""
        done
    fi

    section "Memory index"                   memory/index.md                      30
    section "Most recent status"             STATUS.md                            50
    section "Policy map (rule → enforcement)" governance/policy-map.md            60
} > "$OUT"

# Trim if the pack got larger than ~30KB — agents shouldn't load megabytes.
SIZE=$(stat -c %s "$OUT" 2>/dev/null || wc -c < "$OUT")
if [ "$SIZE" -gt 30000 ]; then
    head -c 30000 "$OUT" > "$OUT.tmp"
    echo "" >> "$OUT.tmp"
    echo "_[truncated at 30KB; raise scripts/context-pack.sh's section caps if you need more]_" >> "$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
fi

log "wrote $OUT ($(wc -c < "$OUT") bytes, $(wc -l < "$OUT") lines)"
ok "agents should read this file at session start"

echo "$OUT"
