#!/usr/bin/env bash
# council.sh - LLM Council for high-stakes decisions and project brainstorming.
#
# Three stages, eleven model calls:
#   1. Five cognitive lenses (Contrarian / First Principles / Expansionist /
#      Outsider / Executor) respond to the same question, in parallel.
#   2. Five reviewers see the five responses anonymized as A-E (randomized
#      mapping) and answer: strongest / biggest blind spot / what did all
#      five miss.
#   3. Chairman synthesizes everything into Where-Council-Agrees /
#      Where-It-Clashes / Blind-Spots / Recommendation / One-Thing-First /
#      LOG-TO routing for governance.
#
# Reserved for: final outputs and project brainstorming. NOT for every dev
# iteration — the existing scripts/adversarial-audit.sh handles iterative
# code review.
#
# Two run modes:
#
#   --via agent    (DEFAULT)
#                  Script stages all 11 prompts to disk and exits with
#                  per-stage instructions. The running agent dispatches each
#                  prompt via its own Agent / subagent mechanism (Claude,
#                  Codex, whatever the agent IS). The agent writes responses
#                  back to the staged paths, then re-invokes the script
#                  for the next stage. This is the right default — uses the
#                  intelligence the user is already paying for AND gets
#                  real subagent isolation for anonymization.
#
#   --via ollama:<model>
#                  Headless mode. Script makes all 11 calls itself via
#                  curl + Ollama. For cron, CI, scripted use. Single-model
#                  council — chairman synthesis tags this as a confidence
#                  limitation.
#
#   --via codex
#                  Headless mode using Codex CLI for each call.
#
# Usage:
#   ./scripts/council.sh decide "<question>" [--via <mode>] [--leaning "<X>"] [--context <file>]
#   ./scripts/council.sh continue <stage> <session-dir>     # agent-mode handoff
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

CMD="${1:-}"; shift || true

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[council]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "  ${RED}[ERR]${NC} $*"; }

playbook_dir() {
    for c in audits/playbooks/council \
             governance/templates/audits/playbooks/council \
             "${PREFLIGHT_HOME:-/tmp/claude_preflight}/governance/templates/audits/playbooks/council"; do
        [ -d "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

cmd_decide() {
    local question=""
    local context_file=""
    local user_leaning=""
    local via="agent"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --context)   shift; context_file="${1:-}" ;;
            --context=*) context_file="${1#--context=}" ;;
            --leaning)   shift; user_leaning="${1:-}" ;;
            --leaning=*) user_leaning="${1#--leaning=}" ;;
            --via)       shift; via="${1:-agent}" ;;
            --via=*)     via="${1#--via=}" ;;
            *) [ -z "$question" ] && question="$1" ;;
        esac
        shift
    done

    if [ "$question" = "-" ]; then
        question="$(cat)"
    fi

    if [ -z "$question" ]; then
        echo "council: 'decide' requires a question" >&2
        exit 2
    fi

    # Refuse validation seeking — the council is theater on a decided question.
    # This is the floor; the agent (caller) must enforce the contextual cases
    # (where the user telegraphed their preferred answer in prior turns).
    if echo "$question" | grep -qiE "^(am i right|validate|confirm) (that |my |this )" ; then
        cat <<EOF
[council] this looks like validation-seeking, not decision support.
          The council finds blind spots and tradeoffs; you've framed
          a question that asks for agreement instead. Reframe as a
          neutral question (e.g. "should I do X or Y, given Z context")
          and re-run.
EOF
        exit 1
    fi

    local pb_dir; pb_dir="$(playbook_dir)"
    if [ -z "$pb_dir" ]; then
        err "no council playbook directory found"
        exit 2
    fi

    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local out_dir="governance/councils/${ts}"
    mkdir -p "$out_dir/prompts"

    # Build the project context that every lens sees.
    local context_payload=""
    if [ -f .agent/project-ingest.md ]; then
        context_payload="## Project context (from .agent/project-ingest.md, head)
$(head -200 .agent/project-ingest.md)
"
    elif [ -f CLAUDE.md ]; then
        context_payload="## Project context (CLAUDE.md head)
