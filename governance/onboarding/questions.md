# Onboarding question bank

The 20-question intake that fills the canonical docs on first install. Used by `scripts/govern-onboard.sh` in interactive mode and by `/govern onboard` in autonomous mode (where the agent answers from repo evidence + cross-project memory and asks only for clarification).

Each question carries: `id`, `category`, `prompt`, `default` (autonomous baseline), `landing` (which doc absorbs the answer), and `policy_hint` (whether the answer should add a row to `policy-map.md`).

## 1. Identity & purpose

### Q1 — One-line purpose
- **prompt**: In one sentence, what does this project do?
- **default**: derive from `README.md` first paragraph if present
- **landing**: `governance/CONSTITUTION.md` Core invariants
- **policy_hint**: no

### Q2 — Primary users
- **prompt**: Who uses this project? (you only / a small team / external customers / autonomous agents)
- **default**: `you only`
- **landing**: `governance/CONSTITUTION.md`
- **policy_hint**: no

### Q3 — Project lifetime
- **prompt**: Is this scratch / WIP / shipped / long-running production?
- **default**: derive from git log frequency + presence of CI
- **landing**: `governance/CONSTITUTION.md`
- **policy_hint**: no

## 2. Stakes & tier

### Q4 — Tier
- **prompt**: Tier 0 (sandbox) / 1 (shipping) / 2 (high-stakes: security/data/financial) / 3 (autonomous, multi-agent, long-running production)
- **default**: 1
- **landing**: `.agent/project-tier.yaml`
- **policy_hint**: yes (gates the artifacts required by `governance-check`)

### Q5 — Blast radius of a bad change
- **prompt**: If an agent ships a bad change here unmonitored, what's the worst case? (lint warning / failing test / data loss / financial loss / production outage / security incident)
- **default**: derive from tier
- **landing**: `governance/RISKS.md` (created on first use)
- **policy_hint**: yes (drives required review gates)

### Q6 — Data & secret sensitivity
- **prompt**: What sensitive material is in or accessed by this repo? (none / API keys / customer data / financial accounts / private keys / health data)
- **default**: scan for `.env`, `secrets/`, `credentials*` in repo
- **landing**: `governance/THREAT_MODEL.md` (tier 2+)
- **policy_hint**: yes (`policy/secrets.rego` allowlist)

## 3. Stack reality

### Q7 — Languages & frameworks
- **prompt**: Primary languages, frameworks, runtimes?
- **default**: detect from manifests (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.)
- **landing**: `governance/CONSTITUTION.md` Core invariants → "Stack"
- **policy_hint**: no

### Q8 — Build / test / lint
- **prompt**: How are tests run? lint? build?
- **default**: detect from manifests + `Makefile` + CI configs
- **landing**: `docs/COMMANDS.md` (created on first use)
- **policy_hint**: no

### Q9 — Deploy target
- **prompt**: Where does this deploy to? (nowhere / static site / container registry / k8s / cloud function / direct ssh)
- **default**: detect from `Dockerfile`, `terraform/`, `.github/workflows/deploy*`
- **landing**: `governance/CONSTITUTION.md` Core invariants
- **policy_hint**: yes (`policy/deployment.rego` environment list)

## 4. Agent permissions

### Q10 — What can the agent do without asking?
- **prompt**: List the operations you want the agent to perform freely (e.g., run tests, edit code in src/, read repo, query graphify).
- **default**: read everything; write in src/, tests/, docs/; run tests
- **landing**: `governance/AGENTS.md` Required behavior
- **policy_hint**: yes (`policy/filesystem.rego` allowlist)

### Q11 — What requires approval?
- **prompt**: List operations that always need a thumbs-up first.
- **default**: dependency changes, CI workflow edits, deploys, force push, package install
- **landing**: `governance/AGENTS.md`
- **policy_hint**: yes (`policy/dependencies.rego`, `policy/git.rego`, `policy/deployment.rego`)

### Q12 — What is forbidden?
- **prompt**: What may an agent never do here, even with approval?
- **default**: read secret files, force-push to main, skip git hooks, disable failing tests
- **landing**: `governance/CONSTITUTION.md` Core invariants
- **policy_hint**: yes (`policy/secrets.rego`, `policy/git.rego`, `policy/shell.rego`)

## 5. Workflow

### Q13 — How do changes land?
- **prompt**: Direct commits to main / feature branches + PR / forked PR + review?
- **default**: detect from `.git/refs/heads/`, default branch protection
- **landing**: `governance/GOVERNANCE.md` Amendment process
- **policy_hint**: yes (`policy/git.rego` protected_branches)

### Q14 — Required reviewers
- **prompt**: For non-doc changes, who reviews? (just you / Codex only / Codex + devil's advocate / human + Codex / full battery)
- **default**: tier-driven (tier 1: Codex; tier 2: + devil's advocate; tier 3: + security audit + human)
- **landing**: `.agent/review-gates.yaml`
- **policy_hint**: yes (`policy/review.rego`)

### Q15 — CI gates
- **prompt**: What must be green before a change is considered done? (tests / lint / type-check / security scan / build)
- **default**: detect from CI yaml
- **landing**: `governance/AGENTS.md` Self-review
- **policy_hint**: no

## 6. Communication

### Q16 — Output style
- **prompt**: Terse + direct / explanatory + thorough?
- **default**: derive from cross-project memory if present, else terse
- **landing**: `governance/INTERACTION_STANDARDS.md` Output
- **policy_hint**: no

### Q17 — Status updates
- **prompt**: Where do meaningful work summaries go? (`STATUS.md` / commit messages / PR descriptions / chat only)
- **default**: `STATUS.md`
- **landing**: `governance/AGENTS.md` Required behavior
- **policy_hint**: no

## 7. History

### Q18 — Recurring frustrations
- **prompt**: What have you had to repeat to agents on past projects?
- **default**: read promoted candidates from cross-project-ingest output
- **landing**: `governance/ANTI_PATTERNS.md`
- **policy_hint**: maybe (depends on category)

### Q19 — Past incidents
- **prompt**: Has an agent ever broken something here or in a similar project? What broke and what should have prevented it?
- **default**: read auto-memory entries with `incident` or `failure` keywords
- **landing**: `governance/ANTI_PATTERNS.md` with provenance
- **policy_hint**: yes (the prevention is the new policy)

### Q20 — Trust profile
- **prompt**: Which subagents, MCP tools, or skills are trusted? Which are not?
- **default**: list what's installed; ask only if anything looks suspicious
- **landing**: `governance/AGENTS.md` Required behavior
- **policy_hint**: no

## Inference shortcuts

In autonomous mode, the agent should:

- Skip Q1, Q7, Q8, Q9 if it can derive them from the repo with high confidence.
- Skip Q3, Q4, Q5 if `.agent/project-tier.yaml` already exists with non-default values.
- Always ask Q12 (forbidden) and Q18 (frustrations) explicitly — these are user-only.
- Run `cross-project-ingest --dry-run` before asking Q11, Q12, Q16, Q18 so the user can ratify or reject prior decisions instead of restating them.
