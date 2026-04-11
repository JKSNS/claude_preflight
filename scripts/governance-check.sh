#!/usr/bin/env bash
# governance-check.sh - Audit the governance state of the current project.
#
# Verifies that the artifacts required by the declared tier exist, that
# `policy-map.md` rows match real enforcement files, that `memory/inbox.md`
# is not accumulating un-promoted items, that templates have been customized
# (placeholder text removed), that standard docs are not stale relative to
# code, and that policy tests pass.
#
# Usage:
#   ./scripts/governance-check.sh                # human-readable report
#   ./scripts/governance-check.sh --format json  # machine-readable for CI
#
# Exit code:
#   0  all checks passed
#   1  one or more checks failed (governance defect)
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

FORMAT="text"
for arg in "$@"; do
    case "$arg" in
        --format) shift; FORMAT="${1:-text}" ;;
        --format=*) FORMAT="${arg#--format=}" ;;
        --json) FORMAT="json" ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# JSON mode: collect findings into a tempfile (more reliable than a bash array
# across redirects + subshells), suppress decorative output, emit at end.
FINDINGS_FILE=""
if [ "$FORMAT" = "json" ]; then
    FINDINGS_FILE="$(mktemp)"
    trap 'rm -f "$FINDINGS_FILE"' EXIT
    pass() { printf 'ok\t%s\n' "$1" >> "$FINDINGS_FILE"; }
    fail() { printf 'fail\t%s\n' "$1" >> "$FINDINGS_FILE"; FAILURES=$((FAILURES + 1)); }
    warn() { printf 'warn\t%s\n' "$1" >> "$FINDINGS_FILE"; WARNINGS=$((WARNINGS + 1)); }
    sect() { printf 'section\t%s\n' "$1" >> "$FINDINGS_FILE"; }
else
    pass() { echo -e "  ${GREEN}[OK]${NC} $1"; }
    fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
    warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
    sect() { echo ""; echo -e "${BOLD}$1${NC}"; }
fi

FAILURES=0
WARNINGS=0
INBOX_STALE_DAYS="${GOVERN_INBOX_STALE_DAYS:-7}"

if [ "$FORMAT" != "json" ]; then
    echo ""
    echo "Governance Check"
    echo ""
else
    # JSON mode: suppress all decorative + inline-python stdout. We restore
    # stdout right before emitting the final JSON object.
    exec 3>&1 1>/dev/null 2>/dev/null
fi

# tier + required artifacts
sect "Tier and required artifacts"

# Bundle self-check: when run inside the claude_preflight bundle's own
# tree (recognized by the source layout: governance/templates/ + scripts/
# + skills/), this file is the source of governance, not a project that
# uses governance. Skip the project-required checks so a `governance-check`
# in the bundle dev tree doesn't spuriously fail.
if [ -d governance/templates ] && [ -d skills/govern ] && [ ! -f .agent/project-tier.yaml ]; then
    pass "bundle source tree detected — project checks not applicable here"
    pass "(run governance-check inside a project that's been governance-init'd)"
    exit 0
fi

if [ ! -f .agent/project-tier.yaml ]; then
    fail "no .agent/project-tier.yaml — run scripts/governance-init.sh"
