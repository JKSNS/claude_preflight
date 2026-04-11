#!/usr/bin/env bash
# preflight.sh - Validate environment before Claude Code session.
# Run at the start of every session to ensure zero-waste configuration.
set -euo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# help
if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo ""
    echo -e "${BOLD}claude_preflight${NC} — Per-project Claude Code optimization toolkit."
    echo ""
    echo -e "${BOLD}Claude Code commands:${NC}"
    echo "  /preflight              Full check and setup (prompts before each modifying step)"
    echo "  /preflight --yes        All-in-one without prompting"
    echo "  /preflight check        Read-only validation, no changes"
    echo "  /preflight install      Install scripts + graphify + persistence + cron"
    echo "  /preflight uninstall    Project-aware removal (cron + startup + .bashrc)"
    echo "  /preflight sync         Start / status / restart the graphify sync daemon"
    echo "  /preflight cleanup      Staleness scan (--legacy-shuffle for the old reorg)"
    echo "  /preflight update       Pull latest from upstream (per-file diff before overwrite)"
    echo "  /preflight soft-refs    Generate overviews for large excluded dirs"
    echo "  /preflight govern       Scaffold the agentic governance layer"
    echo "  /preflight model        Show / apply / check the model routing config"
    echo "  /preflight fresh        Purge + reinstall (captures state to archive/ first)"
    echo ""
    echo -e "${BOLD}Shell commands:${NC}"
    echo "  ./scripts/preflight.sh           Run environment checks"
    echo "  ./scripts/model-profile.sh       Manage model profiles"
    echo "  ./scripts/self-update.sh         Pull latest & reinstall"
    echo "  ./scripts/soft-references.sh     Generate soft reference overviews"
    echo "  ./scripts/graphify-sync.sh       Run or start sync daemon"
    echo "  ./scripts/graphify-rebuild.sh    Full graph rebuild"
    echo "  ./scripts/staleness-scan.sh      Find stale / unreferenced files"
    echo ""
    echo -e "${BOLD}Knowledge graph queries (in Claude Code):${NC}"
    echo "  \"How does classify route to specialists?\"   — onboarding, architecture"
    echo "  \"Which auto_* helpers duplicate logic?\"     — refactoring analysis"
    echo "  \"What breaks if I change ModelConfig?\"      — impact analysis on god nodes"
    echo "  \"Show the data flow from input to output\"   — tracing pipelines"
    echo "  \"What communities does KrakenState bridge?\" — cross-module coupling"
    echo ""
    echo -e "${BOLD}Updating an existing install:${NC}"
    echo "  ./scripts/self-update.sh --check    Check for upstream updates"
    echo "  ./scripts/self-update.sh            Pull latest & overwrite all scripts"
    echo "  /preflight update                   Same, from inside Claude Code"
    echo ""
    echo "  self-update pulls the latest repo, re-runs install.sh --force,"
    echo "  which overwrites all scripts, hooks, profiles, and the SKILL.md."
    echo "  Your .graphifyignore and graph data are preserved."
    echo ""
    echo -e "${BOLD}Docs:${NC}"
    echo "  README.md               Full documentation"
    echo "  GRAPHIFY.md             Knowledge graph reference"
    echo "  graphify-out/           Graph outputs (GRAPH_REPORT.md, SOFT_REFERENCES.md)"
    echo ""
    exit 0
fi

pass() { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

FAILURES=0

echo ""

echo "Claude Code Preflight Checklist"
echo ""

# ollama
echo "Ollama Model Stack"
OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"
MODEL_COUNT=$(curl -sf "${OLLAMA}/api/tags" 2>/dev/null \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin)['models']))" 2>/dev/null || echo 0)

if [ "$MODEL_COUNT" -gt 0 ]; then
    pass "Ollama reachable at $OLLAMA ($MODEL_COUNT models)"
else
    fail "Ollama not reachable at $OLLAMA"
fi

