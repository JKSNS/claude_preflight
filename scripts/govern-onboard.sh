#!/usr/bin/env bash
# govern-onboard.sh - Bootstrap a project's governance from a 20-question intake.
#
# Two modes:
#
#   --interactive   Walk the question bank with the user, write answers into
#                   a YAML answer-file, then run a templating pass that fills
#                   CONSTITUTION.md / AGENTS.md / INTERACTION_STANDARDS.md /
#                   ANTI_PATTERNS.md / .agent/project-tier.yaml from those
#                   answers. Called by /govern onboard.
#
#   --autonomous    Print the question bank with each question's autonomous
#                   default value derived where possible (manifest detection,
#                   cross-project memory, etc.). Intended to be read by an
#                   agent that then asks only the open questions.
#
# Either way, the human ratifies the final docs before they are committed.
#
# Usage:
#   ./scripts/govern-onboard.sh                              # alias for --interactive
#   ./scripts/govern-onboard.sh --autonomous                 # emit defaults
#   ./scripts/govern-onboard.sh --answers <path>             # consume answer YAML
#   ./scripts/govern-onboard.sh --apply <answer-yaml>        # write canonical docs
#
# Question bank lives at governance/onboarding/questions.md (in the bundle) or
# (after install) at $PREFLIGHT_HOME/governance/onboarding/questions.md.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

MODE="interactive"
ANSWERS=""
APPLY=""
TIER=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --interactive) MODE="interactive" ;;
        --autonomous)  MODE="autonomous" ;;
        --answers) shift; ANSWERS="${1:-}" ;;
        --answers=*) ANSWERS="${1#--answers=}" ;;
        --apply) shift; APPLY="${1:-}" ;;
        --apply=*) APPLY="${1#--apply=}" ;;
        --tier) shift; TIER="${1:-}" ;;
        --tier=*) TIER="${1#--tier=}" ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
    shift
done

# Detect tier from .agent/project-tier.yaml if not passed.
if [ -z "$TIER" ] && [ -f .agent/project-tier.yaml ]; then
    TIER="$(awk -F': *' '/^tier:/ {print $2; exit}' .agent/project-tier.yaml | tr -d '"' | tr -d ' ')"
fi
[ -z "$TIER" ] && TIER="1"

# Question subset per tier — fewer questions for smaller projects. Tier 1+
# always asks Q14 (required reviewers) because governance-init installs the
# review-gate artifacts at tier 1+; skipping Q14 there leaves them undefined.
case "$TIER" in
    0) QUESTIONS_FOR_TIER="Q1 Q4 Q12 Q18 Q20" ;;
    1) QUESTIONS_FOR_TIER="Q1 Q2 Q3 Q4 Q7 Q9 Q10 Q11 Q12 Q13 Q14 Q15 Q18" ;;
    2) QUESTIONS_FOR_TIER="Q1 Q2 Q3 Q4 Q5 Q6 Q7 Q9 Q10 Q11 Q12 Q13 Q14 Q15 Q18 Q19" ;;
    3) QUESTIONS_FOR_TIER="all" ;;
    *) QUESTIONS_FOR_TIER="all" ;;
esac

