#!/usr/bin/env bash
# session-synthesize.sh - Continuously distill session signal into governance.
#
# Triggered at three high-value moments:
#   1. PreCompact hook (Claude Code)        — capture themes before context loss
#   2. graphify post-commit / post-checkout — capture themes when graph rebuilds
#   3. Manual:  /govern synthesize          — on demand
#
# What it does:
#   1. Reads this project's auto-memory at ~/.claude/projects/<slug>/memory/
#   2. Reads the current promotion-queue + already-active memory pointers
#   3. Asks Ollama (or a configured local model) to identify themes that are
#      not yet captured: security inclinations, methodology preferences,
#      recurring frustrations, conventions surfaced repeatedly
#   4. Emits each theme as a candidate row in governance/PROMOTION_QUEUE.md,
#      idempotent via a synthesis-hash that survives across runs
#
# This is the "the constitution grows continuously" piece. The human ratifies
# via /govern promote.
#
# Usage:
#   ./scripts/session-synthesize.sh                 # synthesize now
#   ./scripts/session-synthesize.sh --dry-run       # report only
#   ./scripts/session-synthesize.sh --quiet         # no stdout (for hook use)
#   ./scripts/session-synthesize.sh --since 7d      # only memory newer than N
#
# Env:
#   OLLAMA_HOST                 Default: http://host.docker.internal:11434
#   SESSION_SYNTHESIS_MODEL     Default: qwen3.6:35b
#   SESSION_SYNTHESIS_DISABLE   If set to 1, exits 0 without doing anything
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

DRY_RUN=false
QUIET=false
SINCE="30d"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --quiet)   QUIET=true ;;
        --since)   shift; SINCE="${1:-30d}" ;;
        --since=*) SINCE="${1#--since=}" ;;
    esac
    shift
done

if [ "${SESSION_SYNTHESIS_DISABLE:-0}" = "1" ]; then
    [ "$QUIET" = false ] && echo "session-synthesize: disabled via SESSION_SYNTHESIS_DISABLE=1"
    exit 0
fi

# This project must have been governance-init'd.
if [ ! -f governance/PROMOTION_QUEUE.md ] || [ ! -f memory/inbox.md ]; then
    [ "$QUIET" = false ] && echo "session-synthesize: project is not governance-init'd; skipping"
    exit 0
fi

# Rate limit: skip if we ran in the last N seconds. Default 30min so a long
# session does not flood the queue (and Ollama) with PreCompact-triggered runs.
# The timestamp is written AFTER a successful synthesis (at the end of the
# script) — writing it here would suppress retries for 30min if Ollama crashes
# mid-call, losing the synthesis opportunity entirely.
MIN_INTERVAL="${SESSION_SYNTHESIS_MIN_INTERVAL:-1800}"
LAST_RUN_FILE=".agent/.last-synthesis"
if [ -f "$LAST_RUN_FILE" ]; then
    LAST="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
    NOW="$(date +%s)"
    AGE=$((NOW - LAST))
    if [ "$AGE" -lt "$MIN_INTERVAL" ]; then
        [ "$QUIET" = false ] && echo "session-synthesize: ran ${AGE}s ago (<${MIN_INTERVAL}s); skipping"
        exit 0
    fi
fi
mkdir -p .agent

OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
MODEL="${SESSION_SYNTHESIS_MODEL:-qwen3.6:35b}"

if ! curl -sf -o /dev/null "${OLLAMA_HOST}/api/tags" 2>/dev/null; then
    [ "$QUIET" = false ] && echo "session-synthesize: ollama unreachable at $OLLAMA_HOST; skipping"
    exit 0
fi

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { [ "$QUIET" = true ] || echo -e "${CYAN}[synthesize]${NC} $*"; }
ok()  { [ "$QUIET" = true ] || echo -e "  ${GREEN}[OK]${NC} $*"; }

