---
name: preflight
description: Validate and optimize a Claude Code project - graphify knowledge graph, safety hooks, plugins, sync daemon
trigger: /preflight
---

# /preflight

Validate and optimize a Claude Code project for token efficiency. Works on new projects and existing ones.

## Usage

```
/preflight              # full check and setup
/preflight check        # validate only, no changes
/preflight install      # install everything, skip validation
/preflight sync         # start the graphify sync daemon
/preflight cleanup      # reorganize repo structure
/preflight update       # pull latest from claude_preflight repo
/preflight soft-refs    # generate overviews for large excluded dirs
/preflight fresh        # purge existing preflight setup and reinstall clean
```

## What You Must Do When Invoked

If no subcommand is given, run the full pipeline. Follow these steps in order.

### Step 1 - Check Ollama

```bash
OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"
curl -sf "${OLLAMA}/api/tags" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
print(f'{len(models)} models available')
required = ['gemma4:26b', 'nemotron-cascade-2']
for r in required:
    base = r.split(':')[0]
    found = any(m.startswith(base + ':') or m == r for m in models)
    status = 'OK' if found else 'MISSING'
    print(f'  {r}: {status}')
" 2>/dev/null || echo "Ollama not reachable at ${OLLAMA}"
```

Report which models are available and which are missing. Do not stop if models are missing. Note it and continue.

### Step 2 - Check permissions

```bash
grep -q 'skipDangerousModePermissionPrompt.*true' ~/.claude/settings.json 2>/dev/null && echo "OK: dangerous mode enabled" || echo "MISSING: add skipDangerousModePermissionPrompt to ~/.claude/settings.json"
```

If missing, tell the user what to add and why (eliminates per-tool approval prompts in containerized environments).

### Step 3 - Check plugins

```bash
# autoCompact
python3 -c "import json; s=json.load(open(\"$HOME/.claude/settings.json\")); print('autoCompact:', s.get('autoCompact', False))" 2>/dev/null

# statusLine
python3 -c "import json; s=json.load(open(\"$HOME/.claude/settings.json\")); print('statusLine:', 'configured' if s.get('statusLine') else 'missing')" 2>/dev/null

# ccusage
npx ccusage --version 2>/dev/null && echo "ccusage: available" || echo "ccusage: not found (npx ccusage)"
```

If `autoCompact` is false or missing, add it:
```bash
python3 -c "
import json
p = '$HOME/.claude/settings.json'
s = json.load(open(p))
s['autoCompact'] = True
open(p,'w').write(json.dumps(s, indent=2) + '\n')
print('autoCompact enabled')
"
```

### Step 4 - Install graphify

Check if graphify is installed. If not, install it.

```bash
python3 -c "import graphify" 2>/dev/null || python3 -m pip install graphifyy -q --break-system-packages 2>/dev/null || python3 -m pip install graphifyy -q
```

Then install the graphify skill and Claude Code hook if not already present:

```bash
# Skill
[ -f ~/.claude/skills/graphify/SKILL.md ] || graphify install 2>/dev/null

# Always-on hook (reads graph before every search)
grep -q "graphify" .claude/settings.json 2>/dev/null || graphify claude install 2>/dev/null

# Git hooks (AST rebuild on commit/checkout, free)
graphify hook status 2>/dev/null | grep -q "installed" || graphify hook install 2>/dev/null
```

### Step 5 - Install scripts

Check if the preflight scripts exist in the project. If not, download them from the repo.

```bash
mkdir -p scripts

for script in preflight.sh repo-cleanup.sh graphify-rebuild.sh graphify-sync.sh; do
    if [ ! -f "scripts/$script" ]; then
        curl -fsSL "https://raw.githubusercontent.com/JKSNS/claude_preflight/main/scripts/$script" -o "scripts/$script"
        chmod +x "scripts/$script"
        echo "Installed scripts/$script"
    fi
done
```

Also install `.graphifyignore` if missing:

```bash
if [ ! -f .graphifyignore ]; then
    curl -fsSL "https://raw.githubusercontent.com/JKSNS/claude_preflight/main/templates/.graphifyignore" -o .graphifyignore
    echo "Installed .graphifyignore"
fi
```

