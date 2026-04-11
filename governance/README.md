# Governance layer

A project-agnostic agentic governance layer: doctrine, memory promotion lifecycle, OPA/Rego gates, adversarial audit hooks. Bundled with `claude_preflight`; installed into target projects by `scripts/governance-init.sh` or `/preflight govern`.

## What it is

Three layers that work together so durable knowledge stops decaying:

1. **Doctrine** — `templates/CONSTITUTION.md`, `GOVERNANCE.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `PROJECT_MEMORY_CONTRACT.md`. Plain text, human-edited, authoritative.

2. **Memory lifecycle** — `templates/memory/`, `PROMOTION_QUEUE.md`, `policy-map.md`. Captures durable instructions, classifies them, promotes them into canonical docs, and records what enforces them.

3. **Executable gates** — `policy/*.rego`, `policy/tests/*_test.rego`, plus the runtime wrappers in `scripts/agent-gate.sh` and `scripts/adversarial-audit.sh`. The decision logic the runtime uses to allow, deny, or require approval for an agent action.

4. **Decision support** — `governance/idea_log.md` (verbatim capture of user's spontaneous thoughts via `scripts/idea-log.sh`) and `scripts/council.sh` (3-stage / 11-call LLM Council for high-stakes decisions and brainstorming, NOT iterative dev review). See sections below.

## Layout

```
governance/
├── README.md
├── templates/                        # copied into target projects
│   ├── CONSTITUTION.md
│   ├── GOVERNANCE.md
│   ├── AGENTS.md
│   ├── INTERACTION_STANDARDS.md
│   ├── ANTI_PATTERNS.md
│   ├── PROJECT_MEMORY_CONTRACT.md
│   ├── PROMOTION_QUEUE.md
│   ├── policy-map.md
│   ├── memory/{inbox,index}.md + active|promoted|stale|rejected/
│   ├── amendments/
│   └── .agent/{project-tier,review-gates,audit-agents}.yaml
└── policy/                           # copied into target projects
    ├── agent.rego                    # top-level dispatcher
    ├── shell.rego
    ├── filesystem.rego
    ├── network.rego
    ├── secrets.rego
    ├── dependencies.rego
    ├── git.rego
    ├── deployment.rego
    ├── review.rego                   # required-review gating
    └── tests/
        ├── shell_test.rego
        ├── git_test.rego
        ├── secrets_test.rego
        └── review_test.rego
```

## What each policy enforces

| Module | Decides | Notable defaults |
|---|---|---|
| `shell.rego` | Shell commands | Denies destructive `rm` variants (incl. `rm -rf .`, `rm -fr *`, `--no-preserve-root`), `mkfs`/`dd`/fork-bomb, `DROP DATABASE`. Denies env-secret disclosure (`printenv`, `env \|`, `echo $AWS_SECRET_*`, etc). Requires approval for `sudo`, package installs, container/orchestration commands, cloud CLIs, network egress. |
| `filesystem.rego` | File ops | Denies access to secret files (`.env`, `id_rsa`, `.pem`). Denies writes to `.git/{objects,refs,HEAD}`. Requires approval for changes to lockfiles, manifests, CI workflows, `policy/`, `governance/`. |
| `network.rego` | Outbound HTTP | Allowlist-based: `github.com`, `pypi.org`, `registry.npmjs.org`, etc. Project supplies its own list via `data.agent.network.allowed_hosts`. |
| `secrets.rego` | Secret access | Default-deny. Reference-only listing is the single allowance. |
| `dependencies.rego` | Add/remove/upgrade | Default require-approval; rejects unpinned adds; allows pinned changes with explicit human approval. |
| `git.rego` | Commit/push/reset/rebase | Aggregates findings via deny-set + approval-set so a single input never triggers conflicting decisions. Denies force-push to protected branches, denies `--no-verify`/skip-hooks. Requires approval for force-push to feature branches, `reset --hard`, rebase of protected branch. |
| `deployment.rego` | Deploys | Tests must pass; security findings open = 0; production additionally requires rollback plan + human approval. |
| `review.rego` | Required-review gating | Author/reviewer must be named (no empty-string bypass). Reviewer ≠ author for non-doc changes. Per change class: doc → none; code → tests + Codex; dependency → + human; policy → devil's advocate + policy tests + human; security → full code battery + security audit + devil's advocate + human; deployment → security battery + regression review + rollback plan + human. |

Run `opa test policy/` to verify all modules. The bundled tests cover 46 cases including the regression suite for the rule conflicts and bypass attempts that earlier revisions had.

## Decision pattern

Modules with multiple potentially-overlapping rules (currently `git.rego`, with `shell.rego` and others to follow) use a deny-set / approval-set aggregation pattern:

```
deny     contains "<reason>" if { ... }
approval contains "<reason>" if { ... }

decision := { allow: false, require_approval: false, reason: join(deny) }
    if count(deny) > 0
decision := { allow: false, require_approval: true,  reason: join(approval) }
    if count(deny) == 0 and count(approval) > 0
decision := { allow: true,  require_approval: false, reason: "..." }
    if count(deny) == 0 and count(approval) == 0
```

This is preferred over per-rule `not other_rule_X` exclusions because adding a new finding cannot inadvertently trigger a complete-rule conflict in OPA.

## Authority model

1. The constitution beats all other prose.
2. Golden rules and standards beat preferences.
3. Executable gates beat agent judgment.
4. Human-approved amendments beat prior constitution text.
5. Current repo state beats stale memory.
6. Agents may propose amendments; agents may not ratify them.

## Two-layer rule

A load-bearing rule lives in at least two layers (doctrine + agent context, or doctrine + executable gate). A critical rule lives in all three. This prevents the failure mode where an instruction exists only as prose and quietly drifts.

## Install into a target project

From inside the target project:

```bash
/preflight govern              # scaffold templates + policies + scripts
/govern check                  # audit governance state (drift, unpromoted memory, missing enforcement)
/govern remember "<rule>"      # capture a durable instruction into memory/inbox
/govern promote                # walk the promotion queue
/govern audit <ref>            # adversarial audit on a git ref
/govern gate <input.json>      # query OPA on an action input
```

## OPA prerequisite

Policies are written for OPA v1 syntax. Install with:

```bash
curl -L -o /usr/local/bin/opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static
chmod +x /usr/local/bin/opa
opa test policy/
```

`scripts/agent-gate.sh` and `scripts/governance-check.sh` degrade gracefully when `opa` is not installed: they report what would be checked and how to install it.

## Tier-aware scaffolding

`governance-init.sh --tier <0..3>` controls how much gets installed:

- **Tier 0** (~9 files): `CONSTITUTION.md`, `AGENTS.md`, `memory/{inbox,index}.md`, `.agent/project-tier.yaml`, plus a stub `README.md`, `STATUS.md`, `PLAN.md`, and `docs/ARCHITECTURE.md`. No policies, no audits, no review subsystem. For sandbox / scratch projects.
- **Tier 1** (~42 files): full doctrine (adds `GOVERNANCE.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `PROJECT_MEMORY_CONTRACT.md`, `PROMOTION_QUEUE.md`, `policy-map.md`), all `policy/*.rego` modules + tests, runtime scripts, audit findings tree, adversarial playbooks, onboarding question bank.
- **Tier 2** (~44 files): adds `docs/RISKS.md` and `docs/THREAT_MODEL.md`. For high-stakes projects (security, financial, data).
- **Tier 3**: same artifacts as tier 2, with stricter `governance-check.sh` enforcement and full 20-question onboarding.

`govern-onboard.sh` automatically reads the tier and asks fewer questions for lower tiers (tier 0 = 5 questions; tier 3 = full 20).

## CI gating

`governance-check.sh --format json` emits a machine-readable summary:

```json
{
  "failures": 0,
  "warnings": 2,
  "pass": true,
  "findings": []
}
```

Useful for blocking PRs in CI: `governance-check.sh --format json | jq -e .pass`. Detailed per-check findings are currently surfaced only in text mode.

## Adversarial audit

`scripts/adversarial-audit.sh` runs the configured reviewers from `.agent/audit-agents.yaml` against a git ref. Default roster: Codex (correctness), devil's advocate (assumptions), security auditor (vulnerabilities), regression hunter (test gaps). The script writes structured findings under `audits/findings/`. Independence is enforced: the author agent may not be the reviewer agent for any non-doc class change (`policy/review.rego`).

The reviewer prompts ship as playbooks under `audits/playbooks/`:

- `devil-advocate.md` — challenges assumptions, hidden failure modes, missing requirements
- `security-auditor.md` — secrets, injection, authz, crypto, supply chain, sandboxing
- `regression-hunter.md` — behavior diff vs callers, removed branches, default flips, test gaps

Every finding produced by these reviewers must end with `PROMOTE TO: task | risk | test | policy | amendment | nothing`. That field is the connection back to governance — a finding that cannot be promoted is dropped.

## PreToolUse policy gate

The bundle ships a Claude Code `PreToolUse` hook (`hooks/pre-tool-policy-gate.sh`) that translates every `Bash`, `Edit`, `Write`, `Read`, and `WebFetch` call into a normalized JSON action descriptor and routes it through `scripts/agent-gate.sh`. The OPA decision becomes the hook's exit code:

- `allow` → exit 0, tool call proceeds
- `require_approval` → exit 0, but the reason is printed to stderr so the agent and the user see it
- `deny` → exit 2, tool call is blocked by Claude Code

When OPA is not installed the hook degrades to advisory mode: the policy decision is reported to stderr but the tool call is allowed (exit 0). This is intentional — earlier revisions defaulted to fail-closed when OPA was missing, which broke agent autonomy in unrelated projects. `install.sh` now installs OPA automatically (Linux + Darwin) so the gate becomes enforcing as soon as the bundle is set up. Disable per-session with `PREFLIGHT_GATE_DISABLE=1`. Registered automatically by `install.sh` as a PreToolUse `*` matcher.

**Approving an `require_approval` decision:** the project-local one-shot marker `.agent/.gate-approve` is the preferred path. Touch it, retry the tool call, the gate consumes (deletes) it on read. There is also `PREFLIGHT_GATE_APPROVE=1` as a fallback, but that variable is shell-global and bleeds into other preflight projects in the same shell — the hook prints a warning when it triggers via the env var. Standing rule for agents: never ask the user to set the global; use `touch .agent/.gate-approve` after showing the proposed content/command.

`scripts/governance-check.sh` warns when this hook is not registered — that means policies exist but are not being enforced at action time.

## Memory lifecycle: ingest → synthesize → onboard

Three pieces let the constitution start non-empty and grow continuously, so the human stops repeating durable instructions.

### Cross-project ingest (`scripts/cross-project-ingest.sh`)

Walks `~/.claude/projects/*/memory/` for every other project the user has touched, classifies the entries it finds (feedback, user, project, reference), counts distinct projects per normalized statement, and seeds candidates into `governance/PROMOTION_QUEUE.md`. A first-run privacy notice fires once per project; `--anonymize` strips prior-project names from the `Source:` field for repos that will be public or shared. Idempotent via `Source-hash` (SHA-256 prefix of normalized statement).

```bash
./scripts/cross-project-ingest.sh             # all candidates, --min 1
./scripts/cross-project-ingest.sh --min 2     # only items recurring across 2+ prior projects
./scripts/cross-project-ingest.sh --anonymize # strip prior-project names from Source
./scripts/cross-project-ingest.sh --dry-run   # report only, write nothing
```

Recommended starting point in a fresh project: `--min 2 --dry-run` to see what's been recurring before flooding the queue.

### Continuous synthesis (`scripts/session-synthesize.sh` + PreCompact hook)

Reads the current project's auto-memory under `~/.claude/projects/<slug>/memory/`, asks Ollama to identify themes the user keeps surfacing but hasn't written down (security focus, methodology preferences, recurring frustrations, conventions), parses JSONL theme objects from the response (handles markdown code-fence wrapping), and appends de-duplicated candidates to the queue.

Auto-fires on Claude Code's `PreCompact` event via `hooks/pre-compact-synthesize.sh`. The hook detaches via `setsid -f` (or `nohup` fallback) and time-bounds at 60s so compaction never blocks. The synthesizer's own urlopen timeout is 50s to fit inside that wrapper.

```bash
./scripts/session-synthesize.sh             # synthesize now
./scripts/session-synthesize.sh --since 7d  # only memory newer than N
SESSION_SYNTHESIS_DISABLE=1 …               # skip entirely (env var)
```

### 20-question onboarding (`scripts/govern-onboard.sh`)

The bank lives at `governance/onboarding/questions.md`. Questions cover identity & purpose, stakes & tier, stack reality, agent permissions, workflow, communication style, history, trust profile. Each question carries `landing` (which doc absorbs the answer) and `policy_hint` (whether the answer should add a `policy-map.md` row).

Two modes:

```bash
./scripts/govern-onboard.sh --interactive   # walk the user through, write YAML
./scripts/govern-onboard.sh --autonomous    # emit defaults derived from the repo
```

Autonomous mode detects languages, default branch, deploy target, secret-file presence, etc. The agent uses these as a starting point and asks only the open questions. The intake's output fills `CONSTITUTION.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `.agent/project-tier.yaml`, and starter rows in `policy-map.md`.