# Same slug scheme as cross-project-ingest: "-" + path[1:].replace("/", "-").
# /home/foo  →  -home-foo
PROJECT_SLUG="-$(echo "${PROJECT_DIR#/}" | sed 's|/|-|g')"
MEMORY_DIR="${HOME}/.claude/projects/${PROJECT_SLUG}/memory"

if [ ! -d "$MEMORY_DIR" ]; then
    log "no auto-memory directory at $MEMORY_DIR — nothing to synthesize"
    exit 0
fi

log "model=$MODEL  memory=$MEMORY_DIR  since=$SINCE"

python3 - "$MEMORY_DIR" "$OLLAMA_HOST" "$MODEL" "$SINCE" "$DRY_RUN" <<'PY'
import sys, os, re, json, hashlib, datetime, pathlib, urllib.request, urllib.error

memory_dir, ollama_host, model, since, dry_run_str = sys.argv[1:6]
dry_run = dry_run_str == "true"

# Compute time threshold from --since.
m = re.match(r"^(\d+)([dhm])$", since)
if not m:
    print(f"  invalid --since: {since}", file=sys.stderr)
    sys.exit(2)
n = int(m.group(1))
unit = m.group(2)
seconds = n * {"d": 86400, "h": 3600, "m": 60}[unit]
threshold = datetime.datetime.now().timestamp() - seconds

mem_root = pathlib.Path(memory_dir)
parts = []
for f in sorted(mem_root.glob("*.md")):
    if f.name == "MEMORY.md":
        continue
    try:
        if f.stat().st_mtime < threshold:
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        continue
    parts.append(f"### {f.name}\n{text.strip()}\n")

if not parts:
    print("  no recent memory entries within --since window")
    sys.exit(0)

corpus = "\n".join(parts)
if len(corpus) > 24000:
    corpus = corpus[:24000] + "\n...[truncated]"

prompt = f"""You are reading this user's auto-memory for a single project. Identify recurring themes that should become durable governance rules but are not yet captured.

A theme is durable if any of the following are true:
- The user repeatedly expresses the same preference, constraint, or frustration.
- The same anti-pattern shows up across multiple memory entries.
- A consistent methodology or convention is implicit but never written down explicitly.
- A specific risk or sensitivity (security, financial, data) keeps surfacing.

For each theme you identify, output a single JSON object on its own line. Do NOT wrap in a list. Do NOT emit anything else. Each object:

{{"name": "<short-slug>", "type": "rule|preference|workflow|security|architecture|operational", "statement": "<one-sentence durable rule>", "rationale": "<why this is the rule>", "evidence": "<which memory entries it came from>", "confidence": "high|medium|low"}}

Emit at most 8 themes. Skip themes that are too narrow to be a project-wide rule. If the memory contains no durable themes, output an empty response.

--- MEMORY ---
{corpus}
"""

req = urllib.request.Request(
    f"{ollama_host}/api/generate",
    data=json.dumps({"model": model, "prompt": prompt, "stream": False}).encode(),
    headers={"Content-Type": "application/json"},
)
try:
    # Timeout intentionally below the PreCompact hook's `timeout 60` wrapper
    # so urlopen returns cleanly rather than getting SIGKILL'd mid-call.
    with urllib.request.urlopen(req, timeout=50) as resp:
        body = json.load(resp)
        response_text = body.get("response", "")
except urllib.error.URLError as e:
    print(f"  ollama call failed: {e}", file=sys.stderr)
    sys.exit(0)
except Exception as e:
    print(f"  ollama call error: {e}", file=sys.stderr)
    sys.exit(0)

# Strip markdown code fences if the model wrapped its output in ```json...```.
response_text = re.sub(r"^```\w*\s*\n", "", response_text, flags=re.M)
response_text = re.sub(r"\n```\s*$", "", response_text, flags=re.M)

# Parse JSONL out of the model response. Accept lines that look like JSON
# objects; ignore prose/commentary the model adds around them.
themes = []
for line in response_text.splitlines():
    line = line.strip()
    if not (line.startswith("{") and line.endswith("}")):
        continue
    try:
        obj = json.loads(line)
        if "statement" in obj and "name" in obj:
            themes.append(obj)
    except Exception:
        continue

if not themes:
    print("  model returned no parseable themes")
    sys.exit(0)

print(f"  {len(themes)} theme(s) identified")

queue_path = pathlib.Path("governance/PROMOTION_QUEUE.md")
queue_text = queue_path.read_text() if queue_path.exists() else ""
existing_hashes = set(re.findall(r"Source-hash:\s*(\w+)", queue_text))
existing_ids = re.findall(r"^## (\d+)", queue_text, re.M)
next_id = max([int(i) for i in existing_ids], default=0) + 1

today = datetime.date.today().isoformat()
appended = []

for t in themes:
    norm = re.sub(r"\s+", " ", t["statement"].lower()).rstrip(".!?:; ")
    h = hashlib.sha256(norm.encode()).hexdigest()[:12]
    if h in existing_hashes:
        continue
    width = max(4, len(str(next_id)))
    nid = f"{next_id:0{width}d}"
    next_id += 1
    block = (
        f"\n## {nid} — {t['name'][:60]}\n\n"
        f"Captured:    {today}\n"
        f"Source:      session-synthesize ({model})\n"
        f"Source-hash: {h}\n"
        f"Statement:   {t['statement']}\n"
        f"Rationale:   {t.get('rationale', '')}\n"
        f"Evidence:    {t.get('evidence', '')}\n"
        f"Type:        {t.get('type', 'TBD')}\n"
        f"Confidence:  {t.get('confidence', 'low')}\n"
        f"Target doc:  TBD\n"
        f"Enforceable: maybe\n"
        f"Proposed enforcement: TBD\n"
        f"Status:      candidate\n"
    )
    appended.append((nid, t["name"][:60], t.get("confidence", "low")))
    if not dry_run:
        with queue_path.open("a", encoding="utf-8") as f:
            f.write(block)

if not dry_run and appended:
    inbox_path = pathlib.Path("memory/inbox.md")
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    with inbox_path.open("a", encoding="utf-8") as f:
        f.write(f"\n## {ts} — session-synthesize\n\n")
        f.write(f"Source:    session-synthesize\n")
        f.write(f"Statement: {len(appended)} theme(s) seeded by {model}\n")
        f.write(f"Context:   ran scripts/session-synthesize.sh --since {since}\n")

if appended:
    for nid, name, conf in appended:
        print(f"  +#{nid} [{conf}] {name}")
    if dry_run:
        print(f"  (dry-run: nothing written)")
    else:
        print(f"  appended {len(appended)} candidate(s) to governance/PROMOTION_QUEUE.md")
else:
    print(f"  no new themes (all {len(themes)} already in queue)")
PY
SYNTH_RC=$?

# Stamp the rate-limit clock only on a successful run so a crashed Ollama
# call doesn't suppress retries for 30 minutes.
if [ "$SYNTH_RC" -eq 0 ]; then
    date +%s > "$LAST_RUN_FILE"
fi

ok "synthesis complete"
