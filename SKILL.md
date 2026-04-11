---
name: preflight
description: Validate and optimize a Claude Code project - graphify knowledge graph, safety hooks, plugins, sync daemon
trigger: /preflight
---

# /preflight

Validate and optimize a Claude Code project for token efficiency. Works on new projects and existing ones.

## Usage

```
/preflight              # full check and setup (prompts before each modifying step)
/preflight --yes        # all-in-one without prompting (unattended bootstrap)
/preflight check        # read-only validation, no changes
/preflight install      # install scripts + graphify + persistence + cron
/preflight uninstall    # project-aware removal: cron + startup + .bashrc lines
/preflight sync         # start / status / restart the graphify sync daemon
/preflight cleanup      # staleness scan; --legacy-shuffle keeps the old name-based reorg
/preflight update       # pull latest from upstream (per-file diff before overwrite)
/preflight soft-refs    # generate overviews for large excluded dirs (with staleness check)
/preflight govern       # scaffold the agentic governance layer
/preflight model        # show / apply / check the model routing config
/preflight snapshot     # capture project state to archive/ for one-line rollback
/preflight fresh        # purge + reinstall (captures state to archive/ first)
```

## Interaction model — ask-at-each-step

`/preflight` (no subcommand) is the all-in-one. It is also the most invasive: it can install scripts, modify `~/.bashrc`, register cron entries, scaffold ~30 governance files, and start a background sync daemon. Some projects need most of this; some need only a slice.

Therefore, in the no-subcommand flow:

- **Read-only checks** (Ollama reachability, permissions, plugin state, graph age, sync daemon status, git status) run immediately without asking.
- **Modifying steps** (install scripts, install graphify, install hooks, scaffold governance, register cron, register `.bashrc`, start the sync daemon) **must be prompted individually** before execution. Use this template at each modifying step:
  ```
  Step <N>: <action> — <one-line explanation of impact>
       Run this step? (y/N)
  ```
  Default to `N` so a stream of `<enter>` keystrokes runs only the read-only checks. The user can always re-invoke the explicit subcommand later (`/preflight install`, `/preflight govern`, etc.) to do the part they want.

- **Subcommands** (`/preflight check`, `/preflight install`, `/preflight govern`, `/preflight cleanup`, `/preflight sync`, `/preflight fresh`, etc.) are the granular form. The user has explicitly chosen the action, so do **not** add per-step prompts inside a subcommand — execute it directly. The exception is `/preflight cleanup`, which previews moves and asks before applying (existing behavior).

- **`--yes` / `-y` flag** on the no-subcommand form runs every step without prompting (for unattended bootstrap).

Then follow the steps in order.

### Step 1 - Check Ollama

```bash
OLLAMA="${OLLAMA_HOST:-http://host.docker.internal:11434}"
curl -sf "${OLLAMA}/api/tags" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
print(f'{len(models)} models available')
required = ['qwen3.6:35b']
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

### Step 4 (modifying, prompt) - Install graphify

Ask:
```
Step 4: Install graphify (pip install + skill + always-on hook + git hooks).
        This adds the package, copies a skill into ~/.claude/skills/, and registers a PreToolUse hook.
        Run this step? (y/N)
```

If no, skip to Step 6.

If yes, check if graphify is installed. If not, install it.

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

### Step 5 (modifying, prompt) - Install scripts

Ask:
```
Step 5: Install per-project scripts under scripts/ (preflight, sync, snapshot, staleness-scan, plus
        governance-init, governance-check, memory-promote, agent-gate, adversarial-audit,
        cross-project-ingest, session-synthesize, govern-onboard).
        Run this step? (y/N)
```

If no, skip to Step 6.

If yes, check if the preflight scripts exist in the project. If not, download them from the repo.

```bash
mkdir -p scripts

for script in preflight.sh graphify-rebuild.sh graphify-sync.sh; do
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

