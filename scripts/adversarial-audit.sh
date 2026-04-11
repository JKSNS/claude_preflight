#!/usr/bin/env bash
# adversarial-audit.sh - Run the configured adversarial reviewers on a git ref.
#
# Reviewers are declared in .agent/audit-agents.yaml. Default roster:
#   codex_reviewer    — code correctness, edge cases, test adequacy (codex)
#   devil_advocate    — assumptions, requirements, hidden failure modes (ollama)
#   security_auditor  — vulnerabilities, secrets, supply chain (ollama)
#   regression_hunter — coverage gaps, behavior changes (ollama)
#
# Usage:
#   ./scripts/adversarial-audit.sh                        # audit working tree vs HEAD
#   ./scripts/adversarial-audit.sh <ref>                  # audit <ref>..HEAD
#   ./scripts/adversarial-audit.sh <base>..<head>         # audit explicit range
#   ./scripts/adversarial-audit.sh --reviewer codex <ref> # only the named reviewer
#
# Findings are written under audits/findings/open.md and audits/reports/<timestamp>.md.
# Independence rule (policy/review.rego): the author agent may not equal the
# reviewer agent for any non-doc-class change.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[audit]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "  ${RED}[ERR]${NC} $*"; }

ONLY_REVIEWER=""
RANGE=""
TRIAGE=false
# while+shift, not for+shift — `for arg in $@` doesn't notice an inner shift,
# so flag values would leak into the positional RANGE.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --reviewer) shift; ONLY_REVIEWER="${1:-}" ;;
        --reviewer=*) ONLY_REVIEWER="${1#--reviewer=}" ;;
        triage|--triage) TRIAGE=true ;;
        *) [ -z "$RANGE" ] && RANGE="$1" ;;
    esac
    shift
done

# Triage mode: walk audits/findings/open.md interactively, mark each pointer
# as accepted | rejected | false-positive | skipped. Moves accepted entries
# to audits/findings/accepted.md, rejected to rejected.md, etc.
if [ "$TRIAGE" = "true" ]; then
    if [ ! -f audits/findings/open.md ]; then
        echo "[audit] no audits/findings/open.md to triage" >&2
        exit 1
    fi
    python3 <<'PY'
import re, pathlib, sys, datetime
open_path     = pathlib.Path("audits/findings/open.md")
accepted_path = pathlib.Path("audits/findings/accepted.md")
rejected_path = pathlib.Path("audits/findings/rejected.md")
fp_path       = pathlib.Path("audits/findings/false-positives.md")
text = open_path.read_text()

# Pointers are blocks "## <TS> — <range>" until next "## ".
blocks = re.split(r"^## (?=\d{8}T)", text, flags=re.M)
header, blocks = blocks[0], blocks[1:]

remaining, accepted, rejected, fp = [], [], [], []
for b in blocks:
    title = b.splitlines()[0].strip()[:60]
    body  = b.strip()
    print(f"\n  ── #{title}")
    for line in body.splitlines()[1:6]:
        print(f"      {line}")
    print(f"      [a]ccept   [r]eject   [f]alse-positive   [s]kip   [q]uit")
    try:
        ans = input("      action: ").strip().lower()
    except EOFError:
        ans = "q"
    if ans == "q":
        remaining.append(b)
        for rest in blocks[blocks.index(b)+1:]:
            remaining.append(rest)
        print("  quit.")
        break
    if ans == "a":   accepted.append(b)
    elif ans == "r": rejected.append(b)
    elif ans == "f": fp.append(b)
    else:            remaining.append(b)

def write_back(path, blocks_list, header_line):
    if not blocks_list:
        return
    if path.exists():
        existing = path.read_text()
    else:
        existing = f"# {header_line}\n\n"
    with path.open("w") as f:
        f.write(existing.rstrip() + "\n\n")
        for b in blocks_list:
            f.write(f"## {b.lstrip()}")

# Rewrite open with what's left.
open_path.write_text(header + ("## " + "## ".join(remaining) if remaining else ""))
write_back(accepted_path, accepted, "accepted findings")
write_back(rejected_path, rejected, "rejected findings")
write_back(fp_path,       fp,       "false-positive findings")

