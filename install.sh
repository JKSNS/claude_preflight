#!/usr/bin/env bash
# install.sh - Bootstrap claude_preflight into any project.
#
# Usage (from inside your project directory):
#   curl -fsSL https://raw.githubusercontent.com/JKSNS/claude_preflight/main/install.sh | bash
#
# Or clone and run:
#   git clone git@github.com:JKSNS/claude_preflight.git /tmp/claude_preflight
#   cd your-project && /tmp/claude_preflight/install.sh
#
# What it does:
#   1. Copies scripts/ into your project
#   2. Copies template configs (.graphifyignore)
#   3. Installs safety hooks + configures settings.json
#   4. Installs graphify (pip) + skill + hooks
#   5. Configures Claude Code plugins (autocompact, statusline, ccusage)
#   6. Registers the sync daemon as a persistent scheduled task
#   7. Runs preflight to validate everything
#
# Flags:
#   --force    Overwrite existing files (used by self-update)
#
# Safe: never overwrites existing files without --force.

set -uo pipefail

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
    esac
done

# Resolve where the preflight repo lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PYTHON="python3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[preflight]${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Claude Code Preflight - Install                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
log "Project: $PROJECT_DIR"
echo ""

cd "$PROJECT_DIR"

# ── Step 1: Copy scripts ──────────────────────────────────
log "Step 1: Installing scripts..."
mkdir -p scripts 2>/dev/null || true

copy_file() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "Source missing: $src"
        return 0
    fi
    if [ -f "$dst" ] && [ "$FORCE" = false ]; then
        warn "EXISTS: $dst (skipping — use --force to overwrite)"
    else
        if cp "$src" "$dst" 2>/dev/null; then
            chmod +x "$dst" 2>/dev/null || true
            if [ -f "$dst" ] && [ "$FORCE" = true ]; then
                ok "Updated $dst"
            else
                ok "Installed $dst"
            fi
        else
            warn "Could not write $dst (permission denied — project dir may be read-only)"
        fi
    fi
}

copy_file "$SCRIPT_DIR/scripts/preflight.sh" "scripts/preflight.sh"
copy_file "$SCRIPT_DIR/scripts/repo-cleanup.sh" "scripts/repo-cleanup.sh"
copy_file "$SCRIPT_DIR/scripts/graphify-rebuild.sh" "scripts/graphify-rebuild.sh"
copy_file "$SCRIPT_DIR/scripts/graphify-sync.sh" "scripts/graphify-sync.sh"
copy_file "$SCRIPT_DIR/scripts/soft-references.sh" "scripts/soft-references.sh"
copy_file "$SCRIPT_DIR/scripts/self-update.sh" "scripts/self-update.sh"
copy_file "$SCRIPT_DIR/scripts/model-profile.sh" "scripts/model-profile.sh"

echo ""

# ── Step 2: Copy templates ────────────────────────────────
log "Step 2: Installing templates..."

if [ ! -f .graphifyignore ] || [ "$FORCE" = true ]; then
    if cp "$SCRIPT_DIR/templates/.graphifyignore" .graphifyignore 2>/dev/null; then
        ok "Installed .graphifyignore"
    else
        warn "Could not write .graphifyignore (project dir may be read-only)"
    fi
else
    warn "EXISTS: .graphifyignore (skipping — use --force to overwrite)"
fi

# Add graphify intermediates to .gitignore if not already there
GITIGNORE_ADDS=(
    "graphify-out/.graphify_*"
    "graphify-out/cache/"
    "graphify-out/.chunk_manifest_*"
    "graphify-out/.sync.lock"
    "graphify-out/.sync.pid"
    "graphify-out/sync.log"
    ".claude_profile"
)
if [ -f .gitignore ]; then
    added=0
    for entry in "${GITIGNORE_ADDS[@]}"; do
        if ! grep -qF "$entry" .gitignore 2>/dev/null; then
            echo "$entry" >> .gitignore 2>/dev/null && added=$((added+1)) || true
        fi
    done
    [ "$added" -gt 0 ] && ok "Updated .gitignore with graphify exclusions" || ok ".gitignore already up to date"
elif printf '%s\n' "${GITIGNORE_ADDS[@]}" > .gitignore 2>/dev/null; then
    ok "Created .gitignore"
