# claude_preflight

Per-project Claude Code optimization. Knowledge graph mapping, continuous sync, safe reorg, and plugin setup. Stop hitting usage limits.

Works on new projects and existing ones. Run it at the start of a project or drop it into one that's already active.

## What it looks like

### Validation before restructuring

Preflight checks your environment, models, graph state, and sync daemon before proposing any changes.

![Precheck](images/precheck.png)

### First run output

Full preflight pass showing Ollama connectivity, graphify installation, hook registration, and persistence setup.

![Output](images/output.png)

### Token savings after graphify

After the knowledge graph is built, Claude navigates by structure instead of grepping raw files. Token savings scale with project size.

![Improvements](images/improvement.png)

## Install

```bash
git clone git@github.com:JKSNS/claude_preflight.git /tmp/claude_preflight
cd your-project
/tmp/claude_preflight/install.sh
```

Installs the `/preflight` skill, graphify, scripts, safety hooks, plugin settings (autocompact, statusline, ccusage), and the persistence layer. After install, everything runs through Claude Code.

## Usage

Inside Claude Code:

```
/preflight              # full check and setup
/preflight check        # validate only, no changes
/preflight install      # install everything, skip validation
/preflight sync         # start the graphify sync daemon
/preflight cleanup      # reorganize repo structure
/preflight update       # pull latest from upstream
/preflight soft-refs    # generate overviews for large excluded dirs
/preflight offline      # switch to local Ollama (gemma4:26b + nemotron-cascade-2)
/preflight online       # switch to Anthropic API with Ollama fallback
/preflight profile      # show current model routing profile
```

### Updating an existing install

```bash
./scripts/self-update.sh --check   # check for upstream updates
./scripts/self-update.sh           # pull latest & overwrite all scripts
```

Or from inside Claude Code:
```
/preflight update
```

Self-update clones the latest repo, then re-runs `install.sh --force` which overwrites all scripts, hooks, and skill definitions. Your `.graphifyignore`, graph data, and project-specific config are preserved.

## How it works

### Knowledge graph

