#!/usr/bin/env bash
# pre-tool-policy-gate.sh - Claude Code PreToolUse hook that routes tool
# calls through the project's OPA policy bundle via scripts/agent-gate.sh.
#
# Wiring: registered in ~/.claude/settings.json as a PreToolUse hook with
# matcher "*" (or per-tool matcher list). The hook reads the tool-call payload
# from stdin, builds a normalized agent-gate input, queries OPA, and exits:
#
#   exit 0  → allow
#   exit 2  → block (Claude Code halts the tool call and shows the reason)
#
# When the policy returns require_approval, we currently exit 0 with a stderr
# warning (Claude Code does not yet expose an "ask the user" exit code in
# stable). The decision is also written to audits/gate.log via agent-gate.sh,
# so the require_approval cases stay reviewable.
#
# Behavior in projects without governance:
#   - If scripts/agent-gate.sh is missing OR policy/ is missing, exit 0.
#   - The hook fails open in that case so it does not break unrelated projects.
#   - Projects that have run /preflight govern get the hook's full effect.
#
# Disable per-session via:
#   export PREFLIGHT_GATE_DISABLE=1
set -uo pipefail

[ "${PREFLIGHT_GATE_DISABLE:-0}" = "1" ] && exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# In a project that has NOT been governance-init'd, the gate is inert.
# Exit 0 so unrelated repos aren't broken by the global hook.
[ -x "$PROJECT_DIR/scripts/agent-gate.sh" ] || exit 0
[ -d "$PROJECT_DIR/policy" ] || [ -d "$PROJECT_DIR/governance/policy" ] || exit 0

# Three states matter:
#   1. OPA installed + policy says deny       → exit 2 (real enforcement)
#   2. OPA installed + policy says approval   → exit 2 unless PREFLIGHT_GATE_APPROVE=1
#   3. OPA NOT installed                      → ADVISORY mode: warn + allow
#
# State 3 used to fail-closed (exit 2). That was wrong: if OPA is missing,
# the agent has no way to install OPA from inside a session that's gated
# from running tools. The forcing function for installing OPA lives in
# governance-check.sh, not in every tool call. Hard-blocking here was a
# design flaw that locked the agent out of fixing its own dependency.
if ! command -v opa >/dev/null 2>&1; then
    # Warn once per parent process via a sentinel — don't spam every call.
    SENTINEL="${TMPDIR:-/tmp}/.preflight-gate-opa-missing-${PPID}"
    if [ ! -f "$SENTINEL" ]; then
        echo "[policy] WARN: opa not installed; gate is in ADVISORY mode (allow all)." >&2
        echo "        Install:  curl -sSL -o ~/.local/bin/opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static && chmod +x ~/.local/bin/opa" >&2
        echo "        Or run:   /preflight install   (auto-installs OPA)" >&2
        echo "        Then restart Claude Code so the gate can enforce." >&2
        touch "$SENTINEL" 2>/dev/null || true
    fi
    exit 0
fi

# Read the PreToolUse JSON payload from stdin. Fields we care about:
#   tool_name           → "Bash" | "Edit" | "Write" | ...
#   tool_input.command  → for Bash
#   tool_input.file_path → for Edit/Write
RAW="$(cat)"
[ -z "$RAW" ] && exit 0

# Build a normalized input for agent-gate. Use python for resilient JSON parsing.
NORMALIZED="$(echo "$RAW" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool = payload.get("tool_name") or payload.get("tool") or ""
ti   = payload.get("tool_input", {}) or {}

if tool == "Bash":
    out = {
        "agent": {"id": "claude-code", "role": "tool"},
        "tool":  {"name": "shell"},
        "request": {
            "command": ti.get("command", ""),
            "cwd": ti.get("cwd", ""),
        },
    }
elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    op = "write"
    if tool in ("Edit", "MultiEdit", "NotebookEdit"):
        op = "write"
    out = {
        "agent": {"id": "claude-code", "role": "tool"},
        "tool":  {"name": "filesystem"},
        "request": {
            "op": op,
            "path": ti.get("file_path", ti.get("notebook_path", "")),
        },
    }
elif tool == "Read":
    out = {
        "agent": {"id": "claude-code", "role": "tool"},
        "tool":  {"name": "filesystem"},
        "request": {
            "op": "read",
            "path": ti.get("file_path", ""),
        },
    }
elif tool == "WebFetch":
    from urllib.parse import urlparse
    host = urlparse(ti.get("url", "")).hostname or ""
    out = {
        "agent": {"id": "claude-code", "role": "tool"},
        "tool":  {"name": "network"},
        "request": {"url": ti.get("url", ""), "host": host, "method": "GET"},
    }
else:
    # Tools we do not gate (TaskCreate, ToolSearch, internal). Pass through.
    sys.exit(0)

print(json.dumps(out))
' 2>/dev/null)"

[ -z "$NORMALIZED" ] && exit 0