fi

echo ""

# ── Step 3: Install safety hooks ─────────────────────────
log "Step 3: Installing safety hooks..."

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"

for hook in pre-bash-firewall.sh protect-critical-files.sh post-edit-quality.sh; do
    if [ -f "$SCRIPT_DIR/hooks/$hook" ]; then
        if cp "$SCRIPT_DIR/hooks/$hook" "$HOOKS_DIR/$hook"; then
            chmod 755 "$HOOKS_DIR/$hook"
            ok "Hook: $hook → $HOOKS_DIR/$hook"
        else
            warn "Could not install hook: $hook"
        fi
    else
        warn "Hook source missing: $SCRIPT_DIR/hooks/$hook"
    fi
done

# Configure hooks in global settings.json — update stale paths, add missing entries
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$GLOBAL_SETTINGS" ]; then
    "$PYTHON" -c "
import json, os, sys

settings_path = '$GLOBAL_SETTINGS'
hooks_dir = '$HOOKS_DIR'

with open(settings_path) as f:
    s = json.load(f)

hooks = s.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])
post = hooks.setdefault('PostToolUse', [])

desired_pre = {
    'Bash':      os.path.join(hooks_dir, 'pre-bash-firewall.sh'),
    'Edit|Write': os.path.join(hooks_dir, 'protect-critical-files.sh'),
}
desired_post = {
    'Edit|MultiEdit|Write': os.path.join(hooks_dir, 'post-edit-quality.sh'),
}

def upsert_hook(hook_list, matcher, command):
    hook_basename = os.path.basename(command)
    for h in hook_list:
        if h.get('matcher', '') == matcher:
            for hk in h.get('hooks', []):
                if hk.get('type') == 'command':
                    # Update if it points to the same script name anywhere
                    if os.path.basename(hk.get('command', '')) == hook_basename:
                        hk['command'] = command
                        return
            return
    hook_list.append({'matcher': matcher, 'hooks': [{'type': 'command', 'command': command}]})

for matcher, cmd in desired_pre.items():
    upsert_hook(pre, matcher, cmd)
for matcher, cmd in desired_post.items():
    upsert_hook(post, matcher, cmd)

