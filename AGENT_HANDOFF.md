# Agent handoff

If you are an agent that was just handed this repo URL and asked to integrate it into a project, **read this file end-to-end before doing anything else**. This is your session-start contract.

This file is the entry point for every fresh agent landing in a project that uses claude_preflight. It tells you what to do, in what order, and what bar you must hit before taking any action on the user's behalf.

## What you're holding

claude_preflight is a per-project governance + token-savings + agent-rule-of-law layer. Three things it gives the project:

- **Guardrails** — OPA/Rego policy gates wired into a `PreToolUse` hook, plus safety hooks for destructive shell, secret access, file protection. Every tool call you make is evaluated. You cannot bypass; you can only request approval.
- **Doctrine** — `governance/CONSTITUTION.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `policy-map.md`. The project's binding rules, what's enforced, what's prose-only.
- **Continuous knowledge promotion** — memory inbox → promotion queue → canonical doc → enforcement. Cross-project ingest from prior project memories. Session synthesis on `PreCompact`. Project ingest before any doctrine drafting.

You did not write this layer. The user installed it because they want their agents bounded, audited, and mission-aligned. Treat it as the law of this project.

## Your mandatory first session, in order

### 1. Verify install + governance state

```bash
./scripts/preflight.sh           # environment validator
./scripts/governance-check.sh    # governance audit
```

If `governance-check` reports failures, surface them to the user before doing anything else. Do not proceed past unresolved failures.

### 2. Build the project ingest if missing or stale

```bash
./scripts/project-ingest.sh      # writes .agent/project-ingest.md
```

This walks every `.md` in the project, the graphify knowledge graph (if present), every auto-memory entry for this project, every `MUST` / `NEVER` / `P0` / `golden rule` / `mandate` directive across the docs, plus the user's accumulated context.

### 3. Read .agent/project-ingest.md end-to-end

Do not skim. Do not summarize internally and move on. Read every section.

### 4. Open every source file the ingest points at

The ingest is an index. The bodies live in:

- `CLAUDE.md` — the project's existing agent contract. This is usually the highest-density doctrine in the project.
- `governance/CONSTITUTION.md` — formal doctrine, if scaffolded
- `governance/AGENTS.md` — agent behavior contract
- `governance/ANTI_PATTERNS.md` — known failure modes the user has called out before
- All `docs/*.md` — research direction, architecture, mission, roadmap
- `~/.claude/projects/<slug>/memory/*.md` — the user's accumulated wisdom for this specific project (preferences, corrections, incidents, lessons)
- `memory/index.md` — promoted active memories
- `STATUS.md`, `PLAN.md` — what's true now, what's planned

### 5. Synthesize what the project IS

Before drafting anything or taking any action, write back to the user with answers to these questions, sourced from the ingest:

- **Domain & purpose**: in one paragraph, what does this project do? Who uses it? What problem does it solve?
- **Mission target**: what is the project's primary success metric? (revenue, latency, accuracy, deliverable, throughput, etc.) Cite the source.
- **All major features / pipelines / integrations**: list every one mentioned across the docs — research pipelines, data sources, third-party integrations, social-media pulls, model integrations, deployment targets. Do not omit something because it isn't current work.
- **P0 mandates**: every `MUST` / `NEVER` / `P0` / `golden rule` / `mandate` / `forbidden` line from the directive grep. The constitution must encode all of these.
- **Domain invariants**: facts that must always hold (data integrity, regulatory, financial, security, mission-specific).
- **Existing governance**: if `CLAUDE.md`, `AGENTS.md`, `GOVERNANCE.md`, or `governance/*` already exist, your work must FAITHFULLY ENCODE them, not replace them with generic templates.
- **User preferences**: every recurring correction, communication style, or workflow preference the user has expressed across their auto-memory. The handoff goal is mission alignment with what THIS user wants, not what your training distribution suggests is generic best practice.
- **Open questions / contested decisions**: anything in `OPEN_QUESTIONS`, TODO files, or amendment proposals that hasn't been resolved.
- **Anti-patterns from history**: every "we got burned by X" story in memory or in any incident write-up.

Cite the source for every claim — `CLAUDE.md:42`, `docs/X.md`, `memory/feedback_destructive_actions.md`. The user must be able to verify what came from where.

### 6. Wait for user confirmation before acting

Your synthesis from step 5 is a hypothesis. Show it to the user. Ask: "is this an accurate read of the project? What did I miss? What did I get wrong?"

Do not take action until the user explicitly confirms or corrects you. Mission misalignment from agent confidence is more expensive than the few seconds of waiting for confirmation.

### 7. Drafting doctrine is iterative — never one-shot

When you draft `CONSTITUTION.md`, `AGENTS.md`, `ANTI_PATTERNS.md`, or any binding doctrine for the project:

1. Show the **full proposed content** in chat first. Inline. The user must be able to read it without opening a file.
2. Ask explicitly for redlines, additions, removals, rephrasings. The first draft is a strawman, not a final.
3. Iterate as many rounds as the user wants. They will tell you what's missing, what's shallow, what's wrong, what's project-irrelevant. Take the feedback and re-draft. Show the new version inline again.
4. Do not write the file until the user explicitly says "yes, write it" (or equivalent). Approving a v1 strawman is rare; v3-v5 is normal.
5. After every revision, re-read `.agent/project-ingest.md` and ask yourself: did I miss a feature, pipeline, mandate, integration, or memory entry that the new version needs to encode? Constitution depth comes from breadth of what's encoded, not eloquence.

The failure mode this prevents: drafting from session context, calling it v1, asking the user to approve a write — and producing "session notes pretending to be a constitution." The user has explicitly named this as a P0 failure mode. Don't repeat it.

## Forever (after the first session)

These are the standing rules — every session, every action, no exceptions:

- **Before any approval-gated tool call** (writes to `governance/`, `policy/`, lockfiles, CI, deps, deployment), show the user the proposed content/command first. Then `touch .agent/.gate-approve` (project-local, one-shot). Never ask the user to set a global env var.
- **Before drafting any doctrine** (`CONSTITUTION.md`, `AGENTS.md`, `ANTI_PATTERNS.md`, etc.), re-run `./scripts/project-ingest.sh` and read the resulting file. Drafting from session context produces session notes pretending to be doctrine — explicitly forbidden.
- **Before any destructive operation** (`fresh`, `cleanup --apply`, `governance-init --force`, `self-update`, `staleness-scan --apply`), the bundle takes a snapshot automatically. If you are doing something destructive that the bundle doesn't snapshot for you, run `./scripts/snapshot.sh create --trigger <reason>` first.
- **Treat executable checks as authoritative over prose** — `policy/*.rego`, hooks, CI, `governance-check.sh` outputs are the law. Doctrine that contradicts them is stale doctrine.
- **Reviewer agent ≠ author agent** for any non-doc change. `policy/review.rego` enforces this.
- **Capture durable user instructions** to `memory/inbox.md` and add a `PROMOTION_QUEUE.md` candidate in the same response. If you find yourself being asked the same thing twice, that's a governance failure — the rule must be promoted, not repeated.
- **After meaningful work**, update `STATUS.md` with: changed files, what was verified, what was not, residual risk, recommended next step.

## Patterns this bundle supports — adopt as appropriate to the project

These are not features you have to use everywhere. They are well-tested patterns proven impactful in real projects. Pattern-match against what the project needs and adopt the ones that fit. The bundle ships scripts/templates for some; others are concepts you encode directly into the project's `CONSTITUTION.md` / `AGENTS.md`.

**Idea log — `governance/idea_log.md` (script: `scripts/idea-log.sh capture "<quote>"`)**
A living, append-only, profanity-stripped log of the user's spontaneous thoughts. When the user says "I've been thinking", "what if", "I want", "wouldn't it be cool if", "I noticed", "imagine if", "I had a thought", "we should" — capture the verbatim quote here, in the same response, before continuing whatever you were doing. Status lifecycle: `captured → considered → inbox-NNN → amendment-NNN → retired-noted`. Distinct from `memory/inbox.md` (durable instructions) and `PROMOTION_QUEUE.md` (classified candidates). The idea log is for raw thought; the queue is for classified candidates.

**Trigger-phrase routing**
Different intent-classes route to different sinks. Generic split:
- "from now on", "every time", "no exceptions", "this should be a rule", "memorialize this" → durable rule → `memory/inbox.md` + `PROMOTION_QUEUE.md` candidate
- "I've been thinking", "what if", "imagine if", "wouldn't it be cool" → idea → `governance/idea_log.md`
- "council this", "run the council", "war room this", "pressure-test this", "help me decide" → high-stakes decision → `scripts/council.sh decide` (output to `governance/councils/<TS>/`). Only invoke for genuine multi-option decisions with stakes; do NOT invoke on simple yes/no, factual lookups, casual "should I" without a meaningful tradeoff, or questions where the user has clearly telegraphed their preferred answer in prior turns (validation seeking).

Council is reserved for final outputs and project brainstorming, not iterative dev audits — the existing `scripts/adversarial-audit.sh` (Codex + devil's advocate + security + regression) handles dev iteration. Don't run a council more than ~once a day; if you're hitting that ceiling, you're using it as procrastination. The bundle's `governance-check.sh` warns when council usage exceeds 3 runs in 7 days.

**Council run mode — `--via agent` is the default.** The script does not call any model itself in this mode; it stages the 11 prompts to disk in three rounds and prints "AGENT, DO THIS:" instructions. You — the agent the user is paying for — dispatch each prompt via your own `Agent` / subagent mechanism, write each response back to the staged path, and then re-invoke `scripts/council.sh continue <stage> <session-dir>` to advance. Stage 1: spawn 5 lens subagents in parallel. Stage 2: spawn 5 reviewer subagents in parallel against the anonymized A-E mapping. Stage 3: one chairman subagent. After the chairman writes `stage3-synthesis.md`, read its trailing `LOG TO:` line and route accordingly (auto-log to idea_log via `scripts/idea-log.sh capture` when it says `idea_log`). Headless mode `--via ollama:<model>` exists for cron / CI but is single-model — chairman synthesis flags this as a confidence limitation. Never default to ollama when the user is paying for a stronger model.

Project-specific intent classes (e.g., R&D session triggers) get their own routing. Document the trigger phrases in the project's `CONSTITUTION.md` so future-you (and other agents) recognize them.

**Amendment tier ladder**
For any change to the project's binding doctrine, classify by tier before proposing:
- **Tier A** — text only, no invariant change (rewording, formatting). Just write it.
- **Tier B** — adds, removes, or weakens an invariant. Requires devil's-advocate review + an incident report or 2-week observation justifying the change.
- **Tier C** — policy code (Rego, hooks, binaries). Requires Tier B + failing-then-passing tests under `policy/tests/` + `opa test policy/` green.
Agents draft amendments. Humans ratify. The asymmetry is intentional: easy to add precision, hard to weaken invariants.

**Verbatim refusal phrasings**
When a P0 gate fires, the agent emits a fixed, greppable refusal string defined in the project's `CONSTITUTION.md`. Paraphrasing IS the violation. Example shape: `REFUSED — <rule> at <location>: <one-line reason>. <Required action> before proceeding.` Greppability lets the project audit "did the agent actually refuse, or did it soften the language?"

**Living docs**
Some docs are state, not history. They reflect what is true now and have anti-staleness rules. The bundle ships `scripts/context-pack.sh` and `scripts/project-ingest.sh` as living docs — they're regenerated, not edited. Adopt the same pattern for project-specific living docs (research README, current-state index, deployment status). Rule of thumb: if mtime > 7 days, regenerate or warn.

**Pre-presentation adversarial pass**
For substantive presentations to the user (top-K rankings, recommendations, quantified results, strategic decision proposals) — not status pings or single-fact answers — run an adversarial review (Codex + devil's-advocate ≥3 attacks) BEFORE showing the user. Surface the verdict + attacks inline. The bundle ships `scripts/adversarial-audit.sh` for the on-demand version; the pattern is that this becomes default-on for high-stakes findings.

**Reading order**
Define a canonical sequence of N docs every new human or AI reads when joining the project. The bundle's default sequence is in `AGENT_HANDOFF.md` step-by-step. The project should specialize: which `docs/*.md` files belong in the canonical reading list? Order matters. Document it in `governance/CONSTITUTION.md` so a new agent doesn't have to guess.

## Where to look when you're confused

| Confused about | Read this |
|---|---|
| What this project IS | `.agent/project-ingest.md` (rebuild if stale) |
| The project's binding rules | `governance/CONSTITUTION.md` + `CLAUDE.md` |
| How you're supposed to behave | `governance/AGENTS.md` + `governance/INTERACTION_STANDARDS.md` |
| Known failure modes | `governance/ANTI_PATTERNS.md` |
| What's enforced and how | `governance/policy-map.md` |
| The user's accumulated context | `~/.claude/projects/<slug>/memory/` + `memory/index.md` |
| The current state of work | `STATUS.md` + `PLAN.md` |
| What lifecycle a memory item is in | `governance/GOVERNANCE.md` |
| Why a tool call was blocked | `./scripts/agent-gate.sh --explain <input.json>` |

## What you should write back to the user as your first message

A reply structured roughly like this. Adapt to the project, but hit every section:

```
I just landed in this project. I've read the handoff and ingested:
- N project docs (list the most important)
- M memory entries from your prior context for this project
- The CLAUDE.md (cite the head sections you saw)
- The graphify knowledge graph (N nodes, M edges, K communities)
- All N MUST/NEVER/P0 directives from the doc grep

My read of the project:
- Domain: <one paragraph, sourced>
- Mission target: <metric, sourced>
- Major features/pipelines: <list, sourced>
- P0 mandates I must encode: <list, sourced>
- User preferences I picked up: <list, sourced>

What I think is currently true:
- <facts from STATUS.md, recent commits, recent work>

What I'm uncertain about:
- <list of open questions, gaps in the ingest, contested doctrine>

Before I take any action: is this an accurate read? What did I miss? What did I get wrong?
```

Wait for the user's response. Then proceed.

## If anything in this handoff conflicts with the project's CLAUDE.md or governance/

The project's own doctrine wins. This handoff is the bundle's default; the project may have specialized or overridden any section. Cite the conflict to the user before acting.
