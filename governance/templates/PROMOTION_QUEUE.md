# PROMOTION QUEUE

Candidate items captured from `memory/inbox.md` that are awaiting promotion into a canonical doc, a policy, or both. Worked through during preflight or by `scripts/memory-promote.sh`.

## Format

```
## <NNNN> — <short title>

Captured:    <YYYY-MM-DD>
Source:      human | incident | derived | external-requirement
Statement:   <verbatim or paraphrase>
Type:        rule | preference | workflow | security | architecture | operational
Confidence:  high | medium | low
Target doc:  <path>
Enforceable: yes | no | maybe
Proposed enforcement: <policy/<file>.rego | scripts/<file>.sh | hooks/<name>>
Status:      candidate | promoted | rejected
Notes:       <optional>
```

## Lifecycle

`candidate` → `promoted` (the rule is written into the target doc, `policy-map.md` is updated, the inbox entry is moved to `memory/promoted/`).

`candidate` → `rejected` (the rule was considered and not adopted; archive with reason).

## Pending items

> No pending items. Add new entries below as candidates arrive from `memory/inbox.md`.