else
    TIER="$(awk -F': *' '/^tier:/ {print $2; exit}' .agent/project-tier.yaml | tr -d '"' | tr -d ' ')"
    [ -z "$TIER" ] && TIER="0"
    pass "declared tier: $TIER"

    declare -a REQUIRED
    case "$TIER" in
        # Tier 0 is the doctrine-only baseline. Must match what
        # governance-init.sh actually installs at tier 0 (CONSTITUTION + AGENTS
        # + memory inbox/index + .agent/project-tier.yaml). GOVERNANCE.md is
        # tier 1+; requiring it here was a drift bug fixed in 0.7.1.
        0) REQUIRED=(governance/CONSTITUTION.md governance/AGENTS.md memory/inbox.md memory/index.md .agent/project-tier.yaml) ;;
        1) REQUIRED=(governance/CONSTITUTION.md governance/GOVERNANCE.md governance/AGENTS.md governance/INTERACTION_STANDARDS.md governance/ANTI_PATTERNS.md governance/PROJECT_MEMORY_CONTRACT.md governance/PROMOTION_QUEUE.md governance/policy-map.md policy memory/inbox.md memory/index.md) ;;
        2) REQUIRED=(governance/CONSTITUTION.md governance/GOVERNANCE.md governance/AGENTS.md governance/INTERACTION_STANDARDS.md governance/ANTI_PATTERNS.md governance/PROJECT_MEMORY_CONTRACT.md governance/PROMOTION_QUEUE.md governance/policy-map.md policy/secrets.rego policy/dependencies.rego policy/git.rego policy/review.rego policy/tests memory/inbox.md memory/index.md) ;;
        3) REQUIRED=(governance/CONSTITUTION.md governance/GOVERNANCE.md governance/AGENTS.md governance/INTERACTION_STANDARDS.md governance/ANTI_PATTERNS.md governance/PROJECT_MEMORY_CONTRACT.md governance/PROMOTION_QUEUE.md governance/policy-map.md policy/secrets.rego policy/dependencies.rego policy/git.rego policy/review.rego policy/deployment.rego policy/tests .agent/audit-agents.yaml .agent/review-gates.yaml governance/amendments memory/inbox.md memory/index.md) ;;
        *) warn "unknown tier '$TIER' — applying tier 1 baseline"
           REQUIRED=(governance/CONSTITUTION.md governance/GOVERNANCE.md governance/AGENTS.md memory/inbox.md memory/index.md) ;;
    esac

    for r in "${REQUIRED[@]}"; do
        if [ -e "$r" ]; then
            pass "$r"
        else
            fail "$r missing"
        fi
    done
fi

# policy-map.md vs reality
sect "policy-map.md ↔ enforcement"

if [ ! -f governance/policy-map.md ]; then
    warn "no governance/policy-map.md to validate"
else
    python3 - <<'PY'
import re, os, pathlib, sys
path = pathlib.Path("governance/policy-map.md")
text = path.read_text()

rows = []
for line in text.splitlines():
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 6:
        continue
    if cells[0].lower() in ("rule", "---") or set(cells[0]) <= {"-"}:
        continue
    rows.append(cells)

failures = 0
warnings = 0

for r in rows:
    rule, source, doc, mem, enforced_by, status = r[:6]
    status_l = status.lower()
    if status_l == "enforced":
        # Check that the enforcement target exists.
        targets = [t.strip() for t in re.split(r"\+|,", enforced_by) if t.strip()]
        any_failed = False
        for t in targets:
            t_clean = re.sub(r"`", "", t)
            t_clean = t_clean.split("(")[0].strip()
            # Hooks are installed globally to ~/.claude/hooks/, not in the
            # project tree; check both locations.
            if t_clean.startswith("hooks/"):
                hook_name = t_clean[len("hooks/"):]
                if not (pathlib.Path(t_clean).exists() or
                        pathlib.Path(f"{os.path.expanduser('~/.claude/hooks')}/{hook_name}").exists()):
                    print(f"  [FAIL] enforced rule '{rule[:60]}' points at missing {t_clean}")
                    failures += 1
                    any_failed = True
            elif t_clean.startswith(("policy/", "scripts/", "ci/")):
                if not pathlib.Path(t_clean).exists():
                    print(f"  [FAIL] enforced rule '{rule[:60]}' points at missing {t_clean}")
                    failures += 1
                    any_failed = True
            elif t_clean == "manual":
                continue
        if not any_failed:
            print(f"  [OK]   enforced: {rule[:60]}")
    elif status_l in ("prose-only", "proposed", "partial", "todo"):
        # Rule of law: a rule that exists in doctrine but isn't actually
        # enforced by code is a rationalization vector. A future agent can
        # talk itself out of it. The bundle's whole point is to make this
        # impossible — so we FAIL on these statuses, not warn.
        #
        # Only `prose-only-acknowledged` is an accepted non-enforced state:
        # the human has explicitly ratified that this rule will live as
        # prose forever and accepted the rationalization risk.
        print(f"  [FAIL] {status_l} (rule-of-law violation): {rule[:60]}")
        print(f"         Doctrine includes this rule but no code enforces it.")
        print(f"         Either land enforcement in policy/, hooks/, scripts/, or ci/,")
        print(f"         or change Status to 'prose-only-acknowledged' if you accept the risk.")
        failures += 1
    elif status_l == "prose-only-acknowledged":
        print(f"  [WARN] prose-only-acknowledged: {rule[:60]}  (explicit human waiver)")
        warnings += 1
    else:
        print(f"  [FAIL] unknown status '{status}' for: {rule[:60]}")
        failures += 1

