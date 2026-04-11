#!/usr/bin/env bash
# memory-promote.sh - Memory lifecycle helper.
#
# Two modes:
#
#   capture <statement>
#     Append a new dated entry to memory/inbox.md and a candidate row to
#     governance/PROMOTION_QUEUE.md. Used by the agent when it detects a
#     durable instruction.
#
#   list
#     Show inbox entries and pending candidates.
#
# Promotion to a canonical doc is a deliberate edit; this script does not
# overwrite docs unattended.
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

CMD="${1:-list}"; shift || true

ts_local() { date "+%Y-%m-%d %H:%M"; }
ts_date()  { date "+%Y-%m-%d"; }

slugify() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-48
}

next_id() {
    # IDs are zero-padded to at least 4 digits but grow without limit so
    # projects that accumulate >9999 candidates over their lifetime still
    # produce strictly monotonic IDs.
    if [ ! -f governance/PROMOTION_QUEUE.md ]; then echo "0001"; return; fi
    local last width
    last=$(grep -oE '^## [0-9]+' governance/PROMOTION_QUEUE.md | awk '{print $2}' | sort -n | tail -1)
    [ -z "$last" ] && { echo "0001"; return; }
    width=${#last}
    [ "$width" -lt 4 ] && width=4
    printf "%0${width}d" "$((10#$last + 1))"
}

cmd_capture() {
    local statement="$*"
    if [ -z "$statement" ]; then
        echo "memory-promote: capture requires a statement" >&2
        exit 2
    fi
    mkdir -p memory governance
    [ -f memory/inbox.md ] || printf "# MEMORY INBOX\n\n" > memory/inbox.md
    [ -f governance/PROMOTION_QUEUE.md ] || printf "# PROMOTION QUEUE\n\n" > governance/PROMOTION_QUEUE.md

    local slug; slug="$(slugify "$statement")"
    local id; id="$(next_id)"

    {
        printf "\n## %s — %s\n\n" "$(ts_local)" "$slug"
        printf "Source:    human\n"
        printf "Statement: %s\n" "$statement"
        printf "Context:   captured by memory-promote\n"
    } >> memory/inbox.md

    {
        printf "\n## %s — %s\n\n" "$id" "$slug"
        printf "Captured:    %s\n" "$(ts_date)"
        printf "Source:      human\n"
        printf "Statement:   %s\n" "$statement"
        printf "Type:        TBD\n"
        printf "Confidence:  high\n"
        printf "Target doc:  TBD\n"
        printf "Enforceable: maybe\n"
        printf "Proposed enforcement: TBD\n"
        printf "Status:      candidate\n"
    } >> governance/PROMOTION_QUEUE.md

    cat <<EOF
captured: $id $slug
  inbox:  memory/inbox.md
  queue:  governance/PROMOTION_QUEUE.md (#$id)

queue block:
  ## $id — $slug
  Captured:    $(ts_date)
  Source:      human
  Statement:   $statement
  Type:        TBD
  Confidence:  high
  Target doc:  TBD
  Enforceable: maybe
  Proposed enforcement: TBD
  Status:      candidate

next:
  1. Fill Type / Target doc / Proposed enforcement.
  2. Write the statement into the target doc.
  3. If enforceable, add a row to governance/policy-map.md.
  4. Set Status: promoted, then move the inbox entry to memory/promoted/.
EOF
}

cmd_list() {
    echo ""
    echo "── Inbox ────────────────────────────────"
    if [ -f memory/inbox.md ]; then
        grep "^## " memory/inbox.md || echo "  (empty)"
    else
        echo "  (no memory/inbox.md)"
    fi
    echo ""
    echo "── Promotion queue (candidates) ─────────"
    if [ -f governance/PROMOTION_QUEUE.md ]; then
        awk '
            /^## [0-9]+ / { id=$0; in_block=1; status=""; statement=""; next }
            in_block && /^Statement:/ { statement=$0; next }
            in_block && /^Status:/ { status=$0;
                if (status ~ /candidate/) print id "\n  " statement "\n  " status "\n";
                in_block=0; next }
        ' governance/PROMOTION_QUEUE.md
    else
        echo "  (no governance/PROMOTION_QUEUE.md)"
    fi
}

cmd_promote() {
    [ -f governance/PROMOTION_QUEUE.md ] || {
        echo "memory-promote: no governance/PROMOTION_QUEUE.md" >&2
        exit 1
    }
    python3 - <<'PY'
import re, sys, pathlib, subprocess
queue = pathlib.Path("governance/PROMOTION_QUEUE.md")
text = queue.read_text()

# A block runs from "## NNNN — title" until the next "## " heading.
blocks = re.split(r"^## (?=\d+ )", text, flags=re.M)
header, blocks = blocks[0], blocks[1:]

def field(b, name):
    m = re.search(rf"^{name}:\s*(.+)$", b, re.M)
    return (m.group(1).strip() if m else "")

new_blocks = []
moved = 0
skipped = 0
seen = 0
for b in blocks:
    if not re.search(r"^Status:\s*candidate\s*$", b, re.M):
        new_blocks.append(b)
        continue
    seen += 1
    title = b.splitlines()[0].strip()
    print(f"\n  ── #{title}")
    print(f"      Statement:   {field(b, 'Statement')}")
    print(f"      Source:      {field(b, 'Source')}")
    print(f"      Confidence:  {field(b, 'Confidence')}")
    cur_target = field(b, "Target doc") or "TBD"
    cur_type   = field(b, "Type") or "TBD"
    print(f"      Current type: {cur_type}")
    print(f"      Current target: {cur_target}")
    print(f"      [p] promote (mark Status: promoted)")
    print(f"      [t] set Type / Target / Enforceable")
    print(f"      [r] reject (mark Status: rejected)")
    print(f"      [s] skip")
    print(f"      [q] quit")
    try:
        ans = input("      action: ").strip().lower()
    except EOFError:
        ans = "q"
    if ans == "q":
        new_blocks.append(b)
        for rest in blocks[blocks.index(b)+1:]:
            new_blocks.append(rest)
        print("  quit.")
        break
    if ans == "s":
        new_blocks.append(b); skipped += 1; continue
    if ans == "r":
        b = re.sub(r"^Status:\s*candidate\s*$", "Status:      rejected", b, flags=re.M)
        new_blocks.append(b); print("      → rejected"); continue
    if ans == "t":
        new_type = input("      Type (rule|preference|workflow|security|architecture|operational): ").strip()
        new_target = input(f"      Target doc [{cur_target}]: ").strip() or cur_target
        new_enf = input("      Enforceable (yes|no|maybe): ").strip()
        if new_type:
            b = re.sub(r"^Type:\s*.*$", f"Type:        {new_type}", b, flags=re.M)
        b = re.sub(r"^Target doc:\s*.*$", f"Target doc:  {new_target}", b, flags=re.M)
        if new_enf:
            b = re.sub(r"^Enforceable:\s*.*$", f"Enforceable: {new_enf}", b, flags=re.M)
        new_blocks.append(b); continue
    if ans == "p":
        b = re.sub(r"^Status:\s*candidate\s*$", "Status:      promoted", b, flags=re.M)
        new_blocks.append(b); moved += 1
        print("      → marked promoted (write the rule into the target doc next).")
        continue
    new_blocks.append(b)

queue.write_text(header + "## ".join([""] + ["## " + b for b in new_blocks])[2:])
print(f"\n  reviewed {seen} candidate(s); promoted {moved}, skipped {skipped}")
PY
}

case "$CMD" in
    capture) cmd_capture "$@" ;;
    list)    cmd_list ;;
    promote) cmd_promote ;;
    *)
        cat <<EOF
Usage: $0 <command>

Commands:
  capture "<statement>"   Append to memory/inbox.md and PROMOTION_QUEUE.md
  list                    Show inbox and pending candidates
  promote                 Walk pending candidates interactively (set Type/Target, mark promoted/rejected)
EOF
        exit 2
        ;;
esac

# Auto-regenerate the context pack for capture/promote so the next agent
# session sees what just changed.
case "$CMD" in
    capture|promote)
        [ -x scripts/context-pack.sh ] && \
            ./scripts/context-pack.sh --quiet >/dev/null 2>&1 || true
        ;;
esac
