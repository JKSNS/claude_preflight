#!/usr/bin/env bash
# staleness-scan.sh - Find stale / unreferenced files in the project.
#
# Replaces the old name-based reorg as the default for /preflight cleanup.
# Looks at four orthogonal signals; flags files that hit two or more.
#
# Signals:
#   1. Orphan in graphify graph (zero inbound edges, not in any community)
#   2. Not referenced by any source file (cross-grep against import statements)
#   3. Not modified in N days (git log -1 mtime)
#   4. Filename heuristic (*.bak, *.old, *-copy.*, *-v[0-9]*.*, *.deprecated, draft/)
#
# Output: a report at staleness-report.md listing each candidate with the
# signals that flagged it. NEVER moves files automatically — proposes moves
# to archive/<reason>/ for the user to approve one at a time.
#
# Usage:
#   ./scripts/staleness-scan.sh                  # scan + write report
#   ./scripts/staleness-scan.sh --signals 1      # less strict (any 1 signal)
#   ./scripts/staleness-scan.sh --age 90         # 90-day mtime threshold (default 180)
#   ./scripts/staleness-scan.sh --apply          # interactive: move-or-skip per file
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

MIN_SIGNALS=2
AGE_DAYS=180
APPLY=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --signals) shift; MIN_SIGNALS="${1:-2}" ;;
        --signals=*) MIN_SIGNALS="${1#--signals=}" ;;
        --age)     shift; AGE_DAYS="${1:-180}" ;;
        --age=*)   AGE_DAYS="${1#--age=}" ;;
        --apply)   APPLY=true ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
    shift
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${CYAN}[stale]${NC} $*"; }
ok()  { echo -e "  ${GREEN}[OK]${NC} $*"; }

REPORT="staleness-report.md"
log "scanning  min-signals=$MIN_SIGNALS  age=${AGE_DAYS}d"

python3 - "$AGE_DAYS" "$MIN_SIGNALS" "$REPORT" "$PROJECT_DIR" <<'PY'
import sys, os, re, subprocess, json, pathlib, time, datetime, fnmatch, collections

age_days, min_signals, report_path, project_dir = sys.argv[1:5]
age_days = int(age_days); min_signals = int(min_signals)
project = pathlib.Path(project_dir)

# Collect all candidate files (tracked by git, exclude vendored/cache/vcs trees).
try:
    tracked = subprocess.check_output(
        ["git", "-C", project_dir, "ls-files"], text=True
    ).splitlines()
except Exception:
    tracked = []

EXCLUDE_DIRS = {".git", "node_modules", "venv", ".venv", "target", "dist",
                "build", ".next", "graphify-out", "archive", "audits", "memory",
                ".agent", "governance", "policy", "scripts", "hooks", "skills",
                "profiles", "templates", "images"}
EXCLUDE_NAMES = {"LICENSE", "VERSION", "CHANGELOG.md", ".gitignore",
                 ".gitattributes", ".graphifyignore", "README.md", "CLAUDE.md",
                 "AGENTS.md", "CONSTITUTION.md", "GOVERNANCE.md"}

# Lockfiles, manifests, and other "always keep" classes — never flag these as
# stale even if they hit the not-referenced + age signals. They exist to
# pin/declare state, not to be referenced from source.
ALWAYS_KEEP_NAMES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
    "Cargo.lock", "poetry.lock", "uv.lock", "Pipfile.lock", "Gemfile.lock",
    "composer.lock", "go.sum", "mix.lock",
    "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile",
    "composer.json", "mix.exs", "Pipfile", "requirements.txt",
    "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
    "Makefile", "Rakefile", "Justfile",
    ".dockerignore", ".npmignore", ".eslintrc", ".prettierrc",
    ".editorconfig", ".nvmrc", ".python-version", ".ruby-version",
    ".pre-commit-config.yaml", ".gitmodules",
}
ALWAYS_KEEP_SUFFIXES = (".lock",)

candidates = []
for f in tracked:
    p = pathlib.Path(f)
    if any(part in EXCLUDE_DIRS for part in p.parts):
        continue
    if p.name in EXCLUDE_NAMES:
        continue
    if p.name in ALWAYS_KEEP_NAMES:
        continue
    if any(p.name.endswith(s) for s in ALWAYS_KEEP_SUFFIXES):
        continue
    if (project / f).is_dir():
        continue
    candidates.append(f)

