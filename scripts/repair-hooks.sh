#!/usr/bin/env bash
# repair-hooks.sh - Detect and clean orphan hook entries in ~/.claude/settings.json.
#
# Why this exists: if you ever remove a hook FILE manually (during lockout
# recovery, debugging, etc.) without also removing the corresponding entry
# from ~/.claude/settings.json, Claude Code keeps trying to invoke the
# missing file and prints "/bin/sh: ... not found" warnings on every tool
# call. This script finds those orphans and removes them.
#
# Usage:
#   ./scripts/repair-hooks.sh           # report orphans
#   ./scripts/repair-hooks.sh --apply   # remove them
set -uo pipefail

SETTINGS="$HOME/.claude/settings.json"
APPLY=false
for arg in "$@"; do
    case "$arg" in --apply) APPLY=true ;; esac
done

if [ ! -f "$SETTINGS" ]; then
    echo "no $SETTINGS — nothing to repair"
    exit 0
fi

python3 - "$SETTINGS" "$APPLY" <<'PY'
import json, sys, pathlib, os

settings_path = sys.argv[1]
apply = sys.argv[2] == "true"
s = json.load(open(settings_path))
hooks = s.get("hooks", {})

orphans = []   # list of (event, matcher, missing_command)
for event, entries in list(hooks.items()):
    for entry in list(entries):
        for hk in list(entry.get("hooks", [])):
            cmd = hk.get("command", "")
            # Extract the path (handles "bash /path" and bare "/path").
            path = cmd.replace("bash ", "").split()[0] if cmd else ""
            if path and path.startswith("/") and not pathlib.Path(path).exists():
                orphans.append((event, entry.get("matcher", ""), path))

if not orphans:
    print("no orphan hook entries found")
    sys.exit(0)

print(f"found {len(orphans)} orphan hook entry/entries:")
for event, matcher, path in orphans:
    print(f"  {event} (matcher: {matcher or '*'}) -> missing: {path}")

if not apply:
    print()
    print("re-run with --apply to remove them, or just install the missing hook")
    print("by running ./install.sh (which redeploys all hook files).")
    sys.exit(0)

# Remove orphan entries.
for event, entries in list(hooks.items()):
    cleaned = []
    for entry in entries:
        hooks_list = entry.get("hooks", [])
        kept = [hk for hk in hooks_list if (hk.get("command", "").replace("bash ", "").split() or [""])[0] and pathlib.Path((hk.get("command", "").replace("bash ", "").split() or [""])[0]).exists()]
        if kept:
            entry["hooks"] = kept
            cleaned.append(entry)
    hooks[event] = cleaned

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
print(f"cleaned {len(orphans)} orphan(s) from {settings_path}")
PY
