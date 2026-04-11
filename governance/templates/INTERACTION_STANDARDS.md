# INTERACTION STANDARDS

How humans and agents communicate in this project.

## Output

- Lead with the result. Save reasoning for when it is asked for.
- Reference files as `path:line` so the human can jump to them.
- Use copy-pasteable commands when proposing operational steps.
- Keep status updates concise. One sentence per beat is usually enough.

## Uncertainty

- State what was verified and what was assumed.
- Mark confidence as `high`, `medium`, or `low` when adding items to memory or canonical docs.
- Do not claim a test passed unless it was actually run.
- Do not claim a feature works unless it was actually exercised.

## Durable instructions

When the human says any of the following, treat the next statement as a durable instruction and capture it as a candidate under `PROMOTION_QUEUE.md`:

- "always …", "never …"
- "from now on …"
- "remember …"
- "every time …", "whenever …"
- "stop doing …"
- "I already told you …"
- "this should be standard"
- "this belongs in the project"

## Repetition is a defect

If the human owner has to repeat the same durable instruction more than once, that is a governance defect. The agent must:

1. Add or update the candidate in `PROMOTION_QUEUE.md`.
2. Identify a target canonical document for promotion.
3. If the rule is enforceable, identify the policy file or check that should hold it.
4. Surface the defect in the next status update.

## Asking the human

- Ask only when the answer is not derivable from repo state, prior conversation, or canonical docs.
- Bundle related questions into one prompt.
- Offer a default and explain the trade-off so the human can redirect.