if failures:
    sys.exit(2)
if warnings:
    sys.exit(3)
PY
    rc=$?
    if [ "$rc" -eq 2 ]; then FAILURES=$((FAILURES + 1)); fi
    if [ "$rc" -eq 3 ]; then WARNINGS=$((WARNINGS + 1)); fi
fi

# rule-of-law audit: doctrine → policy-map sync
sect "Doctrine ↔ policy-map sync (rule-of-law audit)"

if [ -f governance/policy-map.md ]; then
    UNMAPPED=$(python3 - <<'PY'
import re, pathlib

# Sources of binding doctrine that an agent should not be able to ignore.
sources = [
    "governance/CONSTITUTION.md",
    "governance/AGENTS.md",
    "governance/ANTI_PATTERNS.md",
    "CLAUDE.md",
]

# Extract policy-map rules (column 0).
pm = pathlib.Path("governance/policy-map.md").read_text()
mapped = set()
for line in pm.splitlines():
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 6 or cells[0].lower() in ("rule", "---") or set(cells[0]) <= {"-"}:
        continue
    # Normalize for fuzzy comparison.
    norm = re.sub(r"\s+", " ", cells[0].lower()).strip().rstrip(".!?:")
    mapped.add(norm)

# Walk doctrine sources for directive-shaped lines.
unmapped = []
for src in sources:
    p = pathlib.Path(src)
    if not p.exists():
        continue
    for i, line in enumerate(p.read_text().splitlines(), 1):
        # A directive looks like a bulleted/numbered line containing at
        # least one strong-modal word.
        if not re.match(r"^[\s]*([-*+]|\d+\.)", line):
            continue
        if not re.search(r"\b(MUST|NEVER|ALWAYS|forbidden|required|P0|golden rule|mandate|may not|shall not)\b", line, re.I):
            continue
        # Strip leading bullet/number, the modal pretext, etc.
        text = re.sub(r"^[\s]*([-*+]|\d+\.)\s*", "", line).strip()
        # Crude norm: lowercase, collapse whitespace, drop trailing punct.
        norm = re.sub(r"\s+", " ", text.lower()).strip().rstrip(".!?:")
        # Match any policy-map rule whose words substantially overlap.
        # Requires that all 3+ char words from the policy-map rule appear in
        # the doctrine line, OR vice versa.
        matched = False
        for pm_norm in mapped:
            pm_words = set(w for w in re.findall(r"\w+", pm_norm) if len(w) > 3)
            doc_words = set(w for w in re.findall(r"\w+", norm) if len(w) > 3)
            if not pm_words or not doc_words:
                continue
            overlap = len(pm_words & doc_words)
            # Loose: at least 3 words shared OR 60%+ of the smaller set.
            if overlap >= 3 or (min(len(pm_words), len(doc_words)) > 0 and
                                overlap / min(len(pm_words), len(doc_words)) >= 0.6):
                matched = True
                break
        if not matched:
            unmapped.append(f"{src}:{i}  {text[:90]}")

# Limit output so a noisy doctrine doesn't drown the report.
for u in unmapped[:15]:
    print(u)
print(f"---TOTAL---{len(unmapped)}")
PY
)
    UNMAPPED_COUNT=$(echo "$UNMAPPED" | grep -oE '^---TOTAL---[0-9]+' | sed 's/---TOTAL---//' || echo 0)
    if [ -z "$UNMAPPED_COUNT" ] || [ "$UNMAPPED_COUNT" = "0" ]; then
        pass "every doctrine directive maps to a policy-map.md row"
    else
        fail "$UNMAPPED_COUNT doctrine directive(s) not represented in policy-map.md (rule-of-law gap):"
        echo "$UNMAPPED" | grep -v "^---TOTAL---" | sed 's/^/         /'
        if [ "$UNMAPPED_COUNT" -gt 15 ]; then
            echo "         (showing first 15 of $UNMAPPED_COUNT)"
        fi
        echo "         Each entry must either get a policy-map row (with enforced status)"
        echo "         or be removed from doctrine."
    fi
