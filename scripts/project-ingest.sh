#!/usr/bin/env bash
# project-ingest.sh - Comprehensive project-knowledge index for governance drafting.
#
# Why this exists: when an agent drafts CONSTITUTION.md / AGENTS.md /
# ANTI_PATTERNS.md / etc. for a pre-existing project, it must NOT draft from
# session context alone. That produces shallow "session notes pretending to
# be a constitution." The constitution must be a synthesis of everything
# the project already is — every doc, every prior memory entry, every
# explicit mandate the user has already written down.
#
# This script walks the project tree and the user's auto-memory for the
# project, builds a structured index at .agent/project-ingest.md, and tells
# the agent to read that file BEFORE drafting any doctrine.
#
# Output: .agent/project-ingest.md — structured table of contents + extracts:
#   - project identity (name, languages, top-level layout)
#   - existing CLAUDE.md / AGENTS.md / GOVERNANCE.md (full content)
#   - docs/*.md inventory with one-line summaries + key extracts
#   - memory inventory from ~/.claude/projects/<slug>/memory/
#   - explicit mandates extracted from CLAUDE.md ("MUST", "NEVER", "P0", etc.)
#   - TODO / OPEN_QUESTIONS / ROADMAP if present
#
# Usage:
#   ./scripts/project-ingest.sh                # write .agent/project-ingest.md
#   ./scripts/project-ingest.sh --quiet
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

QUIET=false
for arg in "$@"; do
    case "$arg" in --quiet) QUIET=true ;; esac
done

OUT=".agent/project-ingest.md"
mkdir -p .agent

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { [ "$QUIET" = true ] || echo -e "${CYAN}[ingest]${NC} $*"; }
ok()  { [ "$QUIET" = true ] || echo -e "  ${GREEN}[OK]${NC} $*"; }

