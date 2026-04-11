#!/usr/bin/env bash
# pre-compact-synthesize.sh - Claude Code PreCompact hook.
#
# Fires when the conversation is about to be compacted, which is the moment
# before session signal is lost. If the current project has been
# governance-init'd, run session-synthesize to distill recent memory entries
# into PROMOTION_QUEUE candidates. Otherwise exit 0 silently.
#
# Read once from stdin so PreCompact's payload doesn't block; we don't use it.
cat >/dev/null

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [ ! -f "$PROJECT_DIR/governance/PROMOTION_QUEUE.md" ]; then
    exit 0
fi

if [ ! -x "$PROJECT_DIR/scripts/session-synthesize.sh" ]; then
    exit 0
fi

# Run quietly. Detach from the parent's process group via setsid (when
# available) so the synthesizer survives Claude's compaction proceeding.
# Time-bound to avoid runaway tasks if Ollama hangs.
if command -v setsid >/dev/null 2>&1; then
    setsid -f bash -c "cd \"$PROJECT_DIR\" && timeout 60 ./scripts/session-synthesize.sh --quiet --since 7d" >/dev/null 2>&1 || true
elif command -v nohup >/dev/null 2>&1; then
    nohup bash -c "cd \"$PROJECT_DIR\" && timeout 60 ./scripts/session-synthesize.sh --quiet --since 7d" >/dev/null 2>&1 &
    disown 2>/dev/null || true
else
    ( cd "$PROJECT_DIR" && timeout 60 ./scripts/session-synthesize.sh --quiet --since 7d ) >/dev/null 2>&1 &
fi
exit 0
