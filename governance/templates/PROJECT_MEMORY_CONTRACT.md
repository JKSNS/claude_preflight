# PROJECT MEMORY CONTRACT

The contract that makes "say it once" actually stick.

## Statement

This project must not require the human owner to repeat durable instructions, constraints, standards, or preferences. When such an instruction is issued, the agent must capture, classify, and promote it through the lifecycle defined in `GOVERNANCE.md`, or explicitly explain why it should remain session-local.

## Triggers

A statement is a durable instruction if it includes any of:

- "always", "never", "from now on"
- "we keep", "this keeps happening", "I already told you"
- "remember", "this should be standard", "this belongs in the project"
- "I still have to remind you"

## Required action on a durable instruction

1. Append a capture entry to `memory/inbox.md` with the verbatim statement, date, and source.
2. Add a candidate entry to `PROMOTION_QUEUE.md` proposing:
   - classification (rule, preference, workflow, security, architecture, operational)
   - target canonical document
   - whether it is enforceable
   - confidence
3. Identify the target canonical document:
   - rule of conduct → `CONSTITUTION.md` or `AGENTS.md`
   - communication preference → `INTERACTION_STANDARDS.md`
   - failure mode → `ANTI_PATTERNS.md`
   - workflow rule → `GOVERNANCE.md` or project workflow doc
   - executable rule → matching `policy/*.rego` and `policy-map.md`
4. Surface the proposed promotion in the next status update for human ratification.
5. If ratified, complete the promotion, update `memory/index.md`, and move the inbox entry to `memory/promoted/`.

## Failure mode

If the same durable instruction is captured twice without promotion, `scripts/governance-check.sh` must report a governance failure on its next run. The fix is promotion, not silence.

## Override

`override: forbidden`. This contract may not be bypassed by sub-agents, scheduled tasks, hooks, remote triggers, urgency, or self-approved waiver. Amendment requires human approval and a constitutional revision.