print(f"\n  triage complete: accepted={len(accepted)} rejected={len(rejected)} false-positive={len(fp)} remaining={len(remaining)}")
PY
    exit 0
fi

EXPLICIT_RANGE="$RANGE"
if [ -z "$RANGE" ]; then
    if git diff --cached --quiet && git diff --quiet; then
        RANGE="HEAD~1..HEAD"
    else
        RANGE="HEAD"
    fi
fi

# If the user supplied an explicit ref/range, validate it before running.
if [ -n "$EXPLICIT_RANGE" ]; then
    if ! git rev-parse --verify --quiet "$EXPLICIT_RANGE" >/dev/null 2>&1 \
       && ! git rev-parse --verify --quiet "${EXPLICIT_RANGE%%..*}" >/dev/null 2>&1; then
        err "ref does not exist: $EXPLICIT_RANGE"
        exit 2
    fi
fi

OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
OLLAMA_MODEL="${ADVERSARIAL_AUDIT_MODEL:-qwen3.6:35b}"

mkdir -p audits/findings audits/reports audits/playbooks
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="audits/reports/${TS}.md"
DIFF_FILE="$(mktemp)"
trap 'rm -f "$DIFF_FILE"' EXIT

if ! git diff "$RANGE" > "$DIFF_FILE" 2>/tmp/.audit-diff-err; then
    err "git diff failed for $RANGE: $(cat /tmp/.audit-diff-err)"
    exit 2
fi
DIFF_SIZE=$(wc -c < "$DIFF_FILE")

if [ "$DIFF_SIZE" -eq 0 ]; then
    if [ -n "$EXPLICIT_RANGE" ]; then
        warn "explicit range $EXPLICIT_RANGE produced an empty diff — nothing to audit"
        exit 1
    fi
    log "no diff for $RANGE — nothing to audit"
    exit 0
fi

log "auditing $RANGE  (${DIFF_SIZE} bytes of diff)"
{
    printf "# Adversarial audit %s\n\n" "$TS"
    printf "Range: \`%s\`\n\n" "$RANGE"
    printf "Affected files:\n"
    git diff --name-only "$RANGE" | sed 's/^/- /'
    printf "\n"
} > "$REPORT"

run_codex() {
    if ! command -v codex >/dev/null 2>&1; then
        warn "codex CLI not found — skipping codex_reviewer"
        return 0
    fi
    log "codex_reviewer"
    {
        printf "## codex_reviewer\n\n"
        cat "$DIFF_FILE" | codex review --quiet 2>&1 || true
        printf "\n"
    } >> "$REPORT"
    ok "codex_reviewer recorded"
}

run_ollama() {
    local name="$1" prompt_path="$2"
    if ! curl -sf -o /dev/null "${OLLAMA_HOST}/api/tags"; then
        warn "ollama unreachable at ${OLLAMA_HOST} — skipping $name"
        return 0
    fi
    local prompt
    if [ -f "$prompt_path" ]; then
        prompt="$(cat "$prompt_path")"
    else
        prompt="You are the ${name//_/ }. Review the following diff. For each finding emit: severity (low|medium|high|critical), confidence, evidence (file:line), recommended fix, and whether it should become a task, risk, test, policy, or amendment."
    fi
    log "$name (ollama:$OLLAMA_MODEL)"
    local body
    body="$(python3 -c "
import json, sys
prompt = sys.argv[1]
diff = open(sys.argv[2]).read()
print(json.dumps({
    'model': '$OLLAMA_MODEL',
    'stream': False,
    'prompt': prompt + '\n\n--- DIFF ---\n' + diff
}))
" "$prompt" "$DIFF_FILE")"
    local response
    response="$(curl -sf -X POST "${OLLAMA_HOST}/api/generate" -d "$body" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('response',''))" 2>/dev/null || true)"
    {
        printf "## %s\n\n" "$name"
        if [ -n "$response" ]; then
            printf "%s\n\n" "$response"
        else
            printf "_no response from ollama_\n\n"
        fi
    } >> "$REPORT"
    ok "$name recorded"
}

want_reviewer() {
    [ -z "$ONLY_REVIEWER" ] && return 0
    [ "$1" = "$ONLY_REVIEWER" ]
}