$(head -150 CLAUDE.md)
"
    fi
    if [ -n "$context_file" ] && [ -f "$context_file" ]; then
        context_payload="${context_payload}

## Additional context (from $context_file)
$(head -200 "$context_file")
"
    fi

    # Per-lens directive: only the Contrarian gets the explicit anti-position
    # when --leaning is set. The other four stay balanced.
    contrarian_directive=""
    other_lens_directive=""
    if [ -n "$user_leaning" ]; then
        contrarian_directive="

## User's stated leaning

The user is currently leaning toward: ${user_leaning}

Your job is to assume this leaning is wrong. Find every reason it fails.
"
        other_lens_directive="

## Context: user's stated leaning

The user is currently leaning toward: ${user_leaning}

Assess on the merits. The Contrarian is taking the explicit anti-position; you do not need to oppose for opposition's sake. Stay balanced.
"
    fi

    # Save the question + context.
    {
        echo "# Council question — $ts"
        echo ""
        echo "Run mode: --via $via"
        if [ -n "$user_leaning" ]; then
            echo "User's stated leaning: $user_leaning"
        fi
        echo ""
        echo "## Question"
        echo ""
        echo "$question"
        echo ""
        if [ -n "$context_payload" ]; then
            echo "$context_payload"
        fi
    } > "$out_dir/question.md"

    # Stage 1 prompt files — one per lens.
    log "stage 1 prompts → $out_dir/prompts/"
    local lenses="contrarian first-principles expansionist outsider executor"
    for lens in $lenses; do
        local pb="$pb_dir/${lens}.md"
        if [ ! -f "$pb" ]; then
            warn "no playbook for $lens — skipped"
            continue
        fi
        local lens_specific=""
        if [ "$lens" = "contrarian" ]; then
            lens_specific="$contrarian_directive"
        else
            lens_specific="$other_lens_directive"
        fi
        {
            cat "$pb"
            echo ""
            if [ -n "$lens_specific" ]; then echo "$lens_specific"; fi
            echo "---"
            echo ""
            echo "## Question for the council"
            echo ""
            echo "$question"
            echo ""
            if [ -n "$context_payload" ]; then echo "$context_payload"; fi
        } > "$out_dir/prompts/stage1-${lens}.md"
    done
    ok "stage 1 prompts written"

    # Save meta.json.
    cat > "$out_dir/meta.json" <<META
{
  "timestamp": "${ts}",
  "question_first_line": "$(echo "$question" | head -1 | head -c 100 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')",
  "via": "${via}",
  "user_leaning": "$(echo "$user_leaning" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])')",
  "stages": ["lens-responses", "peer-review", "chairman-synthesis"],
  "lenses": ["contrarian", "first-principles", "expansionist", "outsider", "executor"],
  "current_stage": 1
}
META

    case "$via" in
        agent)
            cat <<EOF

[council] stage 1 staged. The agent dispatches now.

  AGENT, DO THIS:

  Spawn 5 subagents in parallel (Agent tool, one call per lens). Each
  subagent gets the prompt from one of these files, and you collect the
  responses into the matching stage1-{lens}.md output:

$(for lens in $lenses; do
    echo "    prompt:   $out_dir/prompts/stage1-${lens}.md"
    echo "    response: $out_dir/stage1-${lens}.md"
done)

  Each subagent's response should be 150-300 words. Save the verbatim
  response text (no preamble) to the response file.

  When all 5 are written, run:
      $0 continue 2 $out_dir
EOF
            ;;
        ollama:*)
            local model="${via#ollama:}"
            run_ollama_stage1 "$out_dir" "$model" "$lenses"
            log "stage 1 done; advancing to stage 2"
            cmd_continue 2 "$out_dir" --via "$via"
            ;;
        codex)
            err "--via codex not yet implemented in headless mode"
            exit 2
            ;;
        *)
            err "unknown --via mode: $via"
            exit 2
            ;;
    esac
}

