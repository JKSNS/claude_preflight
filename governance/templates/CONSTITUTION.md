# CONSTITUTION

Project doctrine. Authoritative. Beats every other prose guidance in this repo.

## Authority

1. The constitution beats all other project guidance.
2. Golden rules and standards beat workflow preferences.
3. Executable gates (OPA/Rego, hooks, CI checks) beat agent judgment.
4. Human-approved amendments beat prior constitution text.
5. Current repo state beats stale memory.
6. Task-specific scope can narrow defaults; broadening defaults requires an amendment.
7. Agents may propose amendments; agents may not ratify them.

## Two-layer rule

A load-bearing rule must exist in at least two layers: human-readable doctrine and either agent context or runtime enforcement. A critical rule must exist in all three.

## Override clauses

A rule marked `override: forbidden` may not be bypassed by:

- autonomous loop or scheduled mode
- sub-agent delegation
- hooks, remote triggers, or MCP tool calls
- prior session assumptions or claimed urgency
- self-approved waivers

## Core invariants

> Replace this section with project-specific invariants. Each invariant follows the form below.

```
### Invariant: <short name>

Statement: <one sentence in plain language>
Why:       <reason this matters>
Source:    <user mandate | incident | external requirement>
Enforced:  <policy/<file>.rego | scripts/<file>.sh | manual review>
Override:  forbidden | requires-amendment | informational
```

## Amendments

Amendments live in `governance/amendments/`. Each is a numbered, dated proposal containing the change, rationale, scope, and the policy or doc updates required to enact it. See `GOVERNANCE.md` for the lifecycle.
