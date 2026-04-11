# ANTI-PATTERNS

Failure modes that have surfaced before. Each entry has provenance so that future agents can judge edge cases instead of blindly following the rule.

## Format

```
### <short name>

Failure:    <how the mistake manifests>
Why bad:   <consequence>
Required:  <the correct behavior>
Prevention: <hook, policy, check, or doc that catches it>
Provenance: <incident reference, date, source>
```

## Starter set

### Requiring the human to repeat durable instructions

Failure:    The human gives a stable preference, rule, or invariant; the agent treats it as session-local.
Why bad:    Knowledge does not accumulate; the human becomes the project memory.
Required:   Capture the instruction in `memory/inbox.md`, add a candidate to `PROMOTION_QUEUE.md`, and propose a target canonical doc in the same response.
Prevention: `scripts/governance-check.sh` warns when high-confidence inbox items are older than the threshold without promotion.

### Prose-only enforcement of a critical rule

Failure:    A rule lives only in Markdown and gets rationalized around in practice.
Why bad:    Agents under pressure interpret prose flexibly; binding force is needed.
Required:   Critical rules carry a Rego policy, hook, or CI check. `policy-map.md` is the source of truth.
Prevention: `scripts/governance-check.sh` flags rules in `policy-map.md` whose enforcement column is empty or missing.

### Stale architecture belief

Failure:    Agent relies on an architecture doc that no longer matches the repo.
Why bad:    Recommendations and edits are aimed at code that does not exist.
Required:   Verify architecture claims against the current file tree before acting on them.
Prevention: Drift detection in `scripts/governance-check.sh` compares declared modules to actual paths.

### Self-review on a non-trivial change

Failure:    The agent that authored the change is the same agent that approves it.
Why bad:    Correctness, security, and design blind spots go unchallenged.
Required:   An independent reviewer (Codex, devil's advocate, or human) must approve any change above the doc class.
Prevention: `policy/review.rego` denies when `author_agent == reviewer_agent` for non-doc classes.

### Bypassing a failing check to land a change

Failure:    Tests fail, hooks fail, policy denies — agent uses `--no-verify`, `--force`, or disables the check.
Why bad:    The check exists because someone learned the hard way. Bypassing it deletes the lesson.
Required:   Diagnose the underlying issue. If the check is wrong, propose an amendment with rationale.
Prevention: `policy/git.rego` denies hook-skip and force-push to protected branches.

### Treating inbox memory as authoritative

Failure:    Agent acts on a `memory/inbox.md` item before it has been validated and promoted.
Why bad:    Inbox is a capture buffer, not project truth. Acting on it short-circuits the promotion lifecycle.
Required:   Treat inbox as candidate-only. Promote it through the lifecycle in `GOVERNANCE.md` before relying on it.
Prevention: Items in `memory/inbox.md` carry no `confidence` until promoted.