# Headless ollama dispatcher (single-model council).
run_ollama_stage1() {
    local out_dir="$1" model="$2" lenses="$3"
    local OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
    if ! curl -sf -o /dev/null "${OLLAMA_HOST}/api/tags" 2>/dev/null; then
        err "ollama unreachable at $OLLAMA_HOST"
        exit 3
    fi
    log "stage 1 via ollama:$model — 5 lenses in parallel"
    local pids=()
    for lens in $lenses; do
        (
            local prompt; prompt="$(cat "$out_dir/prompts/stage1-${lens}.md")"
            local body; body="$(python3 -c "
import json, sys
print(json.dumps({'model': '$model', 'prompt': sys.stdin.read(), 'stream': False, 'options': {'temperature': 0.7, 'num_predict': 800}}))
" <<< "$prompt")"
            local response
            response="$(curl -sf -X POST "${OLLAMA_HOST}/api/generate" -d "$body" 2>/dev/null \
                | python3 -c "import json,sys; print(json.load(sys.stdin).get('response', '(no response)'))" 2>/dev/null \
                || echo "(ollama call failed for $lens)")"
            echo "$response" > "$out_dir/stage1-${lens}.md"
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    ok "stage 1 done"
}

cmd_continue() {
    local stage="${1:-}" out_dir="${2:-}"
    shift 2 || true
    local via="agent"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --via) shift; via="${1:-agent}" ;;
            --via=*) via="${1#--via=}" ;;
        esac
        shift
    done
    [ -z "$stage" ] || [ -z "$out_dir" ] && { echo "usage: $0 continue <2|3> <session-dir>" >&2; exit 2; }
    [ -d "$out_dir" ] || { err "no such session: $out_dir"; exit 2; }

    case "$stage" in
        2) cmd_stage2 "$out_dir" "$via" ;;
        3) cmd_stage3 "$out_dir" "$via" ;;
        *) err "stage must be 2 or 3"; exit 2 ;;
    esac
}

cmd_stage2() {
    local out_dir="$1" via="$2"
    local pb_dir; pb_dir="$(playbook_dir)"

    # Verify all 5 stage-1 responses exist.
    local lenses="contrarian first-principles expansionist outsider executor"
    for lens in $lenses; do
        if [ ! -f "$out_dir/stage1-${lens}.md" ]; then
            err "missing stage 1 response: stage1-${lens}.md"
            exit 2
        fi
    done

    # Build the A-E mapping with a randomized assignment.
    python3 - "$out_dir" <<'PY' > "$out_dir/.anon-map.json"
import json, random, sys, pathlib
out_dir = sys.argv[1]
lenses = ["contrarian", "first-principles", "expansionist", "outsider", "executor"]
shuffled = lenses[:]; random.shuffle(shuffled)
labels = ["A", "B", "C", "D", "E"]
mapping = dict(zip(labels, shuffled))   # label -> lens
print(json.dumps({"label_to_lens": mapping}))
PY

    # Build the peer-review prompt with anonymized responses.
    local peer_pb="$pb_dir/peer-review.md"
    local question
    question="$(awk '
        /^## Question$/   { in_q=1; next }
        /^## / && in_q    { exit }
        in_q              { print }
    ' "$out_dir/question.md" | sed '/./,$!d' | sed -e :a -e '/^$/{$d;N;ba' -e '}')"

    local peer_template; peer_template="$(cat "$peer_pb")"
    local letters=("A" "B" "C" "D" "E")
    local responses=()
    for letter in "${letters[@]}"; do
        local lens
        lens="$(python3 -c "import json; print(json.load(open('$out_dir/.anon-map.json'))['label_to_lens']['$letter'])")"
        responses+=("$(cat "$out_dir/stage1-${lens}.md")")
    done

    local peer_prompt="$peer_template"
    peer_prompt="${peer_prompt//\{\{QUESTION\}\}/$question}"
    peer_prompt="${peer_prompt//\{\{RESPONSE_A\}\}/${responses[0]}}"
    peer_prompt="${peer_prompt//\{\{RESPONSE_B\}\}/${responses[1]}}"
    peer_prompt="${peer_prompt//\{\{RESPONSE_C\}\}/${responses[2]}}"
    peer_prompt="${peer_prompt//\{\{RESPONSE_D\}\}/${responses[3]}}"
    peer_prompt="${peer_prompt//\{\{RESPONSE_E\}\}/${responses[4]}}"

    # Save the same prompt for each reviewer.
    for r in 1 2 3 4 5; do
        echo "$peer_prompt" > "$out_dir/prompts/stage2-reviewer-${r}.md"
    done

    case "$via" in
        agent)
            cat <<EOF