### Together

```
cross-project-ingest   →  PROMOTION_QUEUE.md  ←  session-synthesize  (continuous)
                                  ↓
                          /govern promote
                                  ↓
              CONSTITUTION.md  /  AGENTS.md  /  policy-map.md  /  policy/*.rego
```

Install the layer once, ratify what's already proven recurring, walk the open questions, then never restate a durable rule again.

## Idea log (`scripts/idea-log.sh`)

A living, append-only, profanity-stripped log of the user's spontaneous thoughts at `governance/idea_log.md`. Distinct from the durable-instructions sink (`memory/inbox.md`) and the classified-candidates queue (`PROMOTION_QUEUE.md`).

Trigger phrases that should fire a capture: "I've been thinking", "what if", "wouldn't it be cool", "imagine if", "I noticed", "I had a thought", "we should". Capture in the same response, before continuing whatever else was happening — verbatim quote, not a paraphrase.

```bash
./scripts/idea-log.sh capture "<verbatim quote>" \
    --title "<one-line title>" \
    --context "<situation that prompted it>" \
    --synthesis "<what this becomes if promoted>"
./scripts/idea-log.sh list
./scripts/idea-log.sh status <id> considered
./scripts/idea-log.sh stale --days 30      # report ideas stuck in `captured` > N days
```