Builds a persistent structural map of your codebase using [graphify](https://github.com/safishamsi/graphify). Claude reads the graph report before every search instead of grepping raw files.

Code files are parsed locally via tree-sitter AST — no API calls, no tokens, instant. Semantic extraction for docs and papers routes through local Ollama models instead of Claude subagents.

Token savings: 10-70x for small projects, 100-2000x for large ones.

### What you can do with it

Once the graph is built, Claude reads it before every search. This changes how you can interact with the codebase:

**Onboarding a new contributor:**
```
"How does classify route to specialists?"
"Walk me through the data flow from input to output."
"What are the main abstractions and how do they connect?"
```

**Refactoring analysis:**
```
"Which auto_* helpers duplicate logic?"
"Find all modules that implement retry/backoff patterns."
"What would a consolidated helper look like for these 4 files?"
```

**Impact analysis before touching a god node:**
```
"What breaks if I change ModelConfig?"
"Show everything that depends on KrakenState."
"If I rename ExploitManager, what files need updating?"
```

**Architecture review:**
```
"Why does KrakenState bridge 5 different communities?"
"Are there circular dependencies between modules?"
"Which components are most coupled and should be decoupled?"
```

### The graph is alive

The graph is not a snapshot. It grows and shrinks with your project automatically through persistent scheduled tasks.

**Git hooks** fire on every commit and branch switch. They rebuild the AST layer instantly at zero cost. New files get nodes. Deleted files lose them.

**Cron job** runs every 5 minutes. It diffs files by timestamp, skips anything unchanged, and runs semantic extraction on new or modified docs via Ollama. Zero API cost.

**Container restart hook** resumes the sync daemon automatically when the container reboots. A startup script in `~/.claude/startup/` is sourced from `.bashrc` on every new shell.

All three layers persist independently. If one fails, the others continue. The graph stays current across sessions, branches, and container restarts.

### Soft references

Large directories excluded from full graphify indexing (datasets, benchmarks, generated results) can still be represented in the graph as lightweight overview nodes.

```
/preflight soft-refs                    # auto-detect large dirs
./scripts/soft-references.sh results    # specific directories
```

Generates `graphify-out/SOFT_REFERENCES.md` with file counts, structure, and descriptions extracted from READMEs. No LLM cost.

### Repo cleanup

Before the graph is built, preflight can reorganize scattered files into a clean structure. A clean repo produces a cleaner graph.

```
/preflight cleanup      # preview and apply repo reorganization
/graphify .             # build knowledge graph on clean structure
```

The cleanup tool analyzes your project, detects scattered docs, overlapping directories, root-level clutter, and binary files that should be archived. All moves use `git mv` so full history is preserved.

### Model routing

Claude decides. Ollama executes.

| Task | Route | Cost |
|---|---|---|
| AST / code extraction | tree-sitter (local) | $0 |
| Doc / paper extraction | `gemma4:26b` via Ollama | $0 |
| Architecture decisions | Claude | tokens |
| Bug diagnosis | Claude | tokens |
| Novel code design | Claude | tokens |

The graphify skill checks `PREFLIGHT_EXTRACTION_MODEL` before dispatching subagents. If set to `ollama:<model>`, semantic extraction goes directly to Ollama — Claude orchestrates chunking and merging, Ollama grinds through the files. Falls back to Claude subagents only if Ollama is unreachable.

To apply a profile:
```bash
./scripts/model-profile.sh offline   # gemma4:26b for everything, $0
./scripts/model-profile.sh online    # Claude primary + Ollama fallback
./scripts/model-profile.sh           # show current profile
```

Required Ollama models:
```bash
ollama pull gemma4:26b
ollama pull nemotron-cascade-2
```

### Safety hooks

Three hooks installed globally into `~/.claude/hooks/` with absolute paths — active in every project, not just the one that installed them:

| Hook | Trigger | What it does |
|---|---|---|
| `pre-bash-firewall.sh` | Before every Bash call | Blocks `rm -rf /`, `rm -rf ~`, `mkfs`, `dd if=...of=/dev/sd*`, `DROP DATABASE` |
| `protect-critical-files.sh` | Before Edit/Write | Blocks writes to `.env`, credentials, API keys, `.pem`, `.key` files |
| `post-edit-quality.sh` | After Edit/Write | Auto-formats with ruff (Python) and prettier (JS/TS) |

**CTF / security research**: bypass the firewall for a session:
```bash
export PREFLIGHT_UNSAFE=1
```

### Plugins

Install configures three plugins in `~/.claude/settings.json`:

**autoCompact** — automatically compact the context window when it fills up, keeping long sessions running without manual intervention.

**statusLine** — live status bar at the bottom of every Claude Code session:
```
claude@host:/path/to/project
claude-sonnet-4-6 | ctx: 23% | $0.0142
```

**ccusage** — CLI tool for tracking equivalent API cost across sessions:
```bash
npx ccusage              # cost summary for today
npx ccusage --live       # live usage dashboard
npx ccusage daily        # breakdown by day
```

## Persistence

All sync layers survive container restarts:

- Git hooks in `.git/hooks/`
- Cron job in crontab (every 5 min, skips if nothing changed)
- Startup script in `~/.claude/startup/` sourced from `.bashrc`
- Sync daemon started immediately on install if graph exists

```bash
crontab -l                          # view registered jobs
ls ~/.claude/startup/sync-*.sh      # view registered projects
```

Multiple Claude Code sessions can run against the same project. The sync daemon is the single writer. All sessions read the same graph snapshot. No coordination needed.

## Structure

```
claude_preflight/
├── install.sh              # bootstrap (one-time)
├── uninstall.sh            # clean removal
├── SKILL.md                # /preflight slash command
├── GRAPHIFY.md             # graphify reference
├── VERSION
├── hooks/
│   ├── pre-bash-firewall.sh
│   ├── protect-critical-files.sh
│   └── post-edit-quality.sh
├── profiles/
│   ├── offline.json        # gemma4:26b for everything, $0
│   └── online.json         # Claude primary + Ollama fallback
├── skills/
│   └── graphify/
│       └── SKILL.md        # /graphify slash command (Ollama-aware)
├── images/
│   ├── precheck.png
│   ├── output.png
│   └── improvement.png
├── templates/
│   └── .graphifyignore
└── scripts/
    ├── preflight.sh        # environment validator
    ├── repo-cleanup.sh     # repo reorganization
    ├── graphify-rebuild.sh # manual graph rebuild
    ├── graphify-sync.sh    # continuous sync daemon
    ├── self-update.sh      # pull latest & reinstall
    ├── soft-references.sh  # large dir overview generator
    └── model-profile.sh    # online/offline profile switcher
```

## Environment

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_HOST` | `http://host.docker.internal:11434` | Ollama endpoint |
| `PREFLIGHT_EXTRACTION_MODEL` | unset (Claude subagents) | Set to `ollama:<model>` for local extraction |
| `GRAPHIFY_MODEL` | `gemma4:26b` | Model for semantic extraction |
| `GRAPHIFY_INTERVAL` | `300` | Seconds between sync cycles |
| `PREFLIGHT_UNSAFE` | unset | Set to `1` to bypass bash firewall |

## Security

- Hooks use absolute paths — no project-relative path confusion
- No password piping to sudo — uses `sudo -n` (passwordless) or root check only
- Hook scripts are `755` — not world-writable
- Protected file list blocks writes to `.env`, credentials, keys, secrets
- Bash firewall blocks truly destructive commands (not normal git or file ops)
- No secrets stored in any config file

## Uninstall

```bash
/tmp/claude_preflight/uninstall.sh
```

## Related

- [claude_setup](https://github.com/JKSNS/claude_setup) - containerized Claude Code environment, safety hooks, base configuration
- [claude_plugins](https://github.com/JKSNS/claude_plugins) - autoresearch, project management, media generation, custom MCP servers

## License

CC BY-NC 4.0. Free to use and fork. Credit required. No commercial use.