[council] stage 2 staged. The agent dispatches now.

  AGENT, DO THIS:

  Spawn 5 reviewer subagents in parallel. Each gets the same anonymized
  peer-review prompt. Save each reviewer's response to the matching file:

$(for r in 1 2 3 4 5; do
    echo "    prompt:   $out_dir/prompts/stage2-reviewer-${r}.md"
    echo "    response: $out_dir/stage2-reviewer-${r}.md"
done)

  When all 5 are written, run:
      $0 continue 3 $out_dir
EOF
            ;;
        ollama:*)
            local model="${via#ollama:}"
            local OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
            log "stage 2 via ollama:$model — 5 reviewers in parallel"
            local rpids=()
            for r in 1 2 3 4 5; do
                (
                    local body; body="$(python3 -c "
import json, sys
print(json.dumps({'model': '$model', 'prompt': sys.stdin.read(), 'stream': False, 'options': {'temperature': 0.5, 'num_predict': 600}}))
" <<< "$peer_prompt")"
                    curl -sf -X POST "${OLLAMA_HOST}/api/generate" -d "$body" 2>/dev/null \
                        | python3 -c "import json,sys; print(json.load(sys.stdin).get('response', '(no response)'))" 2>/dev/null \
                        > "$out_dir/stage2-reviewer-${r}.md" \
                        || echo "(ollama call failed)" > "$out_dir/stage2-reviewer-${r}.md"
                ) &
                rpids+=($!)
            done
            for pid in "${rpids[@]}"; do wait "$pid"; done
            cmd_continue 3 "$out_dir" --via "$via"
            ;;
    esac
}

cmd_stage3() {
    local out_dir="$1" via="$2"
    local pb_dir; pb_dir="$(playbook_dir)"

    # Verify all 5 stage-2 reviews exist.
    for r in 1 2 3 4 5; do
        if [ ! -f "$out_dir/stage2-reviewer-${r}.md" ]; then
            err "missing stage 2 reviewer: stage2-reviewer-${r}.md"
            exit 2
        fi
    done

    # Build consolidated peer-review file with the de-anonymization mapping.
    {
        echo "# Stage 2 — anonymized peer review"
        echo ""
        echo "De-anonymized mapping:"
        python3 -c "
import json
m = json.load(open('$out_dir/.anon-map.json'))['label_to_lens']
for k, v in sorted(m.items()):
    print(f'  - {k}: {v}')
"
        echo ""
        for r in 1 2 3 4 5; do
            echo "## Reviewer $r"; echo ""
            cat "$out_dir/stage2-reviewer-${r}.md"; echo ""
        done
    } > "$out_dir/stage2-peer-review.md"

    local question
    question="$(awk '
        /^## Question$/   { in_q=1; next }
        /^## / && in_q    { exit }
        in_q              { print }
    ' "$out_dir/question.md" | sed '/./,$!d' | sed -e :a -e '/^$/{$d;N;ba' -e '}')"

    local chair_pb="$pb_dir/chairman.md"
    local chair_template; chair_template="$(cat "$chair_pb")"
    local r_contrarian r_first r_exp r_out r_exec peer_text
    r_contrarian="$(cat "$out_dir/stage1-contrarian.md")"
    r_first="$(cat "$out_dir/stage1-first-principles.md")"
    r_exp="$(cat "$out_dir/stage1-expansionist.md")"
    r_out="$(cat "$out_dir/stage1-outsider.md")"
    r_exec="$(cat "$out_dir/stage1-executor.md")"
    peer_text="$(cat "$out_dir/stage2-peer-review.md")"

    local chair_prompt="$chair_template"
    chair_prompt="${chair_prompt//\{\{QUESTION\}\}/$question}"
    chair_prompt="${chair_prompt//\{\{RESPONSE_CONTRARIAN\}\}/$r_contrarian}"
    chair_prompt="${chair_prompt//\{\{RESPONSE_FIRST_PRINCIPLES\}\}/$r_first}"
    chair_prompt="${chair_prompt//\{\{RESPONSE_EXPANSIONIST\}\}/$r_exp}"
    chair_prompt="${chair_prompt//\{\{RESPONSE_OUTSIDER\}\}/$r_out}"
    chair_prompt="${chair_prompt//\{\{RESPONSE_EXECUTOR\}\}/$r_exec}"
    chair_prompt="${chair_prompt//\{\{PEER_REVIEWS\}\}/$peer_text}"

    echo "$chair_prompt" > "$out_dir/prompts/stage3-chairman.md"

    case "$via" in
        agent)
            cat <<EOF