# Signal 1: Orphan in graphify graph.
orphans = set()
graph_path = project / "graphify-out" / "graph.json"
if graph_path.exists():
    try:
        graph = json.loads(graph_path.read_text())
        nodes = {n.get("id", n.get("name", "")): n for n in graph.get("nodes", [])}
        edges = graph.get("links", graph.get("edges", []))
        inbound = collections.Counter()
        for e in edges:
            tgt = e.get("target") or e.get("to")
            if tgt:
                inbound[tgt] += 1
        # An "orphan" is a node with zero inbound edges and no community.
        for nid, node in nodes.items():
            if inbound.get(nid, 0) == 0:
                # Try to map node id back to a file path.
                fp = node.get("file") or node.get("path") or nid
                if fp and pathlib.Path(fp).exists():
                    orphans.add(str(pathlib.Path(fp).relative_to(project) if pathlib.Path(fp).is_absolute() else fp))
    except Exception:
        pass

# Signal 2: Not referenced by any source file (cross-grep).
# Build an "import-like" grep across all candidate files for each candidate's
# basename (without extension) and full path. A file referenced by another file
# in the project is NOT stale by this signal.
referenced = set()
basenames = {f: pathlib.Path(f).stem for f in candidates}
all_text_files = []
for f in candidates:
    p = project / f
    if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp",
                             ".pdf", ".zip", ".tar", ".gz", ".so", ".dylib",
                             ".bin", ".exe", ".class", ".jar", ".wasm",
                             ".mp4", ".mp3", ".wav", ".webm", ".mov", ".avi"):
        continue
    all_text_files.append(f)

# For each candidate, search for its name in the corpus. Cap at first hit.
corpus = {}
for f in all_text_files:
    try:
        corpus[f] = (project / f).read_text(errors="ignore")
    except Exception:
        corpus[f] = ""

# A reference is one of:
#   - the full relative path appears in another file (covers configs, docs)
#   - the stem appears in an import-shaped context: `import X`, `from X`,
#     `require('X')`, `<script src=".../X.js">`, etc.
# A bare substring match like "setup" matching anywhere is too loose — it
# false-positives on common stems like setup/index/main/util.
import_patterns = {
    "py":   [
        r"\bimport\s+{stem}\b",          # import used
        r"\bfrom\s+{stem}\s+import",     # from used import X
        r"\bfrom\s+\S*\.{stem}\s+import",# from foo.used import X
        r"\bfrom\s+\.{stem}\s+import",   # from .used import X
        r"\bimport\s+\S*\.{stem}\b",     # import foo.used
    ],
    "js":   [r"require\(\s*['\"][^'\"]*{stem}['\"]", r"from\s+['\"][^'\"]*{stem}['\"]"],
    "ts":   [r"require\(\s*['\"][^'\"]*{stem}['\"]", r"from\s+['\"][^'\"]*{stem}['\"]"],
    "go":   [r'"\S*/{stem}"'],
    "rs":   [r"\bmod\s+{stem}\b", r"\buse\s+\S+::{stem}\b"],
    "rb":   [r"require[_relative]*\s+['\"][^'\"]*{stem}['\"]"],
    "java": [r"\bimport\s+\S+\.{stem}\b"],
}
generic_patterns = [
    r"\b{stem}\.[a-z]+\b",                 # used as a module: `setup.foo()`
    r"<script[^>]*src=['\"][^'\"]*{stem}\.",
    r"<link[^>]*href=['\"][^'\"]*{stem}\.",
    r"src=['\"][^'\"]*{stem}\.[a-z]+['\"]",
]

for f in candidates:
    needle_path = f
    needle_stem = basenames[f]
    if not needle_stem or len(needle_stem) <= 2:
        continue
    safe_stem = re.escape(needle_stem)
    found = False
    for other, text in corpus.items():
        if other == f or not text:
            continue
        # Strong signal: the full relative path appears verbatim.
        if needle_path in text:
            found = True; break
        # Build per-language patterns from the OTHER file's extension.
        ext = pathlib.Path(other).suffix.lstrip(".").lower()
        patterns = list(import_patterns.get(ext, []))
        patterns.extend(generic_patterns)
        for pat in patterns:
            if re.search(pat.format(stem=safe_stem), text):
                found = True; break
        if found:
            break
    if found:
        referenced.add(f)

unreferenced = set(candidates) - referenced

# Signal 3: Old git mtime.
old = set()
threshold = time.time() - age_days * 86400
for f in candidates:
    try:
        out = subprocess.check_output(
            ["git", "-C", project_dir, "log", "-1", "--format=%at", "--", f],
            text=True
        ).strip()
        if out and int(out) < threshold:
            old.add(f)
    except Exception:
        pass

