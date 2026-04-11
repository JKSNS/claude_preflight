# AGENTS

Behavior contract for any agent operating in this repository.

## Session start

1. Read `.agent/context-packs/current.md` first. It aggregates `CONSTITUTION.md`, `AGENTS.md`, `INTERACTION_STANDARDS.md`, `ANTI_PATTERNS.md`, active memories, and recent `STATUS.md` into a single 30KB file. If it doesn't exist, run `./scripts/context-pack.sh` to generate it.
2. If the context-pack is older than the latest commit, regenerate it (`./scripts/context-pack.sh`) before relying on it.
3. Verify the working tree is in the state assumed by the most recent status update. If not, reconcile before acting.

The context-pack is the canonical session-start read. Reading the source files individually is the fallback when the pack is missing or stale.

## Required behavior

- Treat every executable check (`policy/`, hooks, CI) as authoritative over prose.
- Verify against current repo state before relying on memory.
- When the human owner expresses a durable preference, rule, recurring correction, or invariant, capture it under `memory/inbox.md` and add a candidate entry to `PROMOTION_QUEUE.md` in the same response.
- After meaningful work, update `STATUS.md` with: changed files, what was verified, what was not, open questions, and recommended next step.
- Surface uncertainty explicitly. Mark inferred conclusions with confidence.

### Approval-gated actions: preview, then approve project-locally

When a tool call will trigger the policy gate's `require_approval` decision (writes to `governance/`, `policy/`, lockfiles, CI workflows, deps, etc.):

1. Show the user the proposed content/command BEFORE attempting the gated call. Write: file path + content. Edit: file path + old/new diff. Bash: the command. Don't ask the user to approve a blank check.
2. After the user explicitly approves, the AGENT (not the user) creates the marker:
   ```bash
   touch .agent/.gate-approve
   ```
   then makes the gated call. The hook deletes the marker after consuming it. One-shot. **Project-local — does not affect any other Claude Code session in any other preflight-installed project.**
3. The shell-global `PREFLIGHT_GATE_APPROVE=1` env var also works but bleeds into every other preflight session in the same shell. Only suggest it for genuine batch operations where the user explicitly accepts that risk.

## Forbidden behavior

- Claiming a task is complete without evidence.
- Disabling, weakening, or skipping a failing test, hook, or policy gate as a way to make a change land.
- Approving your own non-doc change. The reviewer agent must not be the author agent. Both must be named (empty strings do not satisfy the rule and are blocked by `policy/review.rego`).
- Treating an item from `memory/inbox.md` as authoritative.
- Modifying `policy/` or `CONSTITUTION.md` without an amendment proposal under `governance/amendments/`.
- Bypassing executable checks via `--no-verify`, `--force`, sub-agent delegation, scheduled mode, or claimed urgency.
- Reading process environment values for variables matching secret-shaped names (e.g., `printenv AWS_SECRET_ACCESS_KEY`, `echo $GITHUB_TOKEN`, `env | grep TOKEN`). Blocked by `policy/shell.rego`.
- **Drafting CONSTITUTION.md, AGENTS.md, ANTI_PATTERNS.md, or any doctrine doc from session context alone.** Run `./scripts/project-ingest.sh` first, read the resulting `.agent/project-ingest.md` end-to-end, open every source file it points at (CLAUDE.md, all `docs/*.md`, every memory entry), produce the synthesis answers required at the bottom of the ingest, and only then propose content. Drafting from "what's currently top-of-mind" produces session notes pretending to be a constitution.
- Asking the user to approve a write/edit/command WITHOUT first showing them the proposed content. The hook will print a preview as a fallback, but doctrine: show the user what you intend to do BEFORE attempting the gated call.

## Self-review

Before reporting a non-trivial change as done, the agent must produce:

- list of changed files and the reason for each
- tests run and tests intentionally not run
- residual risk
- docs touched (or a justification for not touching any)
- policy impact (no impact, gap discovered, amendment proposed)
- open questions
- recommended next step

## Source attribution

Each item written into a canonical doc must carry: source, date, confidence, type, and target file. The exact format is defined in `GOVERNANCE.md`.
