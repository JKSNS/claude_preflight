#!/usr/bin/env bash
# model-profile.sh - Switch between online/offline model routing profiles.
#
# Usage:
#   ./scripts/model-profile.sh offline     # local Ollama (nemotron + gemma4, $0)
#   ./scripts/model-profile.sh online      # Anthropic API with Ollama fallback
#   ./scripts/model-profile.sh             # show current profile
#   ./scripts/model-profile.sh list        # list available profiles
#   ./scripts/model-profile.sh check       # validate current profile's models are available
#
# Profiles are JSON files in profiles/ or ~/.claude/preflight/profiles/.
# Custom profiles: create a JSON file following the same schema.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PYTHON="${GRAPHIFY_PYTHON:-python3}"
PROFILE_FILE=".claude_profile"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Locate profile directory — check project scripts/, then preflight cache
find_profile_dir() {
    local dirs=(
        "profiles"
        "scripts/profiles"
        "$HOME/.claude/preflight/profiles"
        "${TMPDIR:-/tmp}/claude_preflight/profiles"
    )
    for d in "${dirs[@]}"; do
        if [ -d "$d" ] && ls "$d"/*.json >/dev/null 2>&1; then
            echo "$d"
            return
        fi
    done
    echo ""
}

PROFILE_DIR=$(find_profile_dir)

# ── Show current profile ──────────────────────────────────
show_current() {
    if [ -f "$PROFILE_FILE" ]; then
        local current
        current=$(cat "$PROFILE_FILE")
        echo -e "${BOLD}Current profile:${NC} ${GREEN}${current}${NC}"

        # Show model assignments
        if [ -f "$GLOBAL_SETTINGS" ]; then
            $PYTHON -c "
import json
s = json.load(open('$GLOBAL_SETTINGS'))
env = s.get('env', {})
print()
print('  \033[1mActive:\033[0m')
active = {
    'Primary':    env.get('PREFLIGHT_PRIMARY_MODEL', '(not set)'),
    'Fast':       env.get('PREFLIGHT_FAST_MODEL', '(not set)'),
    'Extraction': env.get('PREFLIGHT_EXTRACTION_MODEL', '(not set)'),
}
max_key = max(len(k) for k in active)
for role, model in active.items():
    provider = 'ollama' if model.startswith('ollama:') else 'anthropic' if 'claude' in model else 'unknown'
    color = '32' if provider == 'ollama' else '35' if provider == 'anthropic' else '33'
    print(f'    {role:<{max_key}}  \033[{color}m{model}\033[0m')

fallback_primary = env.get('PREFLIGHT_FALLBACK_PRIMARY', '')
fallback_fast = env.get('PREFLIGHT_FALLBACK_FAST', '')
if fallback_primary or fallback_fast:
    print()
    print('  \033[1mFallback:\033[0m')
    if fallback_primary:
        print(f'    {\"Primary\":<{max_key}}  \033[32m{fallback_primary}\033[0m')
    if fallback_fast:
        print(f'    {\"Fast\":<{max_key}}  \033[32m{fallback_fast}\033[0m')
" 2>/dev/null
        fi
    else
        echo -e "${YELLOW}No profile set.${NC} Run: ./scripts/model-profile.sh offline"
    fi
}

# ── List available profiles ───────────────────────────────
list_profiles() {
    echo -e "${BOLD}Available profiles:${NC}"
    echo ""
    if [ -z "$PROFILE_DIR" ]; then
        echo -e "  ${RED}No profile directory found${NC}"
        return 1
    fi

    local current=""
    [ -f "$PROFILE_FILE" ] && current=$(cat "$PROFILE_FILE")

    for f in "$PROFILE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .json)
        local desc
        desc=$($PYTHON -c "import json; print(json.load(open('$f')).get('_comment', ''))" 2>/dev/null || echo "")

        if [ "$name" = "$current" ]; then
            echo -e "  ${GREEN}* ${name}${NC}  ${DIM}${desc}${NC}"
        else
            echo -e "    ${name}  ${DIM}${desc}${NC}"
        fi
    done
}

# ── Check model availability ──────────────────────────────
check_models() {
    if [ ! -f "$PROFILE_FILE" ]; then
        echo -e "${YELLOW}No profile set.${NC}"
        return 1
    fi

    local current
    current=$(cat "$PROFILE_FILE")
    local profile_path="${PROFILE_DIR}/${current}.json"

    if [ ! -f "$profile_path" ]; then
        echo -e "${RED}Profile file not found: ${profile_path}${NC}"
        return 1
    fi

    echo -e "${BOLD}Checking models for profile: ${current}${NC}"
    echo ""

    OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"

    $PYTHON -c "
import json, subprocess, sys

profile = json.load(open('$profile_path'))
required = profile.get('required_models', [])
models = profile.get('models', {})

# Get available Ollama models
try:
    import urllib.request
    data = json.loads(urllib.request.urlopen('${OLLAMA}/api/tags', timeout=5).read())
    available = [m['name'] for m in data.get('models', [])]
except:
    available = []
    print('  \033[33m[WARN]\033[0m Ollama not reachable')

ok = 0
fail = 0

# Check required Ollama models
for m in required:
    base = m.split(':')[0]
    found = any(a.startswith(base + ':') or a == m for a in available)
    if found:
        print(f'  \033[32m[OK]\033[0m   {m} (required, local)')
        ok += 1
    else:
        print(f'  \033[31m[MISS]\033[0m {m} (required) — run: ollama pull {m}')
        fail += 1

# Check Anthropic models (just verify API key exists)
has_anthropic = False
for role, spec in models.items():
    if spec.get('provider') == 'anthropic':
        has_anthropic = True
        break

if has_anthropic:
    import os
    if os.environ.get('ANTHROPIC_API_KEY'):
        print(f'  \033[32m[OK]\033[0m   Anthropic API key set')
    else:
        print(f'  \033[31m[MISS]\033[0m ANTHROPIC_API_KEY not set')
        fail += 1

print()
if fail == 0:
    print(f'\033[32mAll models available.\033[0m')
else:
    print(f'\033[31m{fail} model(s) missing.\033[0m')
    sys.exit(1)
" 2>/dev/null
}

# ── Apply a profile ───────────────────────────────────────
apply_profile() {
    local name="$1"

    if [ -z "$PROFILE_DIR" ]; then
        echo -e "${RED}No profile directory found.${NC}"
        echo "  Expected: profiles/*.json or ~/.claude/preflight/profiles/*.json"
        return 1
    fi

    local profile_path="${PROFILE_DIR}/${name}.json"
    if [ ! -f "$profile_path" ]; then
        echo -e "${RED}Profile not found: ${name}${NC}"
        list_profiles
        return 1
    fi

    echo -e "${BOLD}Switching to profile: ${CYAN}${name}${NC}"
    echo ""

    # Apply env vars to global settings.json
    if [ ! -f "$GLOBAL_SETTINGS" ]; then
        echo -e "${RED}No global settings.json at ${GLOBAL_SETTINGS}${NC}"
        return 1
    fi

    $PYTHON -c "
import json, sys

profile = json.load(open('$profile_path'))
settings_path = '$GLOBAL_SETTINGS'

with open(settings_path) as f:
    settings = json.load(f)

env = settings.setdefault('env', {})

# Apply profile env vars
profile_env = profile.get('env', {})
for key, value in profile_env.items():
    env[key] = value

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

# Report what was set
models = profile.get('models', {})
fallback = profile.get('fallback_models', {})
all_roles = list(models.keys())
max_role = max(len(r) for r in all_roles) if all_roles else 0

print()
print('  \033[1mActive:\033[0m')
for role, spec in models.items():
    provider = spec.get('provider', '?')
    model = spec.get('model', '?')
    color = '32' if provider == 'ollama' else '35'
    cost = '\$0' if provider == 'ollama' else 'tokens'
    print(f'    {role:<{max_role}}  \033[{color}m{provider}:{model}\033[0m  ({cost})')

if fallback:
    print()
    print('  \033[1mFallback (if primary unreachable):\033[0m')
    for role, spec in fallback.items():
        provider = spec.get('provider', '?')
        model = spec.get('model', '?')
        color = '32' if provider == 'ollama' else '35'
        print(f'    {role:<{max_role}}  \033[{color}m{provider}:{model}\033[0m  (\$0)')
print()
" 2>/dev/null

    # Write profile marker
    echo "$name" > "$PROFILE_FILE"

    echo -e "${GREEN}Profile '${name}' applied.${NC}"
    echo -e "${DIM}Restart Claude Code for env changes to take effect.${NC}"

    # Also write a .env-style export file for shell scripts to source
    $PYTHON -c "
import json
profile = json.load(open('$profile_path'))
env = profile.get('env', {})
lines = [f'export {k}=\"{v}\"' for k, v in env.items()]
with open('.claude_profile_env', 'w') as f:
    f.write('\n'.join(lines) + '\n')
" 2>/dev/null
    echo -e "${DIM}Shell export file: .claude_profile_env (source it in scripts)${NC}"
}

# ── Help ──────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD}model-profile.sh${NC} — Switch model routing between local and cloud providers."
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  ./scripts/model-profile.sh                  Show current profile"
    echo "  ./scripts/model-profile.sh <profile>        Switch to a profile"
    echo "  ./scripts/model-profile.sh list             List available profiles"
    echo "  ./scripts/model-profile.sh check            Validate models are available"
    echo "  ./scripts/model-profile.sh help             Show this help"
    echo ""
    echo -e "${BOLD}Built-in profiles:${NC}"
    echo -e "  ${GREEN}offline${NC}   gemma4:26b default, nemotron-cascade-2 speed fallback (local, \$0)"
    echo -e "  ${CYAN}online${NC}    claude-opus-4-6 + claude-haiku-4-5, Ollama fallback"
    echo ""
    echo "  gemma4:26b is default everywhere (top OSS model). nemotron-cascade-2"
    echo "  is the speed fallback. Online falls back to local models if Anthropic"
    echo "  is unreachable. Extraction always stays local."
    echo ""
    echo -e "${BOLD}Custom profiles:${NC}"
    echo "  Create a JSON file in profiles/ following the same schema."
    echo "  Then: ./scripts/model-profile.sh <name>"
    echo ""
    echo -e "${BOLD}Inside Claude Code:${NC}"
    echo "  /preflight offline    /preflight online"
    echo "  /preflight profile    (show current)"
    echo ""
    echo -e "${BOLD}What it does:${NC}"
    echo "  1. Writes env vars to ~/.claude/settings.json (takes effect on restart)"
    echo "  2. Creates .claude_profile_env (source in shell scripts)"
    echo "  3. Extraction always stays local regardless of profile"
}

# ── Main ──────────────────────────────────────────────────
case "${1:-}" in
    "")
        show_current
        ;;
    list)
        list_profiles
        ;;
    check)
        check_models
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        apply_profile "$1"
        ;;
esac
