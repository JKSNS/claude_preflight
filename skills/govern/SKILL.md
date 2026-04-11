---
name: govern
description: Project governance layer - constitution, memory promotion, OPA/Rego gates, adversarial audits
trigger: /govern
---

# /govern

Operate the governance layer that `/preflight govern` (or `scripts/governance-init.sh`) installs into the project. Capture durable instructions, walk the promotion queue, query policy gates, and run adversarial audits.

## Usage

```
/govern                          # show governance status (alias for /govern check)
/govern check                    # audit governance state (drift, unpromoted memory, missing enforcement)
/govern remember "<rule>"        # capture a durable instruction into memory/inbox + PROMOTION_QUEUE
/govern list                     # show inbox + pending promotion candidates
/govern promote                  # walk the candidate list interactively
/govern gate <input.json>        # query OPA on a normalized action input
/govern audit                    # run adversarial audit on current diff
/govern audit <ref>              # run adversarial audit on <ref>..HEAD
/govern audit triage             # walk audits/findings/open.md interactively
/govern context-pack             # generate .agent/context-packs/current.md
/govern policy explain <input>   # show OPA trace for a debugging input
/govern test                     # run opa test on policy/
/govern install                  # scaffold the governance layer if not yet present
/govern onboard                  # walk the 20-question intake to fill canonical docs
/govern onboard --autonomous     # emit autonomous defaults derived from the repo
/govern ingest                   # seed candidates from prior-project memory
/govern ingest --min 2           # only candidates that recurred across N projects
/govern ingest --anonymize       # strip prior-project names from Source field
/govern ingest --dry-run         # report only, write nothing
/govern synthesize               # distill the current session's themes into candidates
/govern synthesize --since 7d    # only memory newer than N (default 30d)
```

## When invoked

If no subcommand is given, run `/govern check` and print a one-screen summary.

### check

Run `./scripts/governance-check.sh`. Surface failures and warnings prominently. If the project tier or required artifacts are missing, recommend `./scripts/governance-init.sh` (with the appropriate `--tier` flag). If `policy-map.md` rows point at missing enforcement files, list them. If `memory/inbox.md` has un-promoted entries older than the threshold, name them and propose targets.

### remember "<rule>"

Run:

```bash
./scripts/memory-promote.sh capture "<rule>"
```

This appends the verbatim statement to `memory/inbox.md` and creates a numbered candidate in `governance/PROMOTION_QUEUE.md`. Then propose the target canonical doc:

- rule of conduct → `governance/CONSTITUTION.md` or `governance/AGENTS.md`
- communication preference → `governance/INTERACTION_STANDARDS.md`
- failure mode → `governance/ANTI_PATTERNS.md`
- workflow rule → `governance/GOVERNANCE.md`
- enforceable rule → matching `policy/*.rego` and a row in `governance/policy-map.md`

End with: "Propose promotion now? (y/n)" and, if yes, perform the promotion edits and update `memory/index.md`.

### list

Run `./scripts/memory-promote.sh list`. Show inbox entries and candidates side by side.

### promote

Read `governance/PROMOTION_QUEUE.md`. For each entry whose `Status:` is `candidate`:

1. Read its statement, type, target doc.
2. Show the proposed edit to the human.
3. On approval, write the entry into the target doc, add a row to `governance/policy-map.md` if enforceable, set `Status: promoted`, and move the matching `memory/inbox.md` entry to `memory/promoted/`.
4. Update `memory/index.md` if this introduces a new active memory.

### gate <input.json>

```bash
./scripts/agent-gate.sh "$1"
```

Expects a JSON action descriptor on stdin or as a file path. Returns the OPA decision. If `opa` is not installed, print the install command:

```
curl -L -o /usr/local/bin/opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static
chmod +x /usr/local/bin/opa
```

### audit [<ref>]

```bash
./scripts/adversarial-audit.sh "${1:-HEAD}"
```

Runs the configured reviewers from `.agent/audit-agents.yaml` against the diff. Default reviewers: `codex_reviewer`, `devil_advocate`, `security_auditor`, `regression_hunter`. Codex requires the `codex` CLI; the others use Ollama. The script writes a structured report under `audits/reports/` and a triage pointer in `audits/findings/open.md`.

