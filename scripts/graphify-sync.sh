#!/usr/bin/env bash
# graphify-sync.sh - Continuous knowledge graph sync daemon.
#
# Detects file changes since last run, rebuilds AST (free), and runs
# semantic extraction on new/changed docs via a local Ollama model.
#
# Usage:
#   ./scripts/graphify-sync.sh                  # one-shot sync
#   ./scripts/graphify-sync.sh --watch          # loop every 5 minutes
#   ./scripts/graphify-sync.sh --watch --interval 120  # loop every 2 min
#
# Environment:
#   GRAPHIFY_MODEL    - Ollama model for semantic extraction (default: qwen3.6:35b)
#   OLLAMA_HOST       - Ollama endpoint (default: http://host.docker.internal:11434)
#   GRAPHIFY_INTERVAL - Seconds between sync cycles in watch mode (default: 300)

set -euo pipefail

PROJECT_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
cd "$PROJECT_ROOT"

PYTHON="python3"
[ -f graphify-out/.graphify_python ] && PYTHON="$(cat graphify-out/.graphify_python)"

MODEL="${GRAPHIFY_MODEL:-qwen3.6:35b}"
OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"
INTERVAL="${GRAPHIFY_INTERVAL:-300}"
WATCH=false
STAMP_FILE="graphify-out/.last_sync"
LOCK_FILE="graphify-out/.sync.lock"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true; shift ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

log() { echo "[graphify-sync $(date +%H:%M:%S)] $*"; }

check_ollama() {
    if curl -sf "${OLLAMA}/api/tags" >/dev/null 2>&1; then
        return 0
    else
        log "WARN: Ollama not reachable at $OLLAMA - AST-only mode"
        return 1
    fi
}

get_changed_files() {
    if [ -f "$STAMP_FILE" ]; then
        # Files modified since last sync
        find . -newer "$STAMP_FILE" \
            -not -path './.git/*' \
            -not -path './graphify-out/*' \
            -not -path './.venv/*' \
            -not -path './venv/*' \
            -not -path './__pycache__/*' \
            -not -path './.claude/*' \
            -type f \( \
                -name '*.py' -o -name '*.js' -o -name '*.ts' -o \
                -name '*.go' -o -name '*.rs' -o -name '*.java' -o \
                -name '*.c' -o -name '*.cpp' -o -name '*.rb' -o \
                -name '*.md' -o -name '*.txt' -o -name '*.rst' -o \
                -name '*.pdf' -o -name '*.yaml' -o -name '*.yml' -o \
                -name '*.json' -o -name '*.toml' \
            \) 2>/dev/null
    else
        # First run - everything
        echo "__full_rebuild__"
    fi
}