fi

# inbox staleness
sect "Memory inbox"

if [ -f memory/inbox.md ]; then
    # Real entries written by memory-promote.sh start with "## YYYY-MM-DD ".
    ENTRIES=$(grep -cE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}' memory/inbox.md 2>/dev/null || true)
    ENTRIES=${ENTRIES:-0}
    if [ "$ENTRIES" -eq 0 ]; then
        pass "inbox empty"
    else
        AGE_DAYS=$(python3 -c "import os, time; print(int((time.time() - os.path.getmtime('memory/inbox.md'))/86400))" 2>/dev/null || echo 0)
        if [ "$AGE_DAYS" -gt "$INBOX_STALE_DAYS" ]; then
            fail "$ENTRIES inbox entries; oldest mtime is ${AGE_DAYS}d (threshold ${INBOX_STALE_DAYS}d) — promote or reject"
        else
            warn "$ENTRIES inbox entries pending promotion"
        fi
    fi
else
    warn "no memory/inbox.md"
fi

# promotion queue
sect "Promotion queue"

if [ -f governance/PROMOTION_QUEUE.md ]; then
    # A real candidate row is "Status:<spaces>candidate" with no trailing alternatives.
    PENDING=$(grep -cE '^Status: +candidate[[:space:]]*$' governance/PROMOTION_QUEUE.md 2>/dev/null || true)
    PENDING=${PENDING:-0}
    if [ "$PENDING" -gt 0 ]; then
        warn "$PENDING candidate(s) in PROMOTION_QUEUE.md awaiting promotion"
    else
        pass "no pending candidates"
    fi

    # Age-out: a candidate older than GOVERN_CANDIDATE_STALE_DAYS that is still
    # in 'candidate' state is a workflow defect — promote, reject, or extend.
    STALE_DAYS="${GOVERN_CANDIDATE_STALE_DAYS:-90}"
    OLD_CANDIDATES=$(python3 - "$STALE_DAYS" <<'PY'
import re, sys, datetime, pathlib
days = int(sys.argv[1])
text = pathlib.Path("governance/PROMOTION_QUEUE.md").read_text()
blocks = re.split(r"^## (?=\d+ )", text, flags=re.M)[1:]
now = datetime.date.today()
old = []
for b in blocks:
    if not re.search(r"^Status:\s*candidate\s*$", b, re.M):
        continue
    m = re.search(r"^Captured:\s*(\d{4}-\d{2}-\d{2})", b, re.M)
    if not m:
        continue
    try:
        d = datetime.date.fromisoformat(m.group(1))
    except Exception:
        continue
    if (now - d).days > days:
        title = b.splitlines()[0].strip()[:60]
        old.append(f"#{title} ({(now - d).days}d old)")
for o in old:
    print(o)
PY
)
    if [ -n "$OLD_CANDIDATES" ]; then
        warn "candidate(s) older than ${STALE_DAYS}d (promote, reject, or extend):"
        echo "$OLD_CANDIDATES" | sed 's/^/         /'
    fi

    # Duplicate detection: PROJECT_MEMORY_CONTRACT requires a hard fail when the
    # same durable instruction is captured twice. We normalize Statement values
    # (lowercase, collapse whitespace, drop trailing punctuation) and look for
    # repeats among rows that are still candidate or already promoted.
    DUPES=$(python3 - <<'PY'
import re, pathlib, collections, sys
text = pathlib.Path("governance/PROMOTION_QUEUE.md").read_text()
blocks = re.split(r"^## (?=\d{4})", text, flags=re.M)[1:]
norm = collections.Counter()
for b in blocks:
    m_stmt = re.search(r"^Statement:\s*(.+)$", b, re.M)
    if not m_stmt:
        continue
    s = m_stmt.group(1).strip().lower()
    s = re.sub(r"\s+", " ", s)
    s = s.rstrip(".!?:; ")
    norm[s] += 1
dupes = [(s, n) for s, n in norm.items() if n > 1]
for s, n in dupes:
    print(f"{n}\t{s[:80]}")
sys.exit(0 if not dupes else 1)
PY
)
    if [ -n "$DUPES" ]; then
        fail "duplicate durable instruction(s) captured (PROJECT_MEMORY_CONTRACT defect):"
        echo "$DUPES" | sed 's/^/         /'
    else
        pass "no duplicate captures"
    fi
