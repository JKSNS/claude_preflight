#!/usr/bin/env bash
# idea-log.sh - Capture user idea-shaped statements verbatim into a living log.
#
# When the user says something idea-shaped ("I've been thinking", "what if",
# "I want", "we should", "I noticed"), the agent captures the verbatim quote
# here, profanity-stripped, with a one-line title + optional context +
# optional synthesis. Append-only, newest at top within each day, day
# headers are H2.
#
# This is distinct from:
#   - memory/inbox.md          → durable instructions awaiting promotion
#   - PROMOTION_QUEUE.md       → classified candidates
#   - STATUS.md                → what is true now
#   - amendments/              → ratified doctrine changes
#
# Lifecycle: captured → considered → inbox-NNN → amendment-NNN → retired-noted
#
# Usage:
#   ./scripts/idea-log.sh capture "<quote>" [--title "<t>"] [--context "<c>"] [--synthesis "<s>"]
#   ./scripts/idea-log.sh status <date> <hh:mm> <new-status>     # e.g. status 2026-04-29 14:32 inbox-0042
#   ./scripts/idea-log.sh list [--status captured|considered|inbox|amendment|retired]
#   ./scripts/idea-log.sh stale [--days 7]                        # captured entries older than N days
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

LOG="governance/idea_log.md"
mkdir -p governance

CMD="${1:-}"; shift || true

# Profanity scrub: replace common profanities with [edited] preserving rough length.
# Conservative wordlist — false positives go to [edited]. Add more as needed.
profanity_strip() {
    python3 - <<PY
import re, sys
text = """$1"""
patterns = [
    r"\bf+u+c+k+(?:ing|ed|er|ers|s)?\b",
    r"\bs+h+i+t+(?:ty|s|ting)?\b",
    r"\ba+s+s+h+o+l+e+s?\b",
    r"\bb+i+t+c+h+(?:es|ing|y)?\b",
    r"\bd+a+m+n+(?:ed|it)?\b",
    r"\bc+u+n+t+s?\b",
    r"\bb+a+s+t+a+r+d+s?\b",
]
for p in patterns:
    text = re.sub(p, "[edited]", text, flags=re.I)
print(text, end="")
PY
}

cmd_capture() {
    local quote="" title="" context="" synthesis=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --title)     shift; title="${1:-}" ;;
            --context)   shift; context="${1:-}" ;;
            --synthesis) shift; synthesis="${1:-}" ;;
            *) [ -z "$quote" ] && quote="$1" ;;
        esac
        shift
    done

    if [ -z "$quote" ]; then
        echo "idea-log: capture requires a quote" >&2
        exit 2
    fi

    local clean_quote
    clean_quote="$(profanity_strip "$quote")"
    [ -z "$title" ] && title="$(echo "$clean_quote" | head -c 60 | tr '\n' ' ' | sed 's/  */ /g')..."

    local today
    today="$(date +%Y-%m-%d)"
    local hhmm
    hhmm="$(date +%H:%M)"
    local zone
    zone="$(date +%Z)"

    # Build the new entry block.
    local entry_block
    entry_block="$(python3 - "$today" "$hhmm" "$zone" "$title" "$clean_quote" "$context" "$synthesis" <<'PY'
import sys
day, hhmm, zone, title, quote, context, synthesis = sys.argv[1:8]
out = []
out.append(f"### {hhmm} {zone} — {title.strip()}")
out.append("")
out.append("> " + quote.replace("\n", "\n> "))
out.append("")
out.append(f"**Context**: {context or '(none)'}")
out.append(f"**Status**:  captured")
if synthesis:
    out.append(f"**Synthesis**: {synthesis}")
out.append("")
out.append("---")
out.append("")
print("\n".join(out))
PY
)"

    if [ ! -f "$LOG" ]; then
        cat > "$LOG" <<EOF
# Idea log

User-spoken thoughts captured verbatim (profanity-stripped) the moment they're said.
Append-only. Newest at top within each day. Lifecycle:
captured → considered → inbox-NNN → amendment-NNN → retired-noted.

EOF
    fi

    # Insert today's entry. Newest-within-day at top; new day sections at
    # top of the body (above older days). The preamble (H1 + intro) stays
    # above all day sections.
    python3 - "$LOG" "$today" "$entry_block" <<'PY'
import sys, re, pathlib
log_path, today, entry_block = sys.argv[1:4]
p = pathlib.Path(log_path)
text = p.read_text()

# Bash command substitution strips trailing newlines; ensure block separates
# cleanly from anything that follows it.
block = entry_block.rstrip() + "\n\n"

day_header = f"## {today}"
if day_header in text:
    # Insert immediately after the existing day header so this entry lands
    # above older same-day entries.
    pattern = re.compile(r"^(" + re.escape(day_header) + r"\s*\n+)", re.M)
    new_text = pattern.sub(lambda m: m.group(1) + block, text, count=1)
else:
    # Find the first existing day header; insert this NEW day section just
    # above it. If none exists yet, append to end of preamble.
    first_day = re.search(r"^## \d{4}-\d{2}-\d{2}", text, re.M)
    new_section = f"{day_header}\n\n{block}"
    if first_day:
        new_text = text[:first_day.start()] + new_section + text[first_day.start():]
    else:
        new_text = text.rstrip() + "\n\n" + new_section