sync_once() {
    # Acquire lock
    if [ -f "$LOCK_FILE" ]; then
        log "Another sync is running (lock exists). Skipping."
        return 0
    fi
    touch "$LOCK_FILE"

    CHANGED=$(get_changed_files)
    CHANGE_COUNT=$(echo "$CHANGED" | grep -c '.' || true)

    if [ "$CHANGED" = "__full_rebuild__" ]; then
        log "First sync - full rebuild"
    elif [ "$CHANGE_COUNT" -eq 0 ]; then
        log "No changes since last sync. Skipping."
        rm -f "$LOCK_FILE"
        return 0
    else
        log "$CHANGE_COUNT file(s) changed since last sync"
    fi

    # Step 1: Detect
    log "Detecting files..."
    "$PYTHON" -c "
import json
from graphify.detect import detect
from pathlib import Path
result = detect(Path('.'))
Path('graphify-out/.graphify_detect.json').write_text(json.dumps(result))
print(f'  {result[\"total_files\"]} files, ~{result[\"total_words\"]} words')
" 2>/dev/null

    # Step 2: AST extraction (always free)
    log "AST extraction (local, free)..."
    "$PYTHON" -c "
import json
from graphify.extract import collect_files, extract
from pathlib import Path

detect = json.loads(Path('graphify-out/.graphify_detect.json').read_text())
code_files = []
for f in detect.get('files', {}).get('code', []):
    code_files.extend(collect_files(Path(f)) if Path(f).is_dir() else [Path(f)])

if code_files:
    result = extract(code_files)
    Path('graphify-out/.graphify_ast.json').write_text(json.dumps(result, indent=2))
    print(f'  AST: {len(result[\"nodes\"])} nodes, {len(result[\"edges\"])} edges')
else:
    Path('graphify-out/.graphify_ast.json').write_text(
        json.dumps({'nodes':[],'edges':[],'input_tokens':0,'output_tokens':0}))
    print('  No code files')
" 2>/dev/null

    # Step 3: Semantic extraction via Ollama (if available)
    OLLAMA_OK=false
    if check_ollama; then
        OLLAMA_OK=true
        log "Semantic extraction via $MODEL at $OLLAMA..."
        "$PYTHON" << 'PYEOF'
import json, os, sys
from pathlib import Path

try:
    from graphify.cache import check_semantic_cache, save_semantic_cache
except ImportError:
    print("  graphify.cache not available - skipping semantic")
    sys.exit(0)

detect = json.loads(Path('graphify-out/.graphify_detect.json').read_text())
non_code = detect.get('files', {}).get('document', []) + detect.get('files', {}).get('paper', [])

if not non_code:
    print("  No docs/papers - semantic extraction skipped")
    sys.exit(0)

cached_nodes, cached_edges, cached_hyperedges, uncached = check_semantic_cache(non_code)

if not uncached:
    print(f"  All {len(non_code)} files cached - semantic extraction skipped")
    # Write cached data
    Path('graphify-out/.graphify_semantic.json').write_text(json.dumps({
        'nodes': cached_nodes, 'edges': cached_edges,
        'hyperedges': cached_hyperedges, 'input_tokens': 0, 'output_tokens': 0
    }))
    sys.exit(0)

print(f"  {len(uncached)} uncached files need extraction")

# Use Ollama for extraction
import urllib.request

model = os.environ.get('GRAPHIFY_MODEL', 'qwen3.6:35b')
ollama = os.environ.get('OLLAMA_HOST', 'http://host.docker.internal:11434')

new_nodes = list(cached_nodes)
new_edges = list(cached_edges)
new_hyperedges = list(cached_hyperedges)

for i, filepath in enumerate(uncached):
    try:
        content = Path(filepath).read_text(errors='replace')[:8000]  # Cap per file
        prompt = f"""Extract a knowledge graph from this document. Output ONLY valid JSON.

File: {filepath}

Content:
{content}

Output this JSON (no other text):
{{"nodes":[{{"id":"unique_id","label":"Name","file_type":"document","source_file":"{filepath}"}}],"edges":[{{"source":"id1","target":"id2","relation":"references","confidence":"EXTRACTED","confidence_score":1.0,"source_file":"{filepath}"}}]}}"""

        req = urllib.request.Request(
            f'{ollama}/api/generate',
            data=json.dumps({
                'model': model,
                'prompt': prompt,
                'stream': False,
                'options': {'temperature': 0.1, 'num_predict': 2048}
            }).encode(),
            headers={'Content-Type': 'application/json'}
        )
        resp = urllib.request.urlopen(req, timeout=120)
        result = json.loads(resp.read())
        text = result.get('response', '')

        # Try to parse JSON from response
        start = text.find('{')
        end = text.rfind('}') + 1
        if start >= 0 and end > start:
            data = json.loads(text[start:end])
            new_nodes.extend(data.get('nodes', []))
            new_edges.extend(data.get('edges', []))
            new_hyperedges.extend(data.get('hyperedges', []))

        if (i + 1) % 25 == 0:
            print(f"  Extracted {i+1}/{len(uncached)} files...")

    except Exception as e:
        print(f"  WARN: {filepath}: {e}")
        continue

# Dedup nodes
seen = set()
deduped = []
for n in new_nodes:
    if n['id'] not in seen:
        deduped.append(n)
        seen.add(n['id'])

Path('graphify-out/.graphify_semantic.json').write_text(json.dumps({
    'nodes': deduped, 'edges': new_edges,
    'hyperedges': new_hyperedges, 'input_tokens': 0, 'output_tokens': 0
}, indent=2))
print(f"  Semantic: {len(deduped)} nodes, {len(new_edges)} edges")
PYEOF
    fi

    # Step 4: Merge AST + semantic → graph
    log "Building graph..."
    GRAPHIFY_MODEL="$MODEL" OLLAMA_HOST="$OLLAMA" "$PYTHON" -c "
import json
from pathlib import Path
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json

ast = json.loads(Path('graphify-out/.graphify_ast.json').read_text())
sem_path = Path('graphify-out/.graphify_semantic.json')
sem = json.loads(sem_path.read_text()) if sem_path.exists() else {'nodes':[],'edges':[],'hyperedges':[]}

seen = {n['id'] for n in ast['nodes']}
merged_nodes = list(ast['nodes'])
for n in sem['nodes']:
    if n['id'] not in seen:
        merged_nodes.append(n)
        seen.add(n['id'])

extraction = {
    'nodes': merged_nodes,
    'edges': ast['edges'] + sem['edges'],
    'hyperedges': sem.get('hyperedges', []),
    'input_tokens': 0, 'output_tokens': 0,
}
Path('graphify-out/.graphify_extract.json').write_text(json.dumps(extraction, indent=2))

detection = json.loads(Path('graphify-out/.graphify_detect.json').read_text())
G = build_from_json(extraction)
communities = cluster(G)
cohesion = score_all(G, communities)
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
labels = {cid: 'Community ' + str(cid) for cid in communities}
questions = suggest_questions(G, communities, labels)

report = generate(G, communities, cohesion, labels, gods, surprises, detection, {'input':0,'output':0}, '.', suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report)
to_json(G, communities, 'graphify-out/graph.json')
print(f'  Graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges, {len(communities)} communities')
" 2>/dev/null

    # Update timestamp
    touch "$STAMP_FILE"
    rm -f "$LOCK_FILE"
    log "Sync complete."
}

# Main
if $WATCH; then
    log "Watch mode - syncing every ${INTERVAL}s (model: $MODEL)"
    log "Press Ctrl+C to stop"
    while true; do
        sync_once
        sleep "$INTERVAL"
    done
else
    sync_once
fi