fi

# pretooluse gate registration
sect "Policy gate hook"

if [ -f "$HOME/.claude/settings.json" ]; then
    HOOK_REGISTERED=$(python3 -c "
import json
try:
    s = json.load(open('$HOME/.claude/settings.json'))
    pre = s.get('hooks', {}).get('PreToolUse', [])
    found = False
    for entry in pre:
        for h in entry.get('hooks', []):
            if 'pre-tool-policy-gate.sh' in h.get('command', ''):
                found = True
    print('yes' if found else 'no')
except Exception:
    print('no')
" 2>/dev/null)
    if [ "$HOOK_REGISTERED" = "yes" ]; then
        pass "pre-tool-policy-gate.sh is registered in PreToolUse"
    else
        warn "pre-tool-policy-gate.sh NOT registered in ~/.claude/settings.json — policies are not enforced at action time"
        echo "         Fix: re-run /preflight install (registers PreToolUse * hook)"
    fi
else
    warn "no ~/.claude/settings.json — policy gate cannot be registered"
fi

# policy tests
sect "Policy tests"

if [ ! -d policy ]; then
    warn "no policy/ directory"
elif command -v opa >/dev/null 2>&1; then
    if opa test policy/ >/tmp/.opa-test.log 2>&1; then
        SUMMARY=$(tail -3 /tmp/.opa-test.log | head -1)
        pass "opa test passed — $SUMMARY"
    else
        fail "opa test failed — see /tmp/.opa-test.log"
    fi
else
    warn "opa binary not installed — install: https://www.openpolicyagent.org/docs/latest/#running-opa"
fi

# architecture drift (basic)
sect "Architecture drift"

if [ -f governance/CONSTITUTION.md ] || [ -f docs/ARCHITECTURE.md ]; then
    DRIFT_FILE=""
    [ -f docs/ARCHITECTURE.md ] && DRIFT_FILE="docs/ARCHITECTURE.md"
    [ -z "$DRIFT_FILE" ] && [ -f ARCHITECTURE.md ] && DRIFT_FILE="ARCHITECTURE.md"
    if [ -n "$DRIFT_FILE" ]; then
        # Look for backtick-quoted relative paths and check existence.
        MISSING=$(grep -oE '`[a-zA-Z0-9_./-]+/[a-zA-Z0-9_./-]+`' "$DRIFT_FILE" 2>/dev/null | tr -d '`' | sort -u | while read -r p; do
            [ -e "$p" ] || echo "$p"
        done | head -10)
        if [ -n "$MISSING" ]; then
            warn "architecture references paths that no longer exist:"
            echo "$MISSING" | sed 's/^/         /'
        else
            pass "architecture path references resolve"
        fi
    else
        pass "no architecture doc to validate"
    fi
fi

# placeholder detection
sect "Template placeholders"

PLACEHOLDER_FILES=$(grep -rln -E "(> Replace this section|> Replace this stub|<YYYY-MM-DD|<short name>|TBD$)" \
    governance/ docs/ STATUS.md PLAN.md 2>/dev/null | head -10 || true)
if [ -n "$PLACEHOLDER_FILES" ]; then
    warn "files still contain template placeholders:"
    echo "$PLACEHOLDER_FILES" | sed 's/^/         /'
else
    pass "no untouched template placeholders detected"
fi

# council usage check
sect "Council usage"

if [ -d governance/councils ]; then
    COUNCIL_RECENT=$(find governance/councils -maxdepth 1 -type d -name "20*" -mtime -7 2>/dev/null | wc -l)
    if [ "$COUNCIL_RECENT" -gt 3 ]; then
        warn "$COUNCIL_RECENT councils run in the last 7 days — high-stakes tool, expensive (11 model calls each)"
        warn "if you're using council on small decisions, you're using it as procrastination"
    elif [ "$COUNCIL_RECENT" -gt 0 ]; then
        pass "$COUNCIL_RECENT council(s) in the last 7 days — appropriate cadence"
    fi
fi

# sync daemon health (folded from /govern doctor concept)
sect "Sync daemon"

if [ -x scripts/sync-health.sh ]; then
    SYNC_OUT="$(scripts/sync-health.sh 2>&1 | head -3)"
    case "$SYNC_OUT" in
        *running*) pass "$(echo "$SYNC_OUT" | head -1 | sed 's/^[[:space:]]*//')" ;;
        *crashed*) fail "$(echo "$SYNC_OUT" | head -1 | sed 's/^[[:space:]]*//')" ;;
        *stopped*) warn "sync daemon stopped (./scripts/sync-health.sh --restart to start)" ;;
        *)         pass "no sync daemon (no graphify-out yet)" ;;
    esac