p.write_text(new_text)
PY

    echo "  captured: $today $hhmm $zone — $title"
    [ -n "$synthesis" ] && echo "  synthesis recorded"
    echo "  $LOG"
}

cmd_status() {
    local day="${1:-}" hhmm="${2:-}" new_status="${3:-}"
    if [ -z "$day" ] || [ -z "$hhmm" ] || [ -z "$new_status" ]; then
        echo "idea-log: status requires <date> <hh:mm> <new-status>" >&2
        exit 2
    fi
    [ -f "$LOG" ] || { echo "no $LOG"; exit 1; }
    python3 - "$LOG" "$day" "$hhmm" "$new_status" <<'PY'
import sys, re, pathlib
log_path, day, hhmm, new_status = sys.argv[1:5]
p = pathlib.Path(log_path)
text = p.read_text()
# Find the entry block for the given day + hhmm and replace its Status line.
pattern = re.compile(
    r"(### " + re.escape(hhmm) + r"\s+\S+\s+—.*?\n.*?\*\*Status\*\*:\s*)\S+",
    re.S
)
match = pattern.search(text)
if not match:
    print(f"  no entry found for {day} {hhmm}", file=sys.stderr)
    sys.exit(1)
new_text = pattern.sub(lambda m: m.group(1) + new_status, text, count=1)
p.write_text(new_text)
print(f"  status updated: {day} {hhmm} → {new_status}")
PY
}

cmd_list() {
    local filter=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --status) shift; filter="${1:-}" ;;
            --status=*) filter="${1#--status=}" ;;
        esac
        shift
    done
    [ -f "$LOG" ] || { echo "no $LOG"; exit 1; }
    python3 - "$LOG" "$filter" <<'PY'
import sys, re, pathlib
log_path, filt = sys.argv[1], sys.argv[2]
text = pathlib.Path(log_path).read_text()

# Iterate H2 day-headers + the H3 entries beneath each.
day_re = re.compile(r"^## (\d{4}-\d{2}-\d{2})", re.M)
entry_re = re.compile(r"^### (\d{2}:\d{2})\s+\S+\s+—\s+(.+?)\n.*?\*\*Status\*\*:\s*(\S+)", re.M | re.S)

for match in day_re.finditer(text):
    day = match.group(1)
    end = day_re.search(text, match.end())
    section = text[match.end():end.start() if end else len(text)]
    for em in entry_re.finditer(section):
        hhmm, title, status = em.group(1), em.group(2).strip(), em.group(3).strip()
        if filt and not status.startswith(filt):
            continue
        print(f"  {day} {hhmm}  [{status:20s}] {title[:70]}")
PY
}

cmd_stale() {
    local days=7
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --days) shift; days="${1:-7}" ;;
            --days=*) days="${1#--days=}" ;;
        esac
        shift
    done
    [ -f "$LOG" ] || { echo "no $LOG"; exit 0; }
    python3 - "$LOG" "$days" <<'PY'
import sys, re, pathlib, datetime
log_path, days = sys.argv[1], int(sys.argv[2])
text = pathlib.Path(log_path).read_text()
today = datetime.date.today()
threshold = today - datetime.timedelta(days=days)

day_re = re.compile(r"^## (\d{4}-\d{2}-\d{2})", re.M)
entry_re = re.compile(r"^### (\d{2}:\d{2})\s+\S+\s+—\s+(.+?)\n.*?\*\*Status\*\*:\s*(\S+)", re.M | re.S)

stale = []
for match in day_re.finditer(text):
    day = match.group(1)
    try:
        d = datetime.date.fromisoformat(day)
    except Exception:
        continue
    if d > threshold:
        continue
    end = day_re.search(text, match.end())
    section = text[match.end():end.start() if end else len(text)]
    for em in entry_re.finditer(section):
        hhmm, title, status = em.group(1), em.group(2).strip(), em.group(3).strip()
        if status == "captured":
            stale.append((day, hhmm, title))

if not stale:
    print(f"  no captured entries older than {days}d")
    sys.exit(0)
print(f"  {len(stale)} captured entries older than {days}d (need promote/consider/retire):")
for day, hhmm, title in stale[:20]:
    print(f"    {day} {hhmm}  {title[:80]}")
sys.exit(1)
PY
}

case "$CMD" in
    capture) cmd_capture "$@" ;;
    status)  cmd_status  "$@" ;;
    list)    cmd_list    "$@" ;;
    stale)   cmd_stale   "$@" ;;
    *)
        cat <<EOF
Usage: $0 <command>

Commands:
  capture "<quote>" [--title T] [--context C] [--synthesis S]
                                Append a verbatim user thought (profanity stripped)
  status <date> <hh:mm> <new-status>
                                Update an entry's status (considered, inbox-NNN, etc.)
  list [--status <prefix>]      Show entries, optionally filtered by status prefix
  stale [--days N]              Show 'captured' entries older than N days (default 7)
EOF
        exit 2
        ;;
esac