with open(settings_path, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
" 2>/dev/null && ok "Global settings.json: hook paths updated" \
    || warn "Could not update global settings.json"
else
    warn "No global settings.json found — create $GLOBAL_SETTINGS and re-run"
fi

echo ""

# ── Step 4: Install graphify ─────────────────────────────
log "Step 4: Installing graphify..."

if "$PYTHON" -c "import graphify" 2>/dev/null; then
    ok "graphify already installed"
else
    log "Installing graphifyy package..."
    "$PYTHON" -m pip install graphifyy -q --break-system-packages 2>/dev/null \
        || "$PYTHON" -m pip install graphifyy -q 2>/dev/null || true
    if "$PYTHON" -c "import graphify" 2>/dev/null; then
        ok "graphify installed"
    else
        fail "Could not install graphify — install manually: pip install graphifyy"
    fi
fi

# Install graphify skill — use bundled SKILL.md (has Ollama routing) rather than
# the package's built-in version, which lags behind.
GRAPHIFY_SKILL_SRC="$SCRIPT_DIR/skills/graphify/SKILL.md"
GRAPHIFY_SKILL_DST="$HOME/.claude/skills/graphify/SKILL.md"
mkdir -p "$(dirname "$GRAPHIFY_SKILL_DST")"
if [ -f "$GRAPHIFY_SKILL_SRC" ] && { [ ! -f "$GRAPHIFY_SKILL_DST" ] || [ "$FORCE" = true ]; }; then
    cp "$GRAPHIFY_SKILL_SRC" "$GRAPHIFY_SKILL_DST"
    ok "Graphify skill installed from repo (Ollama-aware)"
elif [ ! -f "$GRAPHIFY_SKILL_DST" ]; then
    graphify install 2>/dev/null && ok "Graphify skill installed" || warn "Could not install graphify skill"
else
    ok "Graphify skill already installed (run --force to update)"
fi

# Install /preflight skill
PREFLIGHT_SKILL_DIR="$HOME/.claude/skills/preflight"
if [ ! -f "$PREFLIGHT_SKILL_DIR/SKILL.md" ] || [ "$FORCE" = true ]; then
    mkdir -p "$PREFLIGHT_SKILL_DIR"
    if cp "$SCRIPT_DIR/SKILL.md" "$PREFLIGHT_SKILL_DIR/SKILL.md"; then
        ok "Preflight skill installed (/preflight)"
    else
        warn "Could not install preflight skill"
    fi
else
    ok "Preflight skill already installed"
fi

# Install Claude Code always-on graphify hook
if grep -q "graphify" .claude/settings.json 2>/dev/null; then
    ok "Graphify Claude hook already active"
else
    graphify claude install 2>/dev/null && ok "Graphify Claude hook installed" \
        || warn "Could not install graphify Claude hook"
fi

# Install git hooks (AST rebuild on commit/checkout)
if graphify hook status 2>/dev/null | grep -q "installed"; then
    ok "Git hooks already installed"
else
    graphify hook install 2>/dev/null && ok "Git hooks installed" \
        || warn "Could not install git hooks"
fi

echo ""

# ── Step 5: Configure Claude Code plugins ────────────────
log "Step 5: Configuring Claude Code plugins..."

GLOBAL_SETTINGS="$HOME/.claude/settings.json"

if [ -f "$GLOBAL_SETTINGS" ]; then
    "$PYTHON" -c "
import json, os

settings_path = '$GLOBAL_SETTINGS'
home = os.path.expanduser('~')
statusline_script = os.path.join(home, '.claude', 'statusline-command.sh')

with open(settings_path) as f:
    s = json.load(f)

changed = False

# autoCompact — compact context when it's getting full
if not s.get('autoCompact'):
    s['autoCompact'] = True
    changed = True

# statusLine — show model, context %, and session cost
if 'statusLine' not in s:
    s['statusLine'] = {
        'type': 'command',
        'command': f'bash {statusline_script}'
    }
    changed = True

if changed:
    with open(settings_path, 'w') as f:
        json.dump(s, f, indent=2)
        f.write('\n')
    print('settings updated')
else:
    print('already configured')
" 2>/dev/null && ok "autoCompact + statusLine configured" \
    || warn "Could not update plugin settings"

    # Install/update statusline script
    STATUSLINE_SCRIPT="$HOME/.claude/statusline-command.sh"
    if [ ! -f "$STATUSLINE_SCRIPT" ] || [ "$FORCE" = true ]; then
        if [ -f "$SCRIPT_DIR/templates/statusline-command.sh" ]; then
            cp "$SCRIPT_DIR/templates/statusline-command.sh" "$STATUSLINE_SCRIPT"
            chmod +x "$STATUSLINE_SCRIPT"
            ok "Statusline script installed: $STATUSLINE_SCRIPT"
        else
            warn "statusline-command.sh template missing — statusline not installed"
        fi
    else
        ok "Statusline script already installed"
    fi
else
    warn "No global settings.json — skipping plugin configuration"
fi

# Install ccusage (session cost tracker) if npm available
if command -v npx >/dev/null 2>&1; then
    if npx --yes ccusage --version >/dev/null 2>&1; then
        ok "ccusage available (run: npx ccusage)"
    else
        warn "ccusage install failed — run: npm install -g ccusage"
    fi
else
    warn "npm/npx not found — skipping ccusage (install node.js for cost tracking)"
fi

echo ""

# ── Step 6: Register persistent sync daemon ───────────────
log "Step 6: Setting up persistent sync daemon..."

PROJECT_NAME="$(basename "$PROJECT_DIR")"
CRON_CMD="cd $PROJECT_DIR && ./scripts/graphify-sync.sh >> graphify-out/sync.log 2>&1"
CRON_ENTRY="*/5 * * * * $CRON_CMD"

if command -v crontab >/dev/null 2>&1; then
    if crontab -l 2>/dev/null | grep -qF "$PROJECT_DIR/scripts/graphify-sync.sh"; then
        ok "Cron job already registered for this project"
    else
        (crontab -l 2>/dev/null; echo "# claude_preflight sync: $PROJECT_NAME"; echo "$CRON_ENTRY") | crontab - 2>/dev/null \
            && ok "Cron job registered (every 5 min)" \
            || warn "Could not register cron job"
    fi
else
    log "crontab not found — attempting to install..."
    if [ "$(id -u)" -eq 0 ]; then
        command -v apt-get >/dev/null && apt-get install -y -qq cron 2>/dev/null || true
        command -v apk >/dev/null && apk add --no-cache dcron 2>/dev/null || true
    elif sudo -n true 2>/dev/null; then
        command -v apt-get >/dev/null && sudo apt-get install -y -qq cron 2>/dev/null || true
        command -v apk >/dev/null && sudo apk add --no-cache dcron 2>/dev/null || true
    fi
    if command -v crontab >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] && service cron start 2>/dev/null || true
        (crontab -l 2>/dev/null; echo "# claude_preflight: $PROJECT_NAME"; echo "$CRON_ENTRY") | crontab - 2>/dev/null \
            && ok "Cron job registered (every 5 min)" || true
    else
        warn "Could not install cron — sync daemon runs as background watch process only"
    fi