PROJECT_NAME="$(basename "$PROJECT_DIR")"
PROJECT_SLUG="-$(echo "${PROJECT_DIR#/}" | sed 's|/|-|g')"
MEMORY_DIR="${HOME}/.claude/projects/${PROJECT_SLUG}/memory"

log "ingesting $PROJECT_NAME ..."

# Inventory counters for the agent to see at-a-glance.
TOTAL_DOCS=$(find . -type f \( -name "*.md" -o -name "*.rst" \) \
    -not -path './.git/*' -not -path './node_modules/*' \
    -not -path './.venv/*' -not -path './venv/*' \
    -not -path './graphify-out/*' -not -path './archive/*' \
    -not -path './target/*' -not -path './dist/*' -not -path './build/*' \
    2>/dev/null | wc -l)

TOTAL_MEMORY=0
[ -d "$MEMORY_DIR" ] && TOTAL_MEMORY=$(find "$MEMORY_DIR" -name "*.md" 2>/dev/null | wc -l)

TOTAL_CODE=$(find . -type f \( -name "*.py" -o -name "*.rs" -o -name "*.go" \
    -o -name "*.ts" -o -name "*.js" -o -name "*.rb" -o -name "*.java" \
    -o -name "*.c" -o -name "*.cpp" -o -name "*.h" \) \
    -not -path './.git/*' -not -path './node_modules/*' \
    -not -path './.venv/*' -not -path './venv/*' \
    -not -path './target/*' -not -path './dist/*' -not -path './build/*' \
    2>/dev/null | wc -l)

{
    cat <<EOF
# Project ingest — ${PROJECT_NAME}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/project-ingest.sh.

**Agents reading this**: do NOT draft a CONSTITUTION, AGENTS, ANTI_PATTERNS,
or any other governance document from session context alone. Read this
ingest first. Open the source files this index points at. Synthesize from
what already exists. The constitution should be a faithful encoding of
what the project IS, not what's currently top of your context window.

## At a glance

- Project:                 ${PROJECT_NAME}
- Path:                    ${PROJECT_DIR}
- Documentation files:     ${TOTAL_DOCS}
- Code files:              ${TOTAL_CODE}
- Auto-memory entries:     ${TOTAL_MEMORY}  (~/.claude/projects/${PROJECT_SLUG}/memory/)

EOF

    # Project identity from manifests / READMEs.
    echo "## Identity"
    echo ""
    if [ -f README.md ]; then
        echo "### README.md (head)"
        echo ""
        head -40 README.md | sed 's/^/    /'
        echo ""
    fi
    echo "### Detected stack"
    echo ""
    [ -f pyproject.toml ]   && echo "- Python (pyproject.toml)"
    [ -f setup.py ]         && echo "- Python (setup.py)"
    [ -f requirements.txt ] && echo "- Python (requirements.txt)"
    [ -f Cargo.toml ]       && echo "- Rust (Cargo.toml)"
    [ -f go.mod ]           && echo "- Go (go.mod)"
    [ -f package.json ]     && echo "- JS/TS (package.json)"
    [ -f Gemfile ]          && echo "- Ruby (Gemfile)"
    [ -f Dockerfile ]       && echo "- Docker (Dockerfile)"
    [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] && echo "- Docker Compose"
    [ -d .github/workflows ] && echo "- GitHub Actions ($(ls .github/workflows/*.yml 2>/dev/null | wc -l) workflows)"
    echo ""

    # Knowledge graph (graphify) — the structural map of the project.
    # If graphify has built one, it's the single most concentrated source of
    # what the project IS: communities, god nodes, dependency topology. Use it.
    if [ -f graphify-out/GRAPH_REPORT.md ]; then
        echo "## Knowledge graph (graphify GRAPH_REPORT.md — full content)"
        echo ""
        echo "This is the topology graphify has discovered for this project."
        echo "Communities, god nodes, and bridge nodes here are load-bearing"
        echo "facts about the project's architecture."
        echo ""
        echo '```'
        cat graphify-out/GRAPH_REPORT.md
        echo '```'
        echo ""
    fi
    if [ -f graphify-out/graph.json ]; then
        echo "### Graph stats"
        echo ""
        python3 -c "
import json
g = json.load(open('graphify-out/graph.json'))
nodes = g.get('nodes', [])
edges = g.get('links', g.get('edges', []))
print(f'- Nodes: {len(nodes)}')
print(f'- Edges: {len(edges)}')
# Top file types.
import collections
exts = collections.Counter()
for n in nodes:
    p = n.get('file') or n.get('path') or n.get('id', '')
    if '.' in p:
        exts[p.rsplit('.', 1)[-1].lower()] += 1
print('- Top file types: ' + ', '.join(f'{ext}={n}' for ext, n in exts.most_common(8)))
" 2>/dev/null || echo "  (could not parse graph.json)"
        echo ""
    fi
    if [ -f graphify-out/SOFT_REFERENCES.md ]; then
        echo "### Soft references (large dirs excluded from full graphify)"
        echo ""
        echo '```'
        head -80 graphify-out/SOFT_REFERENCES.md
        echo '```'
        echo ""
    fi

    # CLAUDE.md is the single most important file — most projects encode
    # their P0 mandates / golden rules / agent contract there. Pull the
    # whole thing inline so the agent does not skim it.
    if [ -f CLAUDE.md ]; then
        echo "## CLAUDE.md (the project's existing agent contract — full content)"
        echo ""
        echo '```'
        cat CLAUDE.md
        echo '```'
        echo ""
    fi

    # Existing governance, if any.
    for f in AGENTS.md GOVERNANCE.md governance/CONSTITUTION.md governance/AGENTS.md governance/GOVERNANCE.md; do
        if [ -f "$f" ]; then
            echo "## $f (full content)"
            echo ""
            echo '```'
            cat "$f"
            echo '```'
            echo ""
        fi
    done

    # Mandates, P0s, MUSTs, NEVERs, golden rules — extract every line that
    # carries a directive across the project.
    echo "## Explicit mandates / directives across the project"
    echo ""
    echo "Every line containing a strong directive (MUST, NEVER, ALWAYS, P0,"
    echo "Golden Rule, mandate, forbidden, required) across all .md files:"
    echo ""
    echo '```'
    grep -rEn -i '\b(MUST|NEVER|ALWAYS|P0|golden rule|mandate|forbidden|required)\b' \
        --include="*.md" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv \
        --exclude-dir=archive --exclude-dir=graphify-out --exclude-dir=target \
        2>/dev/null | head -150 || echo "  (none found)"
    echo '```'
    echo ""

    # Comprehensive .md inventory — every markdown file in the project
    # tree. Vendored, generated, and bundle-internal trees are excluded.
    # The agent should open and READ each one before drafting doctrine,
    # not just rely on this index.
    echo "## Every .md file in the project (read all of these)"
    echo ""
    find . -type f -name "*.md" \
        -not -path './.git/*' -not -path './node_modules/*' \
        -not -path './.venv/*' -not -path './venv/*' \
        -not -path './graphify-out/*' -not -path './archive/*' \
        -not -path './target/*' -not -path './dist/*' -not -path './build/*' \
        -not -path './.next/*' -not -path './.agent/*' \
        2>/dev/null | sort | while IFS= read -r f; do
            line1=$(head -1 "$f" 2>/dev/null | sed 's/^# *//' | head -c 100)
            size=$(wc -l < "$f" 2>/dev/null || echo 0)
            printf -- "- \`%s\` (%s lines) — %s\n" "${f#./}" "$size" "$line1"
    done
    echo ""

    # Memory inventory — the user's curated knowledge for THIS project.
    if [ -d "$MEMORY_DIR" ]; then
        echo "## Auto-memory entries for this project"
        echo ""
        echo "Location: \`${MEMORY_DIR}\`"
        echo ""
        for mf in "$MEMORY_DIR"/*.md; do
            [ -f "$mf" ] || continue
            [ "$(basename "$mf")" = "MEMORY.md" ] && continue
            # Extract front-matter description if present.
            desc=$(awk '/^description:/ {sub(/^description: */, ""); print; exit}' "$mf" 2>/dev/null)
            type=$(awk '/^type:/ {sub(/^type: */, ""); print; exit}' "$mf" 2>/dev/null)
            name=$(basename "$mf" .md)
            printf -- "- **%s** [%s] — %s\n" "$name" "${type:-?}" "${desc:-(no description)}"
        done
        echo ""
        # Also include the memory index if present.
        if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
            echo "### MEMORY.md index"
            echo ""
            echo '```'
            cat "$MEMORY_DIR/MEMORY.md"
            echo '```'
            echo ""
        fi
    else
        echo "## Auto-memory"
        echo ""
        echo "No auto-memory directory at \`${MEMORY_DIR}\` (Claude Code may not have created memory for this project yet)."
        echo ""
    fi

    # Open questions / TODOs / roadmap.
    for f in OPEN_QUESTIONS.md TODO.md ROADMAP.md PLAN.md STATUS.md docs/OPEN_QUESTIONS.md docs/TODO.md docs/ROADMAP.md; do
        if [ -f "$f" ]; then
            echo "## $f"
            echo ""
            echo '```'
            head -100 "$f"
            echo '```'
            echo ""
        fi
    done

    # Architecture references.
    for f in ARCHITECTURE.md docs/ARCHITECTURE.md docs/architecture.md; do
        if [ -f "$f" ]; then
            echo "## $f"
            echo ""
            echo '```'
            head -150 "$f"
            echo '```'
            echo ""
        fi
    done

    # Synthesis the agent must produce before drafting any doctrine.
    cat <<EOF