### Step 6 - Check knowledge graph

If `graphify-out/graph.json` exists, report its size and age. If not, tell the user to run `/graphify .` to build it.

```bash
if [ -f graphify-out/graph.json ]; then
    python3 -c "
import json, os, time
from pathlib import Path
data = json.loads(Path('graphify-out/graph.json').read_text())
nodes = len(data.get('nodes', []))
edges = len(data.get('links', data.get('edges', [])))
age = time.time() - os.path.getmtime('graphify-out/graph.json')
if age < 3600: ago = f'{int(age/60)}m ago'
elif age < 86400: ago = f'{int(age/3600)}h ago'
else: ago = f'{int(age/86400)}d ago'
print(f'Graph: {nodes} nodes, {edges} edges, updated {ago}')
"
    graphify benchmark graphify-out/graph.json 2>/dev/null || true
else
    echo "No knowledge graph found. Run /graphify . to build one."
fi
```

### Step 7 - Check sync daemon

```bash
if [ -f graphify-out/.sync.pid ] && ps -p "$(cat graphify-out/.sync.pid)" >/dev/null 2>&1; then
    echo "Sync daemon running (PID $(cat graphify-out/.sync.pid))"
else
    echo "Sync daemon not running"
fi
```

If not running, offer to start it:

```bash
nohup ./scripts/graphify-sync.sh --watch > graphify-out/sync.log 2>&1 &
echo $! > graphify-out/.sync.pid
echo "Started sync daemon (PID $!)"
```

### Step 8 - Register persistence

Register the project for container-restart persistence if not already done.

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
STARTUP_DIR="$HOME/.claude/startup"
STARTUP_SCRIPT="$STARTUP_DIR/sync-${PROJECT_NAME}.sh"

mkdir -p "$STARTUP_DIR"

if [ ! -f "$STARTUP_SCRIPT" ]; then
    cat > "$STARTUP_SCRIPT" << STARTUP
#!/usr/bin/env bash
cd "$PROJECT_DIR" 2>/dev/null || exit 0
if [ -f scripts/graphify-sync.sh ]; then
    [ -f graphify-out/.sync.pid ] && kill "\$(cat graphify-out/.sync.pid)" 2>/dev/null || true
    nohup ./scripts/graphify-sync.sh --watch > graphify-out/sync.log 2>&1 &
    echo \$! > graphify-out/.sync.pid
fi
STARTUP
    chmod +x "$STARTUP_SCRIPT"
    echo "Registered startup script for container restart persistence"
fi

# Register in .bashrc if not already
MARKER="# claude_preflight: $PROJECT_NAME"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n[ -f "%s" ] && bash "%s"\n' "$MARKER" "$STARTUP_SCRIPT" "$STARTUP_SCRIPT" >> "$HOME/.bashrc"
    echo "Registered in .bashrc"
fi
```

### Step 9 - Register cron job

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if command -v crontab >/dev/null 2>&1; then
    if ! crontab -l 2>/dev/null | grep -qF "$PROJECT_DIR/scripts/graphify-sync.sh"; then
        PROJECT_NAME="$(basename "$PROJECT_DIR")"
        (crontab -l 2>/dev/null; echo "# claude_preflight: $PROJECT_NAME"; echo "*/5 * * * * cd $PROJECT_DIR && ./scripts/graphify-sync.sh >> graphify-out/sync.log 2>&1") | crontab -
        echo "Cron job registered (every 5 min)"
    else
        echo "Cron job already registered"
    fi
fi
```

### Step 10 - Check git status

```bash
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l)
BEHIND=$(git rev-list --count HEAD..@{upstream} 2>/dev/null || echo "?")
AHEAD=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "?")

[ "$UNCOMMITTED" -gt 0 ] && echo "WARN: $UNCOMMITTED uncommitted changes"
[ "$BEHIND" != "?" ] && [ "$BEHIND" -gt 0 ] && echo "WARN: $BEHIND commits behind origin"
[ "$AHEAD" != "?" ] && [ "$AHEAD" -gt 0 ] && echo "WARN: $AHEAD unpushed commits"
```