### Step 8 (modifying, prompt) - Register persistence

Ask:
```
Step 8: Register a startup hook in ~/.bashrc and ~/.claude/startup/ so the sync daemon
        resumes after container restart.
        Run this step? (y/N)
```

If no, skip to Step 9.

If yes, register the project for container-restart persistence if not already done.

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

### Step 9 (modifying, prompt) - Register cron job

Ask:
```
Step 9: Register a cron entry that runs scripts/graphify-sync.sh every 5 minutes.
        Adds a line to your crontab.
        Run this step? (y/N)
```

If no, skip to Step 10.

If yes:

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

### Step 10 (modifying, prompt) - Scaffold governance

Ask:
```
Step 10: Scaffold the agentic governance layer (CONSTITUTION, AGENTS, OPA policies + tests, memory lifecycle, audit harness).
         This creates ~30 files under governance/, memory/, policy/, .agent/, audits/.
         Run this step? (y/N)
```

If yes, run:

```bash
./scripts/governance-init.sh
./scripts/cross-project-ingest.sh --dry-run --min 2
```

`governance-init.sh` automatically generates `.agent/project-ingest.md` — a comprehensive index of every `.md` file, the graphify graph (if present), all auto-memory entries, every MUST/NEVER/P0/golden-rule directive, plus a synthesis checklist.

**HARD REQUIREMENT before drafting any doctrine in this project:**

1. Read `.agent/project-ingest.md` end-to-end.
2. Open and read every source file it points at — CLAUDE.md, every `docs/*.md`, every memory entry. Do not skim.
3. Answer the synthesis questions at the bottom of the ingest in your reply to the user (domain & purpose, mission target, all features/pipelines/integrations, P0 mandates, domain invariants, existing governance, open questions, anti-patterns).
4. Only THEN propose CONSTITUTION.md / AGENTS.md / etc. content — and show the user the proposed content BEFORE attempting any gated write.

Drafting from session context alone produces "session notes pretending to be a constitution." That is a failure mode the user has explicitly called out. Don't do it.

Then ask:
```
Cross-project ingest found <N> recurring rule(s) from prior projects.
Seed them into this project's PROMOTION_QUEUE for ratification? (y/N)
```

If yes:
```bash
./scripts/cross-project-ingest.sh --min 2
./scripts/govern-onboard.sh --autonomous
```

Then offer the 20-question intake:
```
Run the 20-question onboarding now to fill the canonical docs? (y/N)
```

If yes:
```bash
./scripts/govern-onboard.sh --interactive
```

After all steps, run `./scripts/governance-check.sh` and surface defects.

### Step 11 - Check git status

```bash
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l)
BEHIND=$(git rev-list --count HEAD..@{upstream} 2>/dev/null || echo "?")
AHEAD=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "?")

[ "$UNCOMMITTED" -gt 0 ] && echo "WARN: $UNCOMMITTED uncommitted changes"
[ "$BEHIND" != "?" ] && [ "$BEHIND" -gt 0 ] && echo "WARN: $BEHIND commits behind origin"
[ "$AHEAD" != "?" ] && [ "$AHEAD" -gt 0 ] && echo "WARN: $AHEAD unpushed commits"
```

### Step 12 - Summary

Print a clean summary of what passed, what failed, and what was installed. Keep it concise. Example:

```
Preflight complete.
  Ollama: 45 models (qwen3.6:35b OK)
  Permissions: dangerous mode enabled
  Plugins: autoCompact ON | statusLine configured | ccusage available
  Graphify: 18,928 nodes, 40,536 edges, updated 2h ago
  Token savings: 143x avg reduction (peak 2,206x)
  Sync daemon: running (PID 12345)
  Persistence: cron + startup hook registered
  Git: clean, up to date
```

## Subcommand behavior

Subcommands are the granular form. Inside a subcommand do **not** add per-step prompts — the user has explicitly chosen this action. The exception is `/preflight cleanup`, which previews moves before applying (existing behavior).