# Check critical models
REQUIRED_MODELS="qwen3.6:35b"
if [ "$MODEL_COUNT" -gt 0 ]; then
    AVAILABLE=$(curl -sf "${OLLAMA}/api/tags" 2>/dev/null \
      | python3 -c "import json,sys; [print(m['name']) for m in json.load(sys.stdin)['models']]" 2>/dev/null)
    for m in $REQUIRED_MODELS; do
        if echo "$AVAILABLE" | grep -q "^${m}$"; then
            pass "Model: $m"
        else
            # Check without tag
            BASE=$(echo "$m" | cut -d: -f1)
            if echo "$AVAILABLE" | grep -q "^${BASE}:"; then
                warn "Model: $m (different tag available)"
            else
                fail "Model: $m not pulled - run: ollama pull $m"
            fi
        fi
    done
fi

echo ""

# permission mode
echo "Permission Mode"
if grep -q 'skipDangerousModePermissionPrompt.*true' ~/.claude/settings.json 2>/dev/null; then
    pass "Dangerous mode enabled (no permission prompts)"
else
    fail "Permission prompts active - add skipDangerousModePermissionPrompt to ~/.claude/settings.json"
fi

echo ""

# graphify knowledge graph
echo "Graphify Knowledge Graph"
if [ -f graphify-out/graph.json ]; then
    GRAPH_SIZE=$(wc -c < graphify-out/graph.json)
    GRAPH_AGE=$(python3 -c "
import os, time
age = time.time() - os.path.getmtime('graphify-out/graph.json')
if age < 3600: print(f'{int(age/60)}m ago')
elif age < 86400: print(f'{int(age/3600)}h ago')
else: print(f'{int(age/86400)}d ago')
" 2>/dev/null || echo "unknown")
    pass "graph.json exists ($(numfmt --to=iec $GRAPH_SIZE 2>/dev/null || echo "${GRAPH_SIZE}B"), updated $GRAPH_AGE)"
else
    fail "No graph.json - run: /graphify . or ./scripts/graphify-rebuild.sh"
fi

if [ -f graphify-out/GRAPH_REPORT.md ]; then
    pass "GRAPH_REPORT.md exists"
else
    fail "No GRAPH_REPORT.md"
fi

# PreToolUse hook
if grep -q "graphify" .claude/settings.json 2>/dev/null; then
    pass "Graphify PreToolUse hook active"
else
    fail "No graphify hook - run: graphify claude install"
fi

# Git hooks
if graphify hook status 2>/dev/null | grep -q "installed"; then
    pass "Git hooks installed (post-commit + post-checkout)"
else
    warn "Git hooks not installed - run: graphify hook install"
fi

echo ""

# sync daemon
echo "Continuous Sync Daemon"
if [ -f graphify-out/.sync.pid ] && ps -p "$(cat graphify-out/.sync.pid)" >/dev/null 2>&1; then
    pass "Sync daemon running (PID $(cat graphify-out/.sync.pid))"
else
    warn "Sync daemon not running"
    echo -e "       Start: ${YELLOW}nohup ./scripts/graphify-sync.sh --watch > graphify-out/sync.log 2>&1 &${NC}"
    echo "       echo \$! > graphify-out/.sync.pid"
fi

echo ""

# claude hooks
echo "Safety & Quality Hooks"
SETTINGS=".claude/settings.json"
if [ -f "$SETTINGS" ]; then
    python3 -c "
import json
s = json.load(open('$SETTINGS'))
hooks = s.get('hooks', {})

pre = hooks.get('PreToolUse', [])
post = hooks.get('PostToolUse', [])

matchers = [h.get('matcher', '*') for h in pre]
if any('Bash' in m for m in matchers):
    print('PASS:Bash firewall (pre-bash)')
else:
    print('FAIL:No bash firewall hook')

if any('Edit' in m or 'Write' in m for m in matchers):
    print('PASS:File protection (pre-edit/write)')
else:
    print('FAIL:No file protection hook')

if any('Glob' in m or 'Grep' in m for m in matchers):
    print('PASS:Graphify awareness (pre-glob/grep)')
else:
    print('FAIL:No graphify awareness hook')

post_matchers = [h.get('matcher', '*') for h in post]
if any('Edit' in m or 'Write' in m for m in post_matchers):
    print('PASS:Quality checks (post-edit)')
else:
    print('WARN:No post-edit quality hook')
" 2>/dev/null | while IFS=: read -r status msg; do
        case "$status" in
            PASS) pass "$msg" ;;
            FAIL) fail "$msg" ;;
            WARN) warn "$msg" ;;
        esac
    done