fi

# Startup script for container restart persistence
STARTUP_DIR="$HOME/.claude/startup"
mkdir -p "$STARTUP_DIR"
STARTUP_SCRIPT="$STARTUP_DIR/sync-${PROJECT_NAME}.sh"

cat > "$STARTUP_SCRIPT" << STARTUP
#!/usr/bin/env bash
# Auto-start graphify sync for $PROJECT_NAME — created by claude_preflight
cd "$PROJECT_DIR" 2>/dev/null || exit 0
if [ -f scripts/graphify-sync.sh ]; then
    [ -f graphify-out/.sync.pid ] && kill "\$(cat graphify-out/.sync.pid)" 2>/dev/null || true
    nohup ./scripts/graphify-sync.sh --watch > graphify-out/sync.log 2>&1 &
    echo \$! > graphify-out/.sync.pid
fi
STARTUP
chmod +x "$STARTUP_SCRIPT"
ok "Startup script: $STARTUP_SCRIPT"

BASHRC="$HOME/.bashrc"
MARKER="# claude_preflight: $PROJECT_NAME"
if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    printf '\n%s\n[ -f "%s" ] && bash "%s"\n' "$MARKER" "$STARTUP_SCRIPT" "$STARTUP_SCRIPT" >> "$BASHRC"
    ok "Registered in .bashrc (survives container restart)"
else
    ok "Already in .bashrc"
fi

# Start sync daemon immediately if graph exists
mkdir -p graphify-out 2>/dev/null || true
if [ -f graphify-out/graph.json ]; then
    if [ -f graphify-out/.sync.pid ] && ps -p "$(cat graphify-out/.sync.pid)" >/dev/null 2>&1; then
        ok "Sync daemon already running (PID $(cat graphify-out/.sync.pid))"
    elif [ -f scripts/graphify-sync.sh ]; then
        nohup ./scripts/graphify-sync.sh --watch > graphify-out/sync.log 2>&1 &
        echo $! > graphify-out/.sync.pid
        ok "Started sync daemon (PID $!)"
    fi
else
    warn "No graph yet — sync daemon will start after /graphify builds the graph"
fi

echo ""

# ── Step 7: Run preflight ────────────────────────────────
log "Step 7: Running preflight check..."
echo ""
bash scripts/preflight.sh 2>/dev/null || true

echo ""

# Stamp version
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    cp "$SCRIPT_DIR/VERSION" scripts/.preflight_version 2>/dev/null || true
    ok "Version: $(cat scripts/.preflight_version 2>/dev/null || cat "$SCRIPT_DIR/VERSION")"
fi

log "Installation complete."
echo ""
echo "  Next steps:"
echo "    1. /graphify .                            # build knowledge graph (in Claude Code)"
echo "    2. ./scripts/repo-cleanup.sh              # preview reorganization"
echo "    3. ./scripts/repo-cleanup.sh --execute    # apply it"
echo "    4. git add -A && git commit && git push   # save everything"
echo ""
echo "  Cost tracking:"
echo "    npx ccusage                               # session cost summary"
echo "    npx ccusage --live                        # live usage dashboard"
echo ""
echo "  Updates:"
echo "    ./scripts/self-update.sh --check          # check for updates"
echo "    ./scripts/self-update.sh                  # pull latest & reinstall"
echo ""