### Step 11 - Summary

Print a clean summary of what passed, what failed, and what was installed. Keep it concise. Example:

```
Preflight complete.
  Ollama: 45 models (gemma4:26b OK, nemotron-cascade-2 OK)
  Permissions: dangerous mode enabled
  Plugins: autoCompact ON | statusLine configured | ccusage available
  Graphify: 18,928 nodes, 40,536 edges, updated 2h ago
  Token savings: 143x avg reduction (peak 2,206x)
  Sync daemon: running (PID 12345)
  Persistence: cron + startup hook registered
  Git: clean, up to date
```

## Subcommand behavior

- `/preflight check` - Run steps 1, 2, 3, 6, 7, 10 only. No installs, no changes.
- `/preflight install` - Run steps 4, 5, 8, 9 only. Install everything.
- `/preflight sync` - Run step 7 only. Start the daemon if not running.
- `/preflight cleanup` - Reorganize the repo structure. Before doing anything, ask the user if they have preferences about how things should be organized. After running `./scripts/repo-cleanup.sh` and applying moves, do a sweep: grep for stale path references to anything that moved, check CLAUDE.md and README.md for outdated structure sections, look for docs that reference old directory names, and flag anything else that looks off. Fix what you can, ask about what you are not sure about. Rebuild the graph when done.
- `/preflight update` - Run `./scripts/self-update.sh` to pull latest from the claude_preflight repo and reinstall.
- `/preflight soft-refs` - Run `./scripts/soft-references.sh` to generate lightweight overview nodes for large directories excluded from full graphify indexing. These appear in `graphify-out/SOFT_REFERENCES.md` and `graphify-out/soft_references.json`.
- `/preflight fresh` - Purge existing preflight setup and reinstall clean. Removes old scripts, graphify-out, cron entries, startup hooks, and .bashrc entries for this project. Then runs the full install pipeline from scratch. Use this when the preflight state is stale or broken.

### /preflight fresh steps

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Stop sync daemon
[ -f graphify-out/.sync.pid ] && kill "$(cat graphify-out/.sync.pid)" 2>/dev/null || true

# Remove cron entry
if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "$PROJECT_DIR/scripts/graphify-sync.sh" | \
        grep -v "claude_preflight: $PROJECT_NAME" | crontab -
fi

# Remove startup script
rm -f "$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"

# Remove .bashrc entry
MARKER="# claude_preflight: $PROJECT_NAME"
if grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    grep -vF "$MARKER" "$HOME/.bashrc" | grep -vF "sync-${PROJECT_NAME}.sh" > "$HOME/.bashrc.tmp"
    mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
fi

# Remove graphify outputs and scripts
rm -rf graphify-out/
rm -f scripts/preflight.sh scripts/repo-cleanup.sh scripts/graphify-rebuild.sh scripts/graphify-sync.sh
rm -f .graphifyignore

# Remove graphify hooks
graphify claude uninstall 2>/dev/null || true
graphify hook uninstall 2>/dev/null || true
```

After purging, run the full install pipeline (all steps) from scratch.

## Cost tracking

`ccusage` tracks equivalent API cost from your local Claude Code session data:

```bash
npx ccusage              # cost summary for today
npx ccusage --live       # live usage dashboard  
npx ccusage daily        # breakdown by day
npx ccusage monthly      # monthly summary
```

The statusline in Claude Code also shows live cost for the current session (bottom of the terminal).

## Knowledge graph query examples

When the graph exists (`graphify-out/graph.json`), users can ask natural language questions that Claude answers using the graph topology rather than grepping raw files:

- **Onboarding**: "How does classify route to specialists?" — architecture from structure, not 20 files
- **Refactoring**: "Which auto_* helpers duplicate logic?" — structural duplication via community overlap
- **Impact analysis**: "What breaks if I change ModelConfig?" — god node dependency mapping
- **Architecture**: "Why does KrakenState bridge 5 communities?" — coupling and bottleneck analysis
- **Tracing**: "Show the data flow from input to output" — call graph traversal