fi

# model routing health
sect "Model routing"

if [ -x scripts/model-profile.sh ]; then
    MODEL_OK=$(scripts/model-profile.sh check 2>&1 | grep -c "\[OK\]" || true)
    MODEL_OK=${MODEL_OK:-0}
    if [ "$MODEL_OK" -gt 0 ]; then
        pass "model profile applied; required Ollama model(s) available"
    else
        warn "model profile check did not find required Ollama model — run ./scripts/model-profile.sh check"
    fi
fi

# stale standard docs
sect "Standard-doc staleness"

STALE_DOC_DAYS="${GOVERN_DOC_STALE_DAYS:-60}"
LAST_COMMIT_TS=$(git log -1 --format=%at 2>/dev/null || echo 0)
for doc in STATUS.md PLAN.md docs/ARCHITECTURE.md docs/RISKS.md docs/THREAT_MODEL.md; do
    [ -f "$doc" ] || continue
    DOC_MTIME=$(stat -c %Y "$doc" 2>/dev/null || echo 0)
    AGE_DAYS=$(( (LAST_COMMIT_TS - DOC_MTIME) / 86400 ))
    if [ "$AGE_DAYS" -gt "$STALE_DOC_DAYS" ]; then
        warn "$doc is ${AGE_DAYS}d behind the last commit (threshold ${STALE_DOC_DAYS}d)"
    fi
done

# summary
if [ "$FORMAT" = "json" ]; then
    # Restore real stdout (suppressed during checks).
    exec 1>&3 3>&-
    python3 - "$FAILURES" "$WARNINGS" "$FINDINGS_FILE" <<'PY'
import json, sys, pathlib
failures = int(sys.argv[1]); warnings = int(sys.argv[2])
findings_file = sys.argv[3]
findings = []
if findings_file and pathlib.Path(findings_file).exists():
    for raw in pathlib.Path(findings_file).read_text().splitlines():
        if not raw or "\t" not in raw:
            continue
        level, msg = raw.split("\t", 1)
        findings.append({"level": level, "message": msg})
print(json.dumps({
    "failures": failures,
    "warnings": warnings,
    "pass": failures == 0,
    "findings": findings,
}, indent=2))
PY
    [ "$FAILURES" -gt 0 ] && exit 1 || exit 0
fi

# Auto-regenerate the context pack so the next agent session starts on the
# freshest doctrine + memory + status snapshot. Quiet — the pack's own log
# would clutter the check output. Skip silently if the script is missing.
if [ -x scripts/context-pack.sh ]; then
    ./scripts/context-pack.sh --quiet >/dev/null 2>&1 || true
fi

echo ""

if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}Governance OK.${NC}"
    exit 0
elif [ "$FAILURES" -eq 0 ]; then
    echo -e "${YELLOW}Governance OK with $WARNINGS warning(s).${NC}"
    exit 0
else
    echo -e "${RED}Governance defect: $FAILURES failure(s), $WARNINGS warning(s).${NC}"
    exit 1
fi
