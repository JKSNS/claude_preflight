#!/usr/bin/env bash
# soft-references.sh - Generate lightweight overview nodes for large/excluded directories.
#
# Scans directories that are too large for full graphify indexing and produces
# summary JSON that can be merged into the knowledge graph as "soft reference" nodes.
#
# Usage:
#   ./scripts/soft-references.sh                    # auto-detect large dirs
#   ./scripts/soft-references.sh benchmarks results  # specific dirs
#   ./scripts/soft-references.sh --threshold 500     # custom file count threshold
#
# Output: graphify-out/soft_references.json
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

THRESHOLD=200
DIRS=()
PYTHON="${GRAPHIFY_PYTHON:-python3}"
CHECK_STALE=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --check-stale) CHECK_STALE=true; shift ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

# --check-stale mode: report staleness instead of regenerating. Exit 0 if
# everything is fresh, 1 if any source dir is newer than the overview.
if [ "$CHECK_STALE" = "true" ]; then
    if [ ! -f graphify-out/SOFT_REFERENCES.md ]; then
        echo "  [WARN] no graphify-out/SOFT_REFERENCES.md — run /preflight soft-refs"
        exit 1
    fi
    OVERVIEW_TS="$(stat -c %Y graphify-out/SOFT_REFERENCES.md 2>/dev/null || echo 0)"
    STALE_DIRS=()
    # Get the dirs the overview already covers (parse SOFT_REFERENCES.md headings).
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        [ -d "$d" ] || continue
        # Find the most recent mtime in the subtree.
        SRC_TS="$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
        if [ -n "$SRC_TS" ] && [ "$SRC_TS" -gt "$OVERVIEW_TS" ]; then
            AGE=$(( SRC_TS - OVERVIEW_TS ))
            STALE_DIRS+=("$d (newer by $((AGE/86400))d)")
        fi
    done < <(grep -oE '^## [a-zA-Z0-9_./-]+' graphify-out/SOFT_REFERENCES.md 2>/dev/null | awk '{print $2}')
    if [ "${#STALE_DIRS[@]}" -gt 0 ]; then
        echo "  [STALE] ${#STALE_DIRS[@]} source dir(s) newer than overview:"
        for d in "${STALE_DIRS[@]}"; do echo "          $d"; done
        echo "  Regenerate: ./scripts/soft-references.sh"
        exit 1
    fi
    echo "  [OK] overview is fresh ($(date -d "@$OVERVIEW_TS" +%Y-%m-%d 2>/dev/null))"
    exit 0
fi

