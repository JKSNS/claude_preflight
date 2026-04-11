#!/usr/bin/env bash
# cross-project-ingest.sh - Seed governance from prior-project memory.
#
# Walks the user's auto-memory under ~/.claude/projects/*/memory/, extracts
# durable items (feedback, user, project, reference, anti-pattern), normalizes
# them, counts occurrences across projects, and emits candidate rows into the
# current project's governance/PROMOTION_QUEUE.md.
#
# An item that appears in N>=2 projects is a strong candidate for the master
# constitution; an item that appears in N=1 is offered for adoption with low
# confidence. The human ratifies via /govern promote.
#
# This is the "the constitution starts non-empty" piece: when a target project
# is freshly /preflight govern'd, it inherits everything the user has already
# repeated to past projects, so the new project does not start cold.
#
# Usage:
#   ./scripts/cross-project-ingest.sh                 # ingest all prior projects
#   ./scripts/cross-project-ingest.sh --dry-run       # report only, don't write
#   ./scripts/cross-project-ingest.sh --min 2         # only items in >= N projects
#   ./scripts/cross-project-ingest.sh --root <path>   # alternate memory root
#
# The current project itself is excluded from the ingest source.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

MEMORY_ROOT="${HOME}/.claude/projects"
MIN_OCCURRENCES=2
LIMIT=25
DRY_RUN=false
ANONYMIZE=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=true ;;
        --anonymize) ANONYMIZE=true ;;
        --min) shift; MIN_OCCURRENCES="${1:-2}" ;;
        --min=*) MIN_OCCURRENCES="${1#--min=}" ;;
        --limit) shift; LIMIT="${1:-25}" ;;
        --limit=*) LIMIT="${1#--limit=}" ;;
        --no-limit) LIMIT=0 ;;
        --root) shift; MEMORY_ROOT="${1:-}" ;;
        --root=*) MEMORY_ROOT="${1#--root=}" ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
    shift
done

if [ ! -d "$MEMORY_ROOT" ]; then
    echo "cross-project-ingest: no memory root at $MEMORY_ROOT" >&2
    exit 0
fi