[council] stage 3 staged. The agent runs the chairman now.

  AGENT, DO THIS:

  Run the chairman (one Agent subagent call). Use this prompt:
      prompt:   $out_dir/prompts/stage3-chairman.md

  Save the chairman's verbatim response to:
      response: $out_dir/stage3-synthesis.md

  Then read the LOG TO line at the bottom of the synthesis. If it says
  'idea_log', auto-log the verdict via:
      ./scripts/idea-log.sh capture "Council verdict: <question>" \\
          --title "council: <short>" --synthesis "<recommendation>"

  Otherwise, surface the synthesis to the user with:
    - the recommendation
    - the one thing to do first
    - the LOG TO routing decision
EOF
            ;;
        ollama:*)
            local model="${via#ollama:}"
            local OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
            log "stage 3 chairman via ollama:$model"
            local body; body="$(python3 -c "
import json, sys
print(json.dumps({'model': '$model', 'prompt': sys.stdin.read(), 'stream': False, 'options': {'temperature': 0.4, 'num_predict': 1200}}))
" <<< "$chair_prompt")"
            curl -sf -X POST "${OLLAMA_HOST}/api/generate" -d "$body" 2>/dev/null \
                | python3 -c "import json,sys; print(json.load(sys.stdin).get('response', '(no response)'))" 2>/dev/null \
                > "$out_dir/stage3-synthesis.md" \
                || echo "(chairman ollama call failed)" > "$out_dir/stage3-synthesis.md"

            local log_to
            log_to="$(grep -m1 -oE '^LOG TO: \w+' "$out_dir/stage3-synthesis.md" | awk '{print $3}' || echo "")"
            if [ "$log_to" = "idea_log" ] && [ -x scripts/idea-log.sh ]; then
                ./scripts/idea-log.sh capture "Council verdict: $(echo "$question" | head -c 200)" \
                    --title "council verdict" \
                    --context "$out_dir/stage3-synthesis.md" \
                    --synthesis "$(grep -A1 -m1 '## The recommendation' "$out_dir/stage3-synthesis.md" | tail -1 | head -c 300)" \
                    >/dev/null 2>&1 || true
                ok "verdict logged to governance/idea_log.md"
            fi
            ok "council complete — synthesis at $out_dir/stage3-synthesis.md"
            ;;
    esac
}

case "$CMD" in
    decide)   cmd_decide   "$@" ;;
    continue) cmd_continue "$@" ;;
    *)
        cat <<EOF
Usage: $0 decide "<question>" [--via agent|ollama:<model>|codex] [--leaning "<X>"] [--context <file>]
       $0 continue <2|3> <session-dir>

--via agent    (DEFAULT) Stage prompts to disk; running agent dispatches via
               its own subagent mechanism (Claude / whatever you're using).
--via ollama:<model>
               Headless. Script makes all 11 calls itself. Single-model.
--via codex    Headless via Codex CLI (not yet implemented).

Reserved for final outputs and project brainstorming. For iterative dev
audits use scripts/adversarial-audit.sh instead.
EOF
        exit 2
        ;;
esac