# Read the roster from .agent/audit-agents.yaml when present so the YAML
# is no longer aspirational. Each entry yields: name, type (codex|ollama),
# model (ollama only), and prompt path. Fall back to the hardcoded roster
# when the YAML is missing or unparseable, so existing projects keep working.
ROSTER_FILE=".agent/audit-agents.yaml"
ROSTER=""
if [ -f "$ROSTER_FILE" ] && command -v python3 >/dev/null 2>&1; then
    ROSTER="$(python3 - "$ROSTER_FILE" <<'PY' 2>/dev/null
import sys, re, pathlib

# Indent-based YAML walker. Avoids PyYAML and avoids the regex-based
# multiline trap (a previous version's `^([a-z]+):\s*$((?:...)+)` pattern
# silently matched zero entries because $-anchor + ((?:...)+) doesn't
# behave the way it looks in re.M mode).
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()

# Find the audit_agents: block and its body until dedent.
in_section = False
section_indent = None
entries = {}            # name -> { "type": "...", "model": "...", "prompt": "..." }
current = None
current_indent = None
in_invocation = False

for line in lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)

    if not in_section:
        if line.rstrip() == "audit_agents:":
            in_section = True
        continue

    # Blank or comment lines don't change state.
    if not stripped or stripped.startswith("#"):
        continue

    # If we're back at column 0 with a top-level key, the section ended.
    if indent == 0:
        break

    # Per-reviewer block: "  <name>:" at indent 2.
    m = re.match(r"^([a-z_][a-z0-9_]*):\s*$", stripped)
    if m and indent == 2:
        current = m.group(1)
        entries.setdefault(current, {})
        in_invocation = False
        continue

    if current is None:
        continue

    # invocation: subblock.
    if re.match(r"^invocation:\s*$", stripped) and indent == 4:
        in_invocation = True
        continue

    # Top-level under invocation:
    if in_invocation and indent == 6:
        kv = re.match(r"^([a-z_]+):\s*(.+?)\s*$", stripped)
        if kv:
            entries[current][kv.group(1)] = kv.group(2)
        continue

    # Anything indented less than the invocation block but inside the
    # reviewer block — leaving invocation but staying in reviewer.
    if indent <= 4:
        in_invocation = False

# Emit roster. One line per reviewer: name<TAB>type<TAB>model<TAB>prompt.
for name, props in entries.items():
    typ    = props.get("type", "ollama")
    model  = props.get("model", "")
    prompt = props.get("prompt", f"audits/playbooks/{name.replace('_','-')}.md")
    if "/" not in prompt:
        prompt = f"audits/playbooks/{prompt}"
    print(f"{name}\t{typ}\t{model}\t{prompt}")
PY
)"
fi

if [ -z "$ROSTER" ]; then
    # Fallback when YAML missing or empty.
    ROSTER="codex_reviewer	codex
devil_advocate	ollama	$OLLAMA_MODEL	audits/playbooks/devil-advocate.md
security_auditor	ollama	$OLLAMA_MODEL	audits/playbooks/security-auditor.md
regression_hunter	ollama	$OLLAMA_MODEL	audits/playbooks/regression-hunter.md"
fi

# Iterate the roster.
while IFS=$'\t' read -r name typ model prompt; do
    [ -z "$name" ] && continue
    want_reviewer "$name" || continue
    case "$typ" in
        codex)  run_codex ;;
        ollama)
            # Per-role model override; fall back to ADVERSARIAL_AUDIT_MODEL.
            ROLE_MODEL="${model:-$OLLAMA_MODEL}"
            ADVERSARIAL_AUDIT_MODEL="$ROLE_MODEL" run_ollama "$name" "$prompt"
            ;;
        *) warn "unknown reviewer type '$typ' for $name — skipping" ;;
    esac
done <<< "$ROSTER"

# Append a pointer into open findings so triage is single-pass.
{
    printf "\n## %s — %s\n\n" "$TS" "$RANGE"
    printf "Report: \`%s\`\n" "$REPORT"
    printf "Status: open (triage required)\n"
} >> audits/findings/open.md

log "report: $REPORT"
log "open findings: audits/findings/open.md"