- `/preflight check` - Run only the read-only checks (steps 1, 2, 3, 6, 7, 11). No installs, no changes.
- `/preflight install` - Run the modifying-but-not-governance steps (4, 5, 8, 9). Install everything related to graphify, persistence, and cron.
- `/preflight sync` - Run `./scripts/sync-health.sh` for status, or `./scripts/sync-health.sh --restart` to start/recover the daemon. Surfaces last error from `graphify-out/sync.log` on crash. Distinguishes running / crashed / stopped / not-installed.
- `/preflight cleanup` - Run `./scripts/staleness-scan.sh` which uses the graphify graph + import cross-grep + git mtime + filename heuristics to flag files that hit 2+ "stale" signals. Output is a report at `staleness-report.md`; nothing is moved automatically. Run `./scripts/staleness-scan.sh --apply` for interactive per-file move-to-`archive/stale/` (auto-snapshots first). The old name-based reorg shipped in earlier versions was deprecated and removed in 0.7.1.
- `/preflight update` - Run `./scripts/self-update.sh` to pull latest from the claude_preflight repo and reinstall.
- `/preflight soft-refs` - Run `./scripts/soft-references.sh` to generate lightweight overview nodes for large directories excluded from full graphify indexing. Output appears in `graphify-out/SOFT_REFERENCES.md` and `graphify-out/soft_references.json`. Add `--check-stale` to detect overview drift (each source dir's most-recent mtime vs overview mtime) without regenerating.
- `/preflight govern` - Scaffold the agentic governance layer into the project. Runs `./scripts/governance-init.sh` to install: `governance/CONSTITUTION.md`, `GOVERNANCE.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `PROJECT_MEMORY_CONTRACT.md`, `PROMOTION_QUEUE.md`, `policy-map.md`; the `memory/` lifecycle tree (`inbox`, `index`, `active/`, `promoted/`, `stale/`, `rejected/`); `policy/*.rego` modules with tests; `.agent/{project-tier,review-gates,audit-agents}.yaml`; `audits/{findings,playbooks,reports}/`; standard project docs (`STATUS.md`, `PLAN.md`, `docs/ARCHITECTURE.md`, plus `docs/RISKS.md` + `docs/THREAT_MODEL.md` for tier 2+); and a README stub when no README exists. Then offers (with explicit prompts) to run `./scripts/cross-project-ingest.sh --dry-run --min 2` to seed candidates from prior-project memory and `./scripts/govern-onboard.sh --interactive` to walk the 20-question intake. Finishes with `./scripts/governance-check.sh`. Day-to-day governance is the `/govern` skill — `/govern check`, `/govern remember "<rule>"`, `/govern promote`, `/govern audit`, `/govern gate`, `/govern ingest`, `/govern synthesize`, `/govern onboard`.
- `/preflight snapshot` - Capture the project's current state to `archive/snapshot-<timestamp>/` so a regretted change has a one-line rollback. Lightweight: a manifest (file listing + sizes), `working-tree.patch` (uncommitted changes), `state/` (settings.json + cron + .bashrc + startup script), `meta.json`, and a README with the rollback command. Auto-fires before destructive ops (`cleanup --apply`, `governance-init --force`, `self-update`, `staleness-scan --apply`, `fresh`). Subcommands: `./scripts/snapshot.sh create`, `list`, `restore <dir>`, `prune --keep N`. Auto-prunes to the most recent 20.

- `/preflight fresh` - Purge claude_preflight state from this project, then reinstall. Uses the unified snapshot (above) as its first step, plus an extra tarball of `graphify-out/` (regenerable but expensive — 10s of minutes of Ollama work). Per-component prompts (default N each); `--yes` accepts all; `--no-reinstall` purges without reinstalling. Run via `./scripts/fresh.sh` or `./scripts/fresh.sh --yes`.

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