# Auto-detect large directories if none specified
if [ ${#DIRS[@]} -eq 0 ]; then
    while IFS= read -r dir; do
        DIRS+=("$dir")
    done < <(
        $PYTHON -c "
import os, sys

threshold = $THRESHOLD
top_dirs = sorted(
    [d for d in os.listdir('.') if os.path.isdir(d) and not d.startswith('.')],
)

for d in top_dirs:
    count = sum(1 for _ in os.walk(d) for __ in _[2])
    if count >= threshold:
        # Check if it's in .graphifyignore
        ignored = False
        if os.path.exists('.graphifyignore'):
            with open('.graphifyignore') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and line.rstrip('/') == d:
                        ignored = True
                        break
        print(d)
" 2>/dev/null
    )
fi

if [ ${#DIRS[@]} -eq 0 ]; then
    echo "No large directories found (threshold: $THRESHOLD files)."
    exit 0
fi

echo "Generating soft references for: ${DIRS[*]}"

# Generate overview JSON
$PYTHON -c "
import json, os, sys
from pathlib import Path
from collections import Counter

dirs = sys.argv[1:]
nodes = []
edges = []

for d in dirs:
    if not os.path.isdir(d):
        continue

    # Count files by extension
    ext_counts = Counter()
    total_files = 0
    total_bytes = 0
    subdirs = set()

    for root, dirnames, filenames in os.walk(d):
        depth = root.count(os.sep) - d.count(os.sep)
        if depth == 0:
            subdirs.update(dirnames)
        for f in filenames:
            total_files += 1
            ext = Path(f).suffix.lower() or '(none)'
            ext_counts[ext] += 1
            try:
                total_bytes += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass

    # Human-readable size
    size = total_bytes
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024:
            size_str = f'{size:.1f} {unit}'
            break
        size /= 1024
    else:
        size_str = f'{size:.1f} TB'

    # Top extensions
    top_exts = ext_counts.most_common(8)
    ext_summary = ', '.join(f'{ext} ({n})' for ext, n in top_exts)

    # Read README if present
    readme_text = ''
    for readme_name in ['README.md', 'README.txt', 'README', 'readme.md']:
        readme_path = os.path.join(d, readme_name)
        if os.path.exists(readme_path):
            with open(readme_path, errors='replace') as f:
                readme_text = f.read(2000).strip()
            break

    # Extract first paragraph as description
    description = ''
    if readme_text:
        lines = readme_text.split('\n')
        # Skip title
        content_lines = []
        for line in lines:
            if line.startswith('#'):
                continue
            if line.strip():
                content_lines.append(line.strip())
            elif content_lines:
                break
        description = ' '.join(content_lines)[:300]

    # Build node
    node_id = f'soft_ref:{d}'
    node = {
        'id': node_id,
        'label': d,
        'type': 'soft_reference',
        'properties': {
            'total_files': total_files,
            'total_size': size_str,
            'subdirectories': sorted(subdirs)[:20],
            'file_types': ext_summary,
            'description': description or f'Large directory with {total_files} files',
            'indexed': False,
            'threshold_note': f'Excluded from full indexing ({total_files} files > threshold)',
        }
    }
    nodes.append(node)

    # Create edges to subdirectories
    for sub in sorted(subdirs)[:15]:
        sub_path = os.path.join(d, sub)
        sub_count = sum(1 for _ in os.walk(sub_path) for __ in _[2])
        edges.append({
            'source': node_id,
            'target': f'soft_ref:{d}/{sub}',
            'type': 'contains',
            'properties': {'file_count': sub_count}
        })
        nodes.append({
            'id': f'soft_ref:{d}/{sub}',
            'label': f'{d}/{sub}',
            'type': 'soft_reference_subdir',
            'properties': {
                'file_count': sub_count,
                'parent': d,
            }
        })

output = {'nodes': nodes, 'edges': edges}

out_path = 'graphify-out/soft_references.json'
os.makedirs('graphify-out', exist_ok=True)
with open(out_path, 'w') as f:
    json.dump(output, f, indent=2)

print(f'Generated {len(nodes)} nodes, {len(edges)} edges → {out_path}')

# Also generate a markdown summary
summary_lines = ['# Soft References — Large Directory Overviews', '', 'Directories excluded from full graphify indexing.', '']
for n in nodes:
    if n['type'] == 'soft_reference':
        props = n['properties']
        summary_lines.append(f'## {n[\"label\"]}/')
        summary_lines.append(f'')
        summary_lines.append(f'- **Files**: {props[\"total_files\"]}')
        summary_lines.append(f'- **Size**: {props[\"total_size\"]}')
        summary_lines.append(f'- **Types**: {props[\"file_types\"]}')
        if props.get('description'):
            summary_lines.append(f'- **Description**: {props[\"description\"]}')
        if props.get('subdirectories'):
            summary_lines.append(f'- **Subdirectories**: {\", \".join(props[\"subdirectories\"])}')
        summary_lines.append('')

md_path = 'graphify-out/SOFT_REFERENCES.md'
with open(md_path, 'w') as f:
    f.write('\n'.join(summary_lines))

print(f'Summary → {md_path}')
" "${DIRS[@]}"

echo "Done. Soft references available for graph queries and GRAPH_REPORT context."