## Required synthesis (the agent fills these in before drafting)

The constitution / agents / anti-patterns docs must be a synthesis of what
this project IS — not a templated stub, not session notes. Before drafting,
write answers to these questions in your reply to the user. If you cannot
answer one from the ingested material, ask. Do not guess.

1. **Domain & purpose** — what does this project actually do, in one paragraph? What problem does it solve? Who uses it?
2. **Core mission target** — what's the project's primary success metric? (revenue, latency, accuracy, throughput, deliverable, etc.) Pull from CLAUDE.md / README / docs, do not invent.
3. **All major features / pipelines / integrations** — list every one mentioned across the docs. Research pipelines, data sources, third-party integrations, social-media pulls, model integrations, deployment targets. Do not omit something because it isn't current work.
4. **Explicit P0 mandates** — every "MUST", "NEVER", "P0", "Golden Rule", "mandate", "forbidden" line from the directive grep above. The constitution must encode all of these.
5. **Domain invariants** — facts that must always hold (data integrity, regulatory, financial, security, mission-specific). Pull from CLAUDE.md and architecture docs.
6. **Existing governance** — if CLAUDE.md, AGENTS.md, GOVERNANCE.md, or governance/* already exist, the new constitution must FAITHFULLY ENCODE them, not replace them with generic templates. Only add things that aren't already covered.
7. **Open questions / contested decisions** — anything in OPEN_QUESTIONS / TODO / amendment proposals that the project hasn't resolved.
8. **Anti-patterns from history** — every "we got burned by X" story in memory or in any incident write-up.

## Drafting checklist (after the synthesis)

1. Show the user the proposed content BEFORE attempting the gated write. Get explicit approval. Never ask the user to approve a blank check.
2. The constitution must reflect EVERY load-bearing rule the project already has, not just what's currently top-of-mind.
3. The constitution must reflect every research direction, feature, integration, and pipeline the project documents — not just current work.
4. When unsure whether something is constitutional vs interaction-standard vs anti-pattern: ask the user.
5. Cite sources for every invariant — \`CLAUDE.md:line\`, \`docs/X.md\`, memory entry name. The user must be able to verify what came from where.
EOF

} > "$OUT"

ok "wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
ok "agents must read this file before drafting any governance doc"
echo "$OUT"