# Locate the question bank.
locate_questions() {
    local candidates=(
        "governance/onboarding/questions.md"
        "${PREFLIGHT_HOME:-}/governance/onboarding/questions.md"
        "${HOME}/.claude/preflight-bundle/governance/onboarding/questions.md"
        "/tmp/claude_preflight/governance/onboarding/questions.md"
        "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../governance/onboarding/questions.md"
    )
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

QBANK="$(locate_questions)"
if [ -z "$QBANK" ]; then
    echo "govern-onboard: cannot locate questions.md" >&2
    exit 2
fi

# Detect baseline values from the repo.
detect_languages() {
    local langs=()
    [ -f package.json ]         && langs+=("javascript")
    [ -f tsconfig.json ]        && langs+=("typescript")
    [ -f pyproject.toml ]       && langs+=("python")
    [ -f requirements.txt ]     && langs+=("python")
    [ -f Cargo.toml ]           && langs+=("rust")
    [ -f go.mod ]               && langs+=("go")
    [ -f Gemfile ]              && langs+=("ruby")
    [ -f composer.json ]        && langs+=("php")
    [ -f mix.exs ]              && langs+=("elixir")
    if [ "${#langs[@]}" -eq 0 ]; then
        # Fallback: count by extension.
        find . -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" -o -name "*.rs" \) 2>/dev/null \
            | head -200 \
            | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -3 | awk '{print $2}' | tr '\n' ',' | sed 's/,$//'
    else
        IFS=,; echo "${langs[*]}"
    fi
}

detect_deploy_target() {
    [ -f Dockerfile ]                           && { echo "container"; return; }
    [ -d .github/workflows ] && grep -q -r 'deploy' .github/workflows/ 2>/dev/null && { echo "ci-driven"; return; }
    [ -d terraform ] || [ -d infra ]            && { echo "infra-as-code"; return; }
    [ -f vercel.json ] || [ -f netlify.toml ]   && { echo "static-host"; return; }
    echo "none"
}

detect_default_branch() {
    git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || \
        git branch --show-current 2>/dev/null || echo "main"
}

detect_has_ci() {
    [ -d .github/workflows ] || [ -f .gitlab-ci.yml ] || [ -f .circleci/config.yml ] && echo "true" || echo "false"
}

detect_has_secrets() {
    # Bound the search: skip vendored / cached / vcs-internal trees that can
    # bloat find by orders of magnitude in real repos.
    if find . -maxdepth 3 \
        \( -path './node_modules' -o -path './venv' -o -path './.venv' \
           -o -path './.git' -o -path './target' -o -path './dist' \
           -o -path './build' -o -path './.next' -o -path './graphify-out' \) -prune \
        -o -type f \( -name ".env" -o -name ".env.*" -o -name "credentials*" \
           -o -name "secrets*" -o -name "*.pem" -o -name "*.key" \
           -o -name "*.pfx" -o -name "*.p12" \) -print 2>/dev/null | head -1 | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

emit_autonomous_defaults() {
    cat <<EOF
# Autonomous onboarding defaults
# Derived from the repo for a $(basename "$PROJECT_DIR") project.
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ).

project:
  dir: $PROJECT_DIR
  name: $(basename "$PROJECT_DIR")
  tier: $TIER

derived:
  languages: $(detect_languages)
  default_branch: $(detect_default_branch)
  deploy_target: $(detect_deploy_target)
  has_ci: $(detect_has_ci)
  has_secret_files: $(detect_has_secrets)
  has_dockerfile: $([ -f Dockerfile ] && echo true || echo false)
  has_existing_governance: $([ -f governance/CONSTITUTION.md ] && echo true || echo false)

# Tier-driven question filter. The agent should ask exactly these questions
# in interactive mode (matching what govern-onboard --interactive would walk).
questions_for_tier: "$QUESTIONS_FOR_TIER"

# These need explicit human confirmation regardless of inference.
ask_human:
  - Q12_forbidden_behaviors
  - Q18_recurring_frustrations
  - Q19_past_incidents

# These are answerable with high confidence from the repo.
inferred:
  - Q1_one_line_purpose       # from README
  - Q7_languages_frameworks   # from manifests
  - Q8_build_test_lint        # from Makefile / scripts
  - Q9_deploy_target          # from Dockerfile / CI / IaC
  - Q13_change_landing        # from default branch + protection
  - Q15_ci_gates              # from CI yaml

# Run cross-project-ingest --dry-run before asking Q11, Q12, Q16, Q18.
suggested_pre_steps:
  - "./scripts/cross-project-ingest.sh --dry-run --min 2"
EOF
}

run_interactive() {
    if [ ! -f "$QBANK" ]; then
        echo "no question bank at $QBANK" >&2
        exit 2
    fi

    OUT="${ANSWERS:-.agent/onboarding-answers.yaml}"
    mkdir -p "$(dirname "$OUT")"

    NUM_QUESTIONS="$(echo "$QUESTIONS_FOR_TIER" | wc -w)"
    [ "$QUESTIONS_FOR_TIER" = "all" ] && NUM_QUESTIONS=20
    cat <<EOF
This will walk a $NUM_QUESTIONS-question intake (tier $TIER) and write your answers to:
  $OUT

You can quit at any time (Ctrl-C); answers so far are preserved. After the
run, use --apply to fill the canonical docs from those answers, or pass them
to /govern onboard for the agent to apply.

Skip a question with an empty answer to accept the default.

EOF

    : > "$OUT"
    echo "# onboarding answers — $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
    echo "project_dir: $PROJECT_DIR" >> "$OUT"
    echo "tier: $TIER" >> "$OUT"
    echo "answers:" >> "$OUT"

    # Walk the question bank, extracting Qn blocks and asking each.
    python3 - "$QBANK" "$OUT" "$QUESTIONS_FOR_TIER" <<'PY'
import sys, re, pathlib
qbank = pathlib.Path(sys.argv[1]).read_text()
out_path = pathlib.Path(sys.argv[2])
question_filter = sys.argv[3].split() if sys.argv[3] != "all" else None

# Match "### Q<N> — <title>" + the next block until the next "### " or section break.
blocks = re.findall(r"^### (Q\d+) — ([^\n]+)\n((?:(?!^### )(?!^## )[\s\S])*)", qbank, re.M)

for qid, title, body in blocks:
    if question_filter is not None and qid not in question_filter:
        continue
    # Extract prompt + default + landing from the body.
    prompt_m = re.search(r"\*\*prompt\*\*:\s*(.+)", body)
    default_m = re.search(r"\*\*default\*\*:\s*(.+)", body)
    landing_m = re.search(r"\*\*landing\*\*:\s*(.+)", body)
    prompt = prompt_m.group(1).strip() if prompt_m else title
    default = default_m.group(1).strip() if default_m else ""
    landing = landing_m.group(1).strip() if landing_m else ""

    print()
    print(f"  [{qid}] {title.strip()}")
    print(f"        {prompt}")
    if default:
        print(f"        default: {default}")
    try:
        ans = input("        > ").strip()
    except EOFError:
        ans = ""
    if not ans:
        ans = f"(default: {default})" if default else "(skipped)"
    with out_path.open("a") as f:
        # Quote multiline / colon-containing answers.
        if "\n" in ans or ":" in ans or "#" in ans:
            esc = ans.replace('"', '\\"').replace("\n", "\\n")
            f.write(f'  {qid}: "{esc}"\n')
        else:
            f.write(f"  {qid}: {ans}\n")
        f.write(f"  {qid}_landing: {landing}\n")

print()
print(f"  answers written to {out_path}")
PY

    echo ""
    echo "  Next: ./scripts/govern-onboard.sh --apply $OUT"
}

apply_answers() {
    local src="$1"
    [ -f "$src" ] || { echo "answer file not found: $src" >&2; exit 2; }

    # Apply works by appending each answered question as a candidate row in
    # PROMOTION_QUEUE.md. The agent can then walk them via /govern promote
    # and decide where each belongs (which canonical doc, with what wording).
    # We DON'T mail-merge into doctrine files — paragraphs deserve a real
    # per-project rewrite, not template substitution.
    [ -f governance/PROMOTION_QUEUE.md ] || {
        echo "no governance/PROMOTION_QUEUE.md — run governance-init.sh first" >&2
        exit 2
    }

    python3 - "$src" <<'PY'
import sys, re, pathlib, datetime
src = pathlib.Path(sys.argv[1]).read_text()
queue = pathlib.Path("governance/PROMOTION_QUEUE.md")
queue_text = queue.read_text()

# Find next ID.
ids = re.findall(r"^## (\d+) ", queue_text, re.M)
next_id = max([int(i) for i in ids], default=0) + 1

# Pull "  Q<N>: value" lines; landing comes from the matching "Q<N>_landing:".
answers = dict(re.findall(r"^\s+(Q\d+(?:_landing)?):\s*(.+?)\s*$", src, re.M))
today = datetime.date.today().isoformat()

appended = 0
with queue.open("a", encoding="utf-8") as f:
    for k, v in sorted(answers.items()):
        if k.endswith("_landing"):
            continue
        if v.startswith("(default:") or v == "(skipped)":
            continue
        landing = answers.get(f"{k}_landing", "TBD")
        nid = f"{next_id:04d}"
        next_id += 1
        f.write(f"\n## {nid} — onboarding answer {k}\n\n")
        f.write(f"Captured:    {today}\n")
        f.write(f"Source:      govern-onboard --apply\n")
        f.write(f"Statement:   {v}\n")
        f.write(f"Type:        TBD\n")
        f.write(f"Confidence:  high\n")
        f.write(f"Target doc:  {landing}\n")
        f.write(f"Enforceable: maybe\n")
        f.write(f"Proposed enforcement: TBD\n")
        f.write(f"Status:      candidate\n")
        appended += 1

print(f"  appended {appended} candidate(s) to governance/PROMOTION_QUEUE.md")
print(f"  next:  /govern promote   to walk them")
PY
}

case "$MODE" in
    autonomous)
        emit_autonomous_defaults
        ;;
    interactive)
        if [ -n "$APPLY" ]; then
            apply_answers "$APPLY"
        else
            run_interactive
        fi
        ;;
esac
