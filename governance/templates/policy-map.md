# POLICY MAP

Rule → enforcement table. The bridge between doctrine and executable checks. Every rule that the project considers binding belongs here, with a clear pointer to whatever actually enforces it.

## Format

| Rule | Source | Canonical doc | Memory pointer | Enforced by | Status |
|---|---|---|---|---|---|

- **Rule** — one-line plain statement.
- **Source** — `human` | `incident` | `external-requirement` | `derived`.
- **Canonical doc** — file path under this repo where the rule lives in prose.
- **Memory pointer** — file under `memory/active/` that loads it into agent context.
- **Enforced by** — `policy/<file>.rego` | `scripts/<file>.sh` | `hooks/<name>` | `ci/<workflow>` | `manual`.
- **Status** — `enforced` | `partial` | `prose-only` | `proposed`.

## Starter rows

| Rule | Source | Canonical doc | Memory pointer | Enforced by | Status |
|---|---|---|---|---|---|
| Agents may not access secrets | derived | `CONSTITUTION.md` | `memory/active/security.md` | `policy/secrets.rego` | enforced |
| Commands must not disclose secret-shaped environment values | derived | `AGENTS.md` | `memory/active/security.md` | `policy/shell.rego` | enforced |
| Destructive `rm` of cwd, wildcards, or with `--no-preserve-root` is forbidden | derived | `AGENTS.md` | `memory/active/security.md` | `policy/shell.rego` + `hooks/pre-bash-firewall.sh` | enforced |
| Dependency changes require approval | derived | `AGENTS.md` | `memory/active/workflow.md` | `policy/dependencies.rego` + `policy/review.rego` | enforced |
| Production deployment requires human approval and rollback plan | derived | `CONSTITUTION.md` | `memory/active/deployment.md` | `policy/deployment.rego` | enforced |
| Security-sensitive changes require human approval | derived | `CONSTITUTION.md` | `memory/active/workflow.md` | `policy/review.rego` | enforced |
| The reviewer agent may not equal the author agent for non-doc changes | derived | `AGENTS.md` | `memory/active/workflow.md` | `policy/review.rego` | enforced |
| Author and reviewer must be named (empty-string bypass closed) | derived | `AGENTS.md` | `memory/active/workflow.md` | `policy/review.rego` | enforced |
| Force push to a protected branch is forbidden | derived | `AGENTS.md` | `memory/active/workflow.md` | `policy/git.rego` | enforced |
| Skipping git hooks is forbidden | derived | `AGENTS.md` | `memory/active/workflow.md` | `policy/git.rego` | enforced |
| Audit log paths must resolve inside the project tree | derived | `AGENTS.md` | `memory/active/security.md` | `scripts/agent-gate.sh` | enforced |
| Durable human instructions must be promoted, not repeated | human | `PROJECT_MEMORY_CONTRACT.md` | `memory/active/workflow.md` | `scripts/governance-check.sh` | enforced |
| Duplicate capture of the same durable instruction is a defect | derived | `PROJECT_MEMORY_CONTRACT.md` | `memory/active/workflow.md` | `scripts/governance-check.sh` | enforced |
| Architecture claims must match repo state | derived | `ANTI_PATTERNS.md` | `memory/active/workflow.md` | `scripts/governance-check.sh` | enforced |
| Agents may propose amendments; agents may not ratify them | human | `CONSTITUTION.md` | `memory/active/workflow.md` | `policy/review.rego` | enforced |
| Doctrine drafted from session context (without project-ingest) is forbidden | human | `AGENTS.md` | `memory/active/workflow.md` | `scripts/project-ingest.sh` + `scripts/governance-check.sh` | enforced |

## Maintenance

- Every entry must be updatable by `scripts/memory-promote.sh` when a candidate is promoted.
- `scripts/governance-check.sh` warns on rows where Status is `enforced` but the Enforced-by file does not exist.
- `scripts/governance-check.sh` warns on rows where Status is `prose-only` for a rule whose Source is `human` or `incident` (those should usually escalate).
