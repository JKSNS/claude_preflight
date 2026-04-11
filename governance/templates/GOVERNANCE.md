# GOVERNANCE

How project knowledge becomes durable, gets enforced, and changes over time.

## Knowledge lifecycle

```
captured  →  candidate  →  validated  →  promoted  →  enforced
                                              ↓
                                    stale  ←  rejected
```

| State      | Meaning                                                           |
|------------|-------------------------------------------------------------------|
| captured   | Raw item written to `memory/inbox.md`                             |
| candidate  | Classified, target document identified                            |
| validated  | Confirmed against repo evidence or explicit human instruction     |
| promoted   | Written into a canonical doc; pointer added to `memory/index.md`  |
| enforced   | Backed by a Rego policy, CI check, hook, or preflight assertion   |
| stale      | Contradicted by current repo state; archived                      |
| rejected   | Considered and explicitly not adopted; archived with reason       |

## Promotion rules

A captured item becomes a candidate when any of the following are true:

- The human owner stated it explicitly.
- The same instruction has been issued more than once.
- It is supported by repo evidence (file structure, history, configuration).
- It is required for safety, correctness, security, or continuity of work.
- It is a recurring source of agent error.

A candidate becomes promoted when its target document is identified, its source is recorded, and its confidence is set.

## Enforcement rules

A promoted rule must move to enforced if a violation could cause:

- data loss
- credential or key exposure
- financial loss
- production outage
- regression of a security control
- invalidation of an experiment or measurement
- repeated wasted work for the human owner

Enforcement requires a corresponding entry in `policy-map.md` linking the rule to its executable check.

## Amendment process

1. Open a proposal under `governance/amendments/<NNNN-slug>.md` containing: change, rationale, scope, affected docs, affected policies, tests required, rollback path.
2. Run any required adversarial review (`scripts/adversarial-audit.sh`).
3. Update the relevant policy under `policy/` and add or update tests under `policy/tests/`.
4. Run `opa test policy/`. All tests must pass.
5. Mark the amendment `accepted` only after explicit human approval.
6. Update `CONSTITUTION.md`, `policy-map.md`, and `memory/index.md` in the same change.

## Failure mode

If the same durable instruction is issued by the human owner twice, that is a governance failure, not a user failure. The agent must add a candidate entry to `PROMOTION_QUEUE.md` and propose a target document.

## File index

- `CONSTITUTION.md` — doctrine
- `GOVERNANCE.md` — this file
- `AGENTS.md` — agent behavior contract
- `INTERACTION_STANDARDS.md` — human/agent communication standards
- `ANTI_PATTERNS.md` — known failure modes with provenance
- `PROJECT_MEMORY_CONTRACT.md` — say-once-persists-forever contract
- `policy-map.md` — rule → enforcement mapping
- `PROMOTION_QUEUE.md` — candidate items awaiting promotion
- `memory/inbox.md` — capture buffer
- `memory/index.md` — index of active memories
- `policy/` — Rego policy modules
- `policy/tests/` — Rego policy tests
- `.agent/project-tier.yaml` — tier declaration and required artifacts
- `.agent/review-gates.yaml` — required reviews per change class
- `.agent/audit-agents.yaml` — adversarial audit roster
