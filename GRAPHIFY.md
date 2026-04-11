# Graphify - Knowledge Graph Setup & Maintenance

Token-optimized codebase navigation for Claude Code. Builds a persistent
knowledge graph so your AI assistant navigates by structure instead of
grepping every file. One-time build, automatic maintenance.

## Quick Start

```bash
# Install graphify (done automatically by install.sh)
pip install graphifyy --break-system-packages 2>/dev/null || pip install graphifyy

# Register the /graphify skill
graphify install

# Install always-on Claude Code hook
graphify claude install

# Install git hooks for auto-rebuild
graphify hook install

# Build the graph (inside Claude Code)
/graphify .
```

## What You Get

```
graphify-out/
├── GRAPH_REPORT.md    # God nodes, communities, surprising connections
├── graph.json         # Persistent queryable graph
├── graph.html         # Interactive visualization (if <6K nodes)
└── cache/             # SHA256 cache - re-runs skip unchanged files
```

## Dynamic Maintenance

The graph grows and shrinks with your project through three mechanisms:

### 1. Git Hooks (automatic, free)

Post-commit and post-checkout hooks rebuild the AST layer on every
commit. Code-only, local tree-sitter parsing, zero API cost.

### 2. Cron Sync (automatic, free via Ollama)

The `graphify-sync.sh` daemon runs every 5 minutes:
- Diffs files by timestamp since last sync
- Nothing changed? → skips (zero cost)
- Files added? → new nodes appear
- Files deleted? → nodes drop on next AST pass
- Semantic extraction → local Ollama model ($0)

### 3. Manual Rebuild

```bash
./scripts/graphify-rebuild.sh              # full rebuild
./scripts/graphify-rebuild.sh --update     # incremental (changed only)
./scripts/graphify-rebuild.sh --ast-only   # code structure only, free
```

## Local Models for Extraction

**Critical:** Semantic extraction should use local Ollama models, not
Claude. Claude is for thinking; local models are for structured text
extraction.

```bash
export GRAPHIFY_MODEL=qwen3.6:35b
```

Cost comparison:

- Subagents via Claude API: burns 50%+ of session budget
- Same work via Ollama qwen3.6:35b: $0, about 3 minutes
- AST extraction: always $0 (local tree-sitter)

## Querying

```bash
# Inside Claude Code
/graphify query "how does auth work"
/graphify path "ModuleA" "ModuleB"
/graphify explain "ClassName"

# Terminal (no Claude needed)
graphify query "show the flow" --graph graphify-out/graph.json
graphify benchmark graphify-out/graph.json
```

## Multi-Platform

| Platform | Install |
|---|---|
| Claude Code | `graphify install && graphify claude install` |
| Codex | `graphify install --platform codex && graphify codex install` |
| Cursor | `graphify cursor install` |
| Gemini CLI | `graphify install --platform gemini && graphify gemini install` |
| Aider | `graphify install --platform aider && graphify aider install` |

## Uninstall

```bash
graphify claude uninstall
graphify hook uninstall
pip uninstall graphifyy
rm -rf graphify-out/
```