else
    fail "No .claude/settings.json found"
fi

# Liveness probes: hook installation says "configured", these probes say "working".
# Probe 1 — firewall actually rejects a destructive command. We emit a synthetic
# tool-call payload through the hook and verify it exits non-zero.
if [ -x "$HOME/.claude/hooks/pre-bash-firewall.sh" ]; then
    PROBE_OUT="$(echo '{"command":"rm -rf /"}' | "$HOME/.claude/hooks/pre-bash-firewall.sh" 2>&1; echo "exit=$?")"
    if echo "$PROBE_OUT" | grep -qE 'BLOCKED|exit=2'; then
        pass "Firewall LIVE — synthetic 'rm -rf /' was blocked"
    else
        fail "Firewall configured but did NOT block synthetic 'rm -rf /' — probe output: $(echo "$PROBE_OUT" | head -1)"
    fi
fi

# Probe 2 — policy gate hook present + exits 2 on a deny.
if [ -x "$HOME/.claude/hooks/pre-tool-policy-gate.sh" ] \
   && [ -x "$PROJECT_DIR/scripts/agent-gate.sh" 2>/dev/null ] \
   && { [ -d policy ] || [ -d governance/policy ]; }; then
    GATE_OUT="$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
        | "$HOME/.claude/hooks/pre-tool-policy-gate.sh" 2>&1; echo "exit=$?")"
    if echo "$GATE_OUT" | grep -q 'exit=2'; then
        pass "Policy gate LIVE — synthetic 'rm -rf /' returned exit 2"
    else
        warn "Policy gate hook present but probe did not block — last line: $(echo "$GATE_OUT" | tail -2 | head -1)"
    fi
fi

echo ""

# mcp server
echo "MCP Server"
MCP_RESULT=$(python3 -c "
import json
s = json.load(open('.claude/settings.json'))
servers = s.get('mcpServers', {})
if servers:
    names = ', '.join(servers.keys())
    print(f'ok {len(servers)} MCP server(s) - {names}')
else:
    print('none')
" 2>/dev/null || echo "none")
if [ "$MCP_RESULT" != "none" ]; then
    pass "${MCP_RESULT#ok }"
else
    warn "No MCP servers configured"
fi

echo ""

# environment
echo "Environment"
pass "Python: $(python3 --version 2>&1)"
pass "Git: $(git --version 2>&1 | head -1)"
pass "Branch: $(git branch --show-current 2>/dev/null || echo 'detached')"
pass "Remote: $(git remote get-url origin 2>/dev/null || echo 'none')"

if [ -n "${OLLAMA_HOST:-}" ]; then
    pass "OLLAMA_HOST=$OLLAMA_HOST"
else
    warn "OLLAMA_HOST not set (using default: http://host.docker.internal:11434)"
fi

echo ""

# git status
echo "Git Status"
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l)
AHEAD=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "?")
BEHIND=$(git rev-list --count HEAD..@{upstream} 2>/dev/null || echo "?")

if [ "$UNCOMMITTED" -eq 0 ]; then
    pass "Working tree clean"
else
    warn "$UNCOMMITTED uncommitted changes"
fi

if [ "$BEHIND" != "?" ] && [ "$BEHIND" -gt 0 ]; then
    warn "$BEHIND commits behind origin - run: git pull"
elif [ "$AHEAD" != "?" ] && [ "$AHEAD" -gt 0 ]; then
    warn "$AHEAD unpushed commits - consider: git push"
else
    pass "Up to date with origin"
fi

echo ""

# summary

if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All checks passed. Ready to develop.${NC}"
else
    echo -e "${RED}$FAILURES check(s) failed. Fix before starting.${NC}"
fi

echo ""
