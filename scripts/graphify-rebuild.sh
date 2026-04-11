#!/usr/bin/env bash
# graphify-rebuild.sh - Rebuild the knowledge graph for this project.
# Called by git hooks (post-commit, post-checkout) or manually.
#
# Usage:
#   ./scripts/graphify-rebuild.sh              # full rebuild
#   ./scripts/graphify-rebuild.sh --update     # incremental (changed files only)
#   ./scripts/graphify-rebuild.sh --ast-only   # code-only, no LLM tokens

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

MODE="${1:---update}"
PYTHON="python3"

# Use graphify's cached python if available
if [ -f graphify-out/.graphify_python ]; then
    PYTHON="$(cat graphify-out/.graphify_python)"
fi

# Verify graphify is installed
if ! "$PYTHON" -c "import graphify" 2>/dev/null; then
    echo "[graphify] Not installed. Run: pip install graphifyy"
    exit 1
fi

echo "[graphify] Detecting files..."
"$PYTHON" -c "
import json
from graphify.detect import detect
from pathlib import Path
result = detect(Path('.'))
Path('graphify-out/.graphify_detect.json').write_text(json.dumps(result))
print(f'  {result[\"total_files\"]} files, ~{result[\"total_words\"]} words')
" 2>/dev/null

echo "[graphify] Running AST extraction (free, no LLM)..."
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
    Path('graphify-out/.graphify_ast.json').write_text(json.dumps({'nodes':[],'edges':[],'input_tokens':0,'output_tokens':0}))
    echo '  No code files'
fi
" 2>/dev/null

if [ "$MODE" = "--ast-only" ]; then
    echo "[graphify] AST-only mode - skipping semantic extraction"
    # Use AST as the full extraction
    cp graphify-out/.graphify_ast.json graphify-out/.graphify_extract.json
else
    echo "[graphify] Merging AST + existing semantic data..."
    "$PYTHON" -c "
import json
from pathlib import Path

ast = json.loads(Path('graphify-out/.graphify_ast.json').read_text())
sem_path = Path('graphify-out/.graphify_semantic.json')
sem = json.loads(sem_path.read_text()) if sem_path.exists() else {'nodes':[],'edges':[],'hyperedges':[]}

seen = {n['id'] for n in ast['nodes']}
merged_nodes = list(ast['nodes'])
for n in sem['nodes']:
    if n['id'] not in seen:
        merged_nodes.append(n)
        seen.add(n['id'])

merged = {
    'nodes': merged_nodes,
    'edges': ast['edges'] + sem['edges'],
    'hyperedges': sem.get('hyperedges', []),
    'input_tokens': sem.get('input_tokens', 0),
    'output_tokens': sem.get('output_tokens', 0),
}
Path('graphify-out/.graphify_extract.json').write_text(json.dumps(merged, indent=2))
print(f'  Merged: {len(merged_nodes)} nodes, {len(merged[\"edges\"])} edges')
"
fi

echo "[graphify] Building graph + clustering..."
"$PYTHON" -c "
import json
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json
from pathlib import Path

extraction = json.loads(Path('graphify-out/.graphify_extract.json').read_text())
detection  = json.loads(Path('graphify-out/.graphify_detect.json').read_text())

G = build_from_json(extraction)
communities = cluster(G)
cohesion = score_all(G, communities)
tokens = {'input': extraction.get('input_tokens', 0), 'output': extraction.get('output_tokens', 0)}
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
labels = {cid: 'Community ' + str(cid) for cid in communities}
questions = suggest_questions(G, communities, labels)

report = generate(G, communities, cohesion, labels, gods, surprises, detection, tokens, '.', suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report)
to_json(G, communities, 'graphify-out/graph.json')
print(f'  Graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges, {len(communities)} communities')
" 2>/dev/null

echo "[graphify] Done. Report: graphify-out/GRAPH_REPORT.md"