# Claude Code slugifies project dirs as "-" + path[1:].replace("/", "-").
# /home/foo  →  -home-foo
CURRENT_SLUG="-$(echo "${PROJECT_DIR#/}" | sed 's|/|-|g')"

mkdir -p memory governance
[ -f memory/inbox.md ] || printf "# MEMORY INBOX\n\n" > memory/inbox.md
[ -f governance/PROMOTION_QUEUE.md ] || printf "# PROMOTION QUEUE\n\n" > governance/PROMOTION_QUEUE.md

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${CYAN}[ingest]${NC} $*"; }
ok()  { echo -e "  ${GREEN}[OK]${NC} $*"; }

log "scanning $MEMORY_ROOT  (excluding self: $CURRENT_SLUG)"

# Privacy notice. The candidate rows we append to PROMOTION_QUEUE include the
# source project names and the original statement text. If this project will
# be made public (open-source repo, shared with collaborators), pass
# --anonymize to strip prior-project names from the Source field.
#
# The acknowledgement marker stores a hash of the current set of source
# project slugs. If the set changes (new projects appear in
# ~/.claude/projects/), we re-warn — the user should know the data flow has
# expanded since they last acknowledged.
SOURCE_HASH=""
if [ -d "$MEMORY_ROOT" ]; then
    SOURCE_HASH="$(ls -1 "$MEMORY_ROOT" 2>/dev/null | grep -v "^$CURRENT_SLUG\$" | sort | sha256sum | awk '{print $1}' | cut -c1-12)"
fi
ACK_FILE=".agent/.cross-project-ingest-acknowledged"
ACK_PRIOR=""
[ -f "$ACK_FILE" ] && ACK_PRIOR="$(cat "$ACK_FILE" 2>/dev/null)"
if [ "$ACK_PRIOR" != "$SOURCE_HASH" ]; then
    if [ -n "$ACK_PRIOR" ]; then
        REASON="(source project set has changed since you last acknowledged)"
    else
        REASON="(first run in this project)"
    fi
    cat <<EOF

  Heads up $REASON: cross-project-ingest reads memory entries from your
  other Claude Code projects under $MEMORY_ROOT and writes them as
  candidates in this project's governance/PROMOTION_QUEUE.md. The "Source:"
  field will list the prior-project slugs and the "Statement:" field will
  contain the original memory text.

  If this project will be public or shared, pass --anonymize to strip the
  prior-project names from the Source field. (The Statement text always
  comes through; review and redact during promotion if needed.)

EOF
    mkdir -p .agent
    echo "$SOURCE_HASH" > "$ACK_FILE"
fi

# Collect every memory file under every project except the current one. Skip
# the index file (MEMORY.md) and any file in a "current" or "live" subdir.
python3 - "$MEMORY_ROOT" "$CURRENT_SLUG" "$MIN_OCCURRENCES" "$DRY_RUN" "$PROJECT_DIR" "$ANONYMIZE" "$LIMIT" <<'PY'
import sys, os, re, hashlib, datetime, pathlib, collections

memory_root, current_slug, min_occ_str, dry_run_str, project_dir, anonymize_str, limit_str = sys.argv[1:8]
min_occ = int(min_occ_str)
dry_run = dry_run_str == "true"
anonymize = anonymize_str == "true"
limit = int(limit_str)

root = pathlib.Path(memory_root)
items = []  # each: (project, type, name, description, hash, normalized)

def normalize(s):
    s = s.strip().lower()
    s = re.sub(r"\s+", " ", s)
    s = s.rstrip(".!?:; ")
    return s

for proj_dir in sorted(root.iterdir()):
    if not proj_dir.is_dir():
        continue
    if proj_dir.name == current_slug:
        continue
    mem_dir = proj_dir / "memory"
    if not mem_dir.is_dir():
        continue
    for mf in mem_dir.glob("*.md"):
        if mf.name == "MEMORY.md":
            continue
        try:
            text = mf.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        # Parse front matter (name, description, type) if present.
        m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", text, re.S)
        if m:
            front = m.group(1)
            body = m.group(2).strip()
        else:
            front = ""
            body = text.strip()
        def get(field):
            mm = re.search(rf"^{field}:\s*(.+)$", front, re.M | re.I)
            return mm.group(1).strip() if mm else ""
        mtype = get("type") or "user"
        name = get("name") or mf.stem
        description = get("description") or ""
        # The memory body itself is what gets promoted; the description summarizes.
        # Normalize on the description if present, else the first non-empty line.
        head = description if description else body.splitlines()[0] if body.splitlines() else ""
        if not head:
            continue
        norm = normalize(head)
        if not norm:
            continue
        h = hashlib.sha256(norm.encode()).hexdigest()[:12]
        items.append((proj_dir.name, mtype, name, head, h, norm, body))

if not items:
    print("  no prior-project memories found")
    sys.exit(0)

# Group by normalized hash, count distinct projects per item.
groups = collections.defaultdict(list)
for proj, mtype, name, head, h, norm, body in items:
    groups[h].append((proj, mtype, name, head, body))

projects_scanned = len({i[0] for i in items})
print(f"  scanned {projects_scanned} projects, {len(items)} memory entries")

# Build candidate list: any group with >= min_occ distinct projects.
candidates = []
for h, occurrences in groups.items():
    distinct_projects = sorted({o[0] for o in occurrences})
    if len(distinct_projects) < min_occ:
        continue
    # Pick the longest name and longest body as the canonical representation.
    by_proj = occurrences[0]
    name = max(occurrences, key=lambda o: len(o[2]))[2]
    head = max(occurrences, key=lambda o: len(o[3]))[3]
    body = max(occurrences, key=lambda o: len(o[4]))[4]
    mtype = collections.Counter(o[1] for o in occurrences).most_common(1)[0][0]
    candidates.append({
        "hash": h,
        "name": name,
        "type": mtype,
        "head": head,
        "body": body,
        "count": len(distinct_projects),
        "projects": distinct_projects,
    })

candidates.sort(key=lambda c: (-c["count"], c["name"]))
print(f"  {len(candidates)} unique candidate(s) at min={min_occ}")

# Compute next ID by reading the existing queue.
queue_path = pathlib.Path("governance/PROMOTION_QUEUE.md")
queue_text = queue_path.read_text() if queue_path.exists() else ""
existing_ids = re.findall(r"^## (\d+)", queue_text, re.M)
existing_hashes = re.findall(r"Source-hash:\s*(\w+)", queue_text)
next_id = max([int(i) for i in existing_ids], default=0) + 1

# Skip candidates whose hash is already in the queue.
new_candidates = [c for c in candidates if c["hash"] not in set(existing_hashes)]
print(f"  {len(new_candidates)} new (after dedup against existing queue)")

if limit > 0 and len(new_candidates) > limit:
    print(f"  capping to first {limit} (use --no-limit or --limit N to override)")
    new_candidates = new_candidates[:limit]

if dry_run:
    print()
    for c in new_candidates[:10]:
        print(f"  - [{c['count']}x] [{c['type']}] {c['name'][:60]}")
    if len(new_candidates) > 10:
        print(f"  ... and {len(new_candidates) - 10} more")
    sys.exit(0)

# Append to PROMOTION_QUEUE.md.
today = datetime.date.today().isoformat()
appended = []
for c in new_candidates:
    nid = f"{next_id:04d}"
    width = max(4, len(str(next_id)))
    nid = f"{next_id:0{width}d}"
    next_id += 1
    confidence = "high" if c["count"] >= 3 else ("medium" if c["count"] >= 2 else "low")
    target_doc = {
        "feedback":  "governance/AGENTS.md or governance/INTERACTION_STANDARDS.md",
        "user":      "governance/INTERACTION_STANDARDS.md",
        "project":   "governance/CONSTITUTION.md or docs/PLAN.md",
        "reference": "governance/AGENTS.md",
    }.get(c["type"], "governance/CONSTITUTION.md")
    if anonymize:
        source_field = f"cross-project-ingest ({c['count']} prior project(s))"
    else:
        source_field = f"cross-project-ingest ({c['count']} project(s): {', '.join(c['projects'][:3])}{' ...' if len(c['projects']) > 3 else ''})"
    block = (
        f"\n## {nid} — {c['name'][:60]}\n\n"
        f"Captured:    {today}\n"
        f"Source:      {source_field}\n"
        f"Source-hash: {c['hash']}\n"
        f"Statement:   {c['head']}\n"
        f"Type:        {c['type']}\n"
        f"Confidence:  {confidence}\n"
        f"Target doc:  {target_doc}\n"
        f"Enforceable: maybe\n"
        f"Proposed enforcement: TBD\n"
        f"Status:      candidate\n"
    )
    appended.append((nid, c['name'][:60]))
    with queue_path.open("a", encoding="utf-8") as f:
        f.write(block)

# Also append a single inbox marker so this run is visible in the inbox stream.
inbox_path = pathlib.Path("memory/inbox.md")
ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
with inbox_path.open("a", encoding="utf-8") as f:
    f.write(f"\n## {ts} — cross-project-ingest\n\n")
    f.write(f"Source:    cross-project-ingest\n")
    f.write(f"Statement: {len(appended)} candidate(s) seeded from {projects_scanned} prior project(s)\n")
    f.write(f"Context:   ran scripts/cross-project-ingest.sh (min={min_occ})\n")

print()
for nid, name in appended[:10]:
    print(f"  +#{nid} {name}")
if len(appended) > 10:
    print(f"  ... and {len(appended) - 10} more")
print()
print(f"  appended {len(appended)} candidate(s) to governance/PROMOTION_QUEUE.md")
print(f"  next: /govern promote   to walk them")
PY

ok "ingest complete"