# Query the OPA bundle via agent-gate.sh.
DECISION="$(echo "$NORMALIZED" | "$PROJECT_DIR/scripts/agent-gate.sh" 2>/dev/null)" || exit 0

# Parse the decision and decide what to print + how to exit.
#
# When we block (deny OR require_approval without explicit override), we ALSO
# print a preview of what was about to happen so the user is not asked to
# approve a blank check.
#
# Approval mechanism — two options, in priority order:
#
#   1. PROJECT-LOCAL FILE (preferred): $PROJECT_DIR/.agent/.gate-approve
#      One-shot. The hook deletes it after consuming it. Scoped to this one
#      project — does NOT leak into other Claude Code sessions you may have
#      running in other preflight-installed projects.
#      Create it via: touch .agent/.gate-approve
#
#   2. SHELL ENV VAR (fallback, batch use): PREFLIGHT_GATE_APPROVE=1
#      Scoped to whatever shell you set it in — therefore bleeds into every
#      Claude Code session sharing that shell. Useful for batch operations
#      where you accept the cross-project risk.
#
# Deny decisions are NEVER bypassable. Only require_approval can be approved.
APPROVE="0"
APPROVE_VIA=""
GATE_APPROVE_FILE="$PROJECT_DIR/.agent/.gate-approve"
if [ -f "$GATE_APPROVE_FILE" ]; then
    APPROVE="1"
    APPROVE_VIA="file ($GATE_APPROVE_FILE — consumed)"
    rm -f "$GATE_APPROVE_FILE" 2>/dev/null
elif [ "${PREFLIGHT_GATE_APPROVE:-0}" = "1" ]; then
    APPROVE="1"
    APPROVE_VIA="env PREFLIGHT_GATE_APPROVE=1 (shell-global; consider .agent/.gate-approve for project-local)"
fi
echo "$DECISION" | APPROVE="$APPROVE" APPROVE_VIA="$APPROVE_VIA" RAW="$RAW" python3 -c '
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
allow  = bool(d.get("allow"))
needs  = bool(d.get("require_approval"))
reason = d.get("reason", "policy denied")
approve = os.environ.get("APPROVE", "0") == "1"

def preview():
    """Print to stderr what was about to happen, so the user can judge."""
    try:
        payload = json.loads(os.environ.get("RAW", ""))
    except Exception:
        return
    tool = payload.get("tool_name", "")
    ti   = payload.get("tool_input", {}) or {}
    if tool == "Bash":
        cmd = ti.get("command", "")
        print(f"[policy] preview — Bash:", file=sys.stderr)
        for line in cmd.splitlines()[:40] or [cmd]:
            print(f"  | {line}", file=sys.stderr)
    elif tool in ("Edit", "MultiEdit"):
        path = ti.get("file_path", "")
        old = ti.get("old_string", "")
        new = ti.get("new_string", "")
        print(f"[policy] preview — Edit {path}:", file=sys.stderr)
        if old:
            print(f"  --- old (first 10 lines) ---", file=sys.stderr)
            for line in old.splitlines()[:10]:
                print(f"  - {line}", file=sys.stderr)
        print(f"  +++ new (first 40 lines) +++", file=sys.stderr)
        new_lines = new.splitlines()
        for line in new_lines[:40]:
            print(f"  + {line}", file=sys.stderr)
        if len(new_lines) > 40:
            print(f"  + [... {len(new_lines)-40} more lines ...]", file=sys.stderr)
    elif tool == "Write":
        path = ti.get("file_path", "")
        content = ti.get("content", "")
        lines = content.splitlines()
        print(f"[policy] preview — Write {path} ({len(lines)} lines, {len(content)} bytes):", file=sys.stderr)
        for line in lines[:40]:
            print(f"  | {line}", file=sys.stderr)
        if len(lines) > 40:
            print(f"  | [... {len(lines)-40} more lines ...]", file=sys.stderr)
    elif tool == "WebFetch":
        url = ti.get("url", "")
        print(f"[policy] preview — WebFetch {url}", file=sys.stderr)

if allow:
    sys.exit(0)
if needs and approve:
    via = os.environ.get("APPROVE_VIA", "")
    print(f"[policy] require_approval bypassed via {via}: {reason}", file=sys.stderr)
    sys.exit(0)
if needs:
    preview()
    print(f"[policy] BLOCKED (approval required): {reason}", file=sys.stderr)
    print(f"         Review the preview above. If you approve, run:", file=sys.stderr)
    print(f"             touch .agent/.gate-approve   # project-local, one-shot, recommended", file=sys.stderr)
    print(f"         then re-issue the call.", file=sys.stderr)
    print(f"         (For batch ops you can also: export PREFLIGHT_GATE_APPROVE=1 — but this is", file=sys.stderr)
    print(f"          shell-global and bleeds into other preflight projects in the same shell.)", file=sys.stderr)
    sys.exit(2)
preview()
print(f"[policy] BLOCKED: {reason}", file=sys.stderr)
sys.exit(2)
'