After the audit finishes, summarize: total findings, severity breakdown, and the top three items that should be triaged first. Surface any finding flagged as an `amendment_candidate` — those become governance change proposals.

### test

```bash
opa test policy/
```

If `opa` is not installed, suggest the install command and explain that the Rego files still serve as a specification for the gate.

### install

If `governance/CONSTITUTION.md` or `policy/agent.rego` is missing, run:

```bash
./scripts/governance-init.sh
```

If those files came from an older bundle, suggest:

```bash
./scripts/governance-init.sh --force
```

with the warning that `--force` overwrites any local edits to the templates.

### onboard

The 20-question intake that fills `CONSTITUTION.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, `.agent/project-tier.yaml`, and starter rows in `policy-map.md`. The question bank lives at `governance/onboarding/questions.md`.

Two modes:

**Interactive** — walk the user through the 20 questions and write answers to `.agent/onboarding-answers.yaml`:

```bash
./scripts/govern-onboard.sh --interactive
```

**Autonomous** — emit defaults derived from the repo (manifests, CI, branch protection, secret-file presence). Use this as the starting point, then ask the user only the open questions:

```bash
./scripts/govern-onboard.sh --autonomous
```

In autonomous mode the agent should:

1. Run `./scripts/cross-project-ingest.sh --dry-run --min 2` first so the user can ratify rules they've already proven recurring.
2. Read the autonomous defaults.
3. Ask only Q12 (forbidden), Q18 (frustrations), Q19 (incidents), and any default whose confidence is low.
4. After answers are gathered, draft the canonical docs in a single pass and present the diff for human approval before writing.

### ingest

Walks `~/.claude/projects/*/memory/`, finds durable items the user has captured in prior projects (feedback memories, anti-patterns, interaction preferences), and seeds them as candidates here. Idempotent — runs again won't duplicate via `Source-hash`.

```bash
./scripts/cross-project-ingest.sh                  # all prior memories
./scripts/cross-project-ingest.sh --dry-run        # report only
./scripts/cross-project-ingest.sh --min 2          # require recurrence
./scripts/cross-project-ingest.sh --anonymize      # strip prior-project names
```

When a candidate appears in 2+ prior projects, mark it as a strong universal-rule candidate. When it appears once, low-confidence — propose for ratification only.

A privacy notice fires on first run per project, warning that the `Source:` field will list prior-project slugs (the `Statement:` field carries the original memory text). Pass `--anonymize` to strip the slugs for repos that will be public or shared. The acknowledgement marker lives at `.agent/.cross-project-ingest-acknowledged` and is added to `.gitignore` by `install.sh`.

### synthesize

Reads the current project's auto-memory under `~/.claude/projects/<slug>/memory/`, asks Ollama to identify themes (security inclinations, methodology preferences, recurring frustrations, conventions used but never written down), and appends each as a candidate. Idempotent via `Source-hash`.

```bash
./scripts/session-synthesize.sh                  # synthesize now
./scripts/session-synthesize.sh --dry-run        # report only
./scripts/session-synthesize.sh --since 7d       # only memory newer than N
```

Auto-fires when:

- Claude Code emits `PreCompact` (handled by `~/.claude/hooks/pre-compact-synthesize.sh`)
- Graphify rebuilds (extend the existing `git/hooks/post-commit` if desired)

Disable with `SESSION_SYNTHESIS_DISABLE=1` in the environment.

## Authority model

When acting on behalf of any subcommand:

1. The constitution beats other prose guidance.
2. Executable gates (Rego, hooks, CI) beat agent judgment.
3. The agent that authored a non-doc change may not be the agent that approves it (`policy/review.rego`).
4. Durable human instructions belong in `memory/inbox.md` plus `PROMOTION_QUEUE.md` on first capture; a second utterance of the same instruction is a governance defect and must be surfaced.
5. Critical rules require enforcement, not prose.

## Output style

Lead with the result. Reference files as `path:line`. Keep status updates short. When proposing a promotion, show the exact diff that will be applied.