Status lifecycle: `captured → considered → inbox-NNN → amendment-NNN → retired-noted`. Format on disk: `## YYYY-MM-DD` day header → `### HH:MM ZONE — title` entry → bold Quote / Context / Status / Synthesis labels → `---` separator. Profanity is regex-stripped (`fuck`/`shit`/etc → `[edited]`) so the log is safe to share.

## LLM Council (`scripts/council.sh`)

For high-stakes decisions and project brainstorming. Reserved for final outputs and genuine multi-option decisions. NOT for every dev iteration — `scripts/adversarial-audit.sh` (Codex + devil's advocate + security + regression) handles iterative code review.

Three stages, eleven model calls, output to `governance/councils/<TS>/`:

1. **Five cognitive lenses** respond to the same question in parallel. Playbooks live at `governance/templates/audits/playbooks/council/`:
   - **Contrarian** (`contrarian.md`) — assume the proposal has a fatal flaw and find it.
   - **First Principles** (`first-principles.md`) — strip back to the actual root requirement.
   - **Expansionist** (`expansionist.md`) — what's the bigger play this could be a step toward.
   - **Outsider** (`outsider.md`) — someone outside the project's worldview reads it cold.
   - **Executor** (`executor.md`) — what does shipping this actually cost in attention and surface area.
2. **Five reviewers** (`peer-review.md`) see the five responses anonymized as A-E (randomized mapping) and answer: strongest / biggest blind spot / what did all five miss.
3. **Chairman** (`chairman.md`) synthesizes everything into Where-Council-Agrees / Where-It-Clashes / Blind-Spots / Recommendation / One-Thing-First, plus a `LOG TO:` routing line (`idea_log` / `promotion_queue` / `amendment` / `task` / `nothing`).

### Run modes

```bash
# Default — uses the intelligence the user is already paying for.
# Script stages all 11 prompts to disk and exits with per-stage instructions.
# The running agent (Claude / Codex / whatever you're using) dispatches each
# prompt via its own Agent / subagent mechanism, writes responses back to the
# staged paths, then re-invokes the script for the next stage.
./scripts/council.sh decide "<question>"                      # --via agent is default
./scripts/council.sh continue 2 governance/councils/<TS>      # after stage 1 responses written
./scripts/council.sh continue 3 governance/councils/<TS>      # after stage 2 responses written

# Headless — for cron / CI / scripted use. Single-model council; chairman
# synthesis tags this as a confidence limitation in its output.
./scripts/council.sh decide "<question>" --via ollama:qwen3.6:35b

# Optional — lets the Contrarian take the explicit anti-position to a stated
# user leaning. The other four lenses stay balanced.
./scripts/council.sh decide "<q>" --leaning "I want to <X>"
```

Real anonymization (separate subagents in `--via agent`) is the design point. Same-context anonymization is theatrical. The agent dispatching subagents in parallel gets both real isolation AND the model the user is paying for.

### Refusals and rate limits

The script refuses validation-seeking framings ("am I right that…", "validate that…", "confirm that…") with a fixed message, because the council finds blind spots, not agreement. Past that floor, the agent must enforce the contextual cases — situations where the user has clearly telegraphed their preferred answer in prior turns also count as validation-seeking.

`governance-check.sh` warns when council usage exceeds 3 runs in 7 days. If you're hitting that ceiling, you're using it as procrastination.

### Trigger phrases

Phrases that should route to the council: "council this", "run the council", "war room this", "pressure-test this", "help me decide" — and only when the question is a genuine multi-option decision with stakes. Document any project-specific trigger phrases in the project's `CONSTITUTION.md`.

## Drafting doctrine — required project ingest

`scripts/project-ingest.sh` writes `.agent/project-ingest.md`: every `.md` file in the project, the graphify knowledge graph (if present), every auto-memory entry for this project, every `MUST` / `NEVER` / `P0` / `golden rule` / `mandate` / `forbidden` directive across the docs, plus the user's accumulated context. Required before drafting any binding doctrine (`CONSTITUTION.md`, `AGENTS.md`, `ANTI_PATTERNS.md`). `governance-check.sh` enforces this as a hard FAIL — drafting from session context produces "session notes pretending to be a constitution," which the user has named as a P0 failure mode.

`scripts/context-pack.sh` aggregates doctrine + memory + status into a single `.agent/context-pack.md` that fits inside an agent's context window without rebuilding the full ingest each session. Use it for routine work; use `project-ingest.sh` only when (re)drafting doctrine.

## Rule-of-law: how strict is "enforced"

`policy-map.md` rows have a status column. `governance-check.sh` treats the values as follows:

| Status | Meaning | Check verdict |
|---|---|---|
| `enforced` | Bound to an executable check (Rego module, hook, CI step) | OK |
| `prose-only-acknowledged` | Explicit human waiver — rule lives only in prose | warn |
| `partial`, `prose-only`, `proposed`, `TODO` | Aspirational, not yet bound | **FAIL** |

Only the explicit waiver is allowed to remain prose-only. Everything else is a hard failure — the whole point of the layer is agent rule-of-law, and a "rule" that has no executable backing is fiction. The check also enforces a doctrine ↔ policy-map sync: every `MUST` / `NEVER` / P0 directive extracted from `CONSTITUTION.md`, `AGENTS.md`, and `CLAUDE.md` must appear in `policy-map.md` with a status, or the check fails.
