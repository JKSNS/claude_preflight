#!/usr/bin/env bash
# model-profile.sh - Show / apply / verify the model routing config.
#
# Single-config design: Claude for everything, Ollama (qwen3.6:35b) for
# graphify only. The offline/online dichotomy was removed in 0.7.0; everything
# routes to Anthropic by default and graphify always runs locally.
#
# Usage:
#   ./scripts/model-profile.sh           # show current routing
#   ./scripts/model-profile.sh show      # same
#   ./scripts/model-profile.sh apply     # write env vars into ~/.claude/settings.json
#   ./scripts/model-profile.sh check     # verify Ollama has the graphify model
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PYTHON="${GRAPHIFY_PYTHON:-python3}"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CMD="${1:-show}"

locate_profile() {
    local candidates=(
        "profiles/default.json"
        "${PREFLIGHT_HOME:-}/profiles/default.json"
        "${HOME}/.claude/preflight-bundle/profiles/default.json"
        "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../profiles/default.json"
    )
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -f "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

PROFILE="$(locate_profile)" || true
if [ -z "$PROFILE" ]; then
    echo "model-profile: cannot locate profiles/default.json" >&2
    exit 2
fi

show_routing() {
    echo ""
    echo -e "${BOLD}Model routing${NC}"
    echo "  Source: $PROFILE"
    echo ""
    "$PYTHON" -c "
import json
p = json.load(open('$PROFILE'))
m = p['models']
print(f'  primary    {m[\"primary\"][\"provider\"]:10s} {m[\"primary\"][\"model\"]:30s} {m[\"primary\"][\"description\"]}')
print(f'  fast       {m[\"fast\"][\"provider\"]:10s} {m[\"fast\"][\"model\"]:30s} {m[\"fast\"][\"description\"]}')
print(f'  extraction {m[\"extraction\"][\"provider\"]:10s} {m[\"extraction\"][\"model\"]:30s} {m[\"extraction\"][\"description\"]}')
print()
print('  Required Ollama models: ' + ', '.join(p['required_models']))
"
    echo ""
}

apply_routing() {
    if [ ! -f "$GLOBAL_SETTINGS" ]; then
        echo -e "${YELLOW}[WARN]${NC} no $GLOBAL_SETTINGS to update" >&2
        return 1
    fi
    "$PYTHON" - "$PROFILE" "$GLOBAL_SETTINGS" <<'PY'
import json, sys
profile_path, settings_path = sys.argv[1:3]
profile = json.load(open(profile_path))
with open(settings_path) as f:
    settings = json.load(f)
env = settings.setdefault("env", {})
for k, v in profile["env"].items():
    env[k] = v
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  applied {len(profile['env'])} env var(s) to {settings_path}")
PY
}

check_ollama() {
    OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"
    AVAILABLE="$(curl -sf "${OLLAMA}/api/tags" 2>/dev/null \
        | "$PYTHON" -c "import json,sys; [print(m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null \
        || true)"
    if [ -z "$AVAILABLE" ]; then
        echo -e "  ${RED}[FAIL]${NC} Ollama unreachable at $OLLAMA"
        return 1
    fi
    REQUIRED="$("$PYTHON" -c "import json; print('\n'.join(json.load(open('$PROFILE'))['required_models']))")"
    local rc=0
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        base="${r%%:*}"
        if echo "$AVAILABLE" | grep -q "^${r}$"; then
            echo -e "  ${GREEN}[OK]${NC}    $r"
        elif echo "$AVAILABLE" | grep -q "^${base}:"; then
            local actual; actual="$(echo "$AVAILABLE" | grep "^${base}:" | head -1)"
            echo -e "  ${YELLOW}[WARN]${NC}  $r not pulled (have $actual)"
            rc=1
        else
            echo -e "  ${RED}[MISSING]${NC} $r — run: ollama pull $r"
            rc=1
        fi
    done <<< "$REQUIRED"
    return $rc
}

case "$CMD" in
    show)  show_routing ;;
    apply) show_routing; apply_routing ;;
    check) show_routing; check_ollama ;;
    *)
        echo "Usage: $0 [show|apply|check]" >&2
        exit 2
        ;;
esac