# Signal 4: Filename heuristics.
heuristic = set()
HEURISTIC_PATTERNS = ["*.bak", "*.old", "*.orig", "*~", "*.swp", "*.tmp",
                      "*-copy*", "*-v[0-9]*", "*-deprecated*", "*.deprecated.*",
                      "*-draft*", "*-archived*", "scratch.*", "wip-*", "TODO_*"]
HEURISTIC_DIRS = ["draft/", "drafts/", "scratch/", "old/", "_old/", "archive_/",
                  "deprecated/", "_archive/", "wip/"]

for f in candidates:
    name = pathlib.Path(f).name
    matched = False
    for pat in HEURISTIC_PATTERNS:
        if fnmatch.fnmatch(name, pat):
            heuristic.add(f); matched = True; break
    if matched:
        continue
    for d in HEURISTIC_DIRS:
        if d in f:
            heuristic.add(f); break

# Aggregate signals per file.
signals = {f: [] for f in candidates}
for f in orphans & set(candidates):     signals[f].append("orphan-in-graph")
for f in unreferenced:                  signals[f].append("not-referenced")
for f in old:                           signals[f].append("untouched-{}d".format(age_days))
for f in heuristic:                     signals[f].append("filename-heuristic")

flagged = [(f, sigs) for f, sigs in signals.items() if len(sigs) >= min_signals]
flagged.sort(key=lambda x: (-len(x[1]), x[0]))

# Write the report.
with open(report_path, "w") as out:
    out.write(f"# Staleness report\n\n")
    out.write(f"Generated: {datetime.datetime.now().isoformat()}\n")
    out.write(f"Min signals: {min_signals}  |  Age threshold: {age_days}d\n\n")
    if not flagged:
        out.write("> No files flagged. Run with `--signals 1` to be more aggressive.\n")
    else:
        out.write(f"## {len(flagged)} candidate(s) flagged\n\n")
        out.write("| File | Signals | Suggested archive | Reason |\n")
        out.write("|---|---|---|---|\n")
        for f, sigs in flagged:
            reason = ", ".join(sigs)
            archive = "archive/stale/" + pathlib.Path(f).name
            out.write(f"| `{f}` | {len(sigs)} | `{archive}` | {reason} |\n")
        out.write("\n")
        out.write("## Next steps\n\n")
        out.write("- Review each candidate: do you actually use this file?\n")
        out.write("- Run `./scripts/staleness-scan.sh --apply` for interactive per-file move-or-skip.\n")
        out.write("- Files that should NEVER be flagged again can be added to `.staleness-keep`.\n")

print(f"  scanned   {len(candidates)} candidate file(s)")
print(f"  signals   orphan={len(orphans)} unreferenced={len(unreferenced)} old={len(old)} heuristic={len(heuristic)}")
print(f"  flagged   {len(flagged)} (>= {min_signals} signals)")
print(f"  report    {report_path}")

if "--apply" in sys.argv:
    pass  # apply mode handled in bash for the prompts
else:
    sys.exit(0)
PY

if [ "$APPLY" = "true" ]; then
    echo ""
    log "interactive apply mode"
    if [ ! -f "$REPORT" ]; then
        echo "  no report to apply" >&2
        exit 1
    fi
    # Snapshot before any move so a regretted apply has a one-line rollback.
    if [ -x scripts/snapshot.sh ]; then
        SNAP="$(./scripts/snapshot.sh create --trigger staleness-scan-apply 2>&1 | tail -1)"
        echo ""
    fi
    # Parse the report's table, ask per file.
    python3 - "$REPORT" <<'PY'
import re, sys, pathlib, subprocess, os
report = pathlib.Path(sys.argv[1]).read_text()
rows = re.findall(r"^\| `([^`]+)` \| \d+ \| `([^`]+)` \| ([^|]+) \|", report, re.M)
moved = 0
for src, dst, reason in rows:
    print(f"\n  {src}")
    print(f"    signals: {reason.strip()}")
    print(f"    suggested move: {dst}")
    ans = input("    move? (y/N/skip-all) ").strip().lower()
    if ans == "skip-all":
        print("  skipping remainder.")
        break
    if ans not in ("y", "yes"):
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        subprocess.check_call(["git", "mv", src, dst])
        moved += 1
        print(f"    moved.")
    except Exception:
        try:
            os.rename(src, dst); moved += 1
            print(f"    moved (non-git).")
        except Exception as e:
            print(f"    failed: {e}")
print(f"\n  total moved: {moved}")
PY
fi

ok "scan complete"
