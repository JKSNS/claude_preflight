#!/usr/bin/env bash
# snapshot.sh - Lightweight project state snapshot + rollback.
#
# Honors the "destructive actions capture state first" rule. Designed to be
# called by any script that's about to do something the user might want to
# undo: cleanup --apply, governance-init --force, self-update, staleness-scan
# --apply, fresh, etc.
#
# What gets captured (small on purpose — the working tree itself is not tarred,
# git already has it):
#   - manifest.txt          file listing with sizes (tracked + untracked)
#   - working-tree.patch    uncommitted changes as a single patch
#   - state/settings.json   ~/.claude/settings.json
#   - state/crontab.lines   this project's cron entries
#   - state/bashrc.lines    this project's .bashrc lines
#   - state/startup.sh      this project's startup script
#   - meta.json             trigger, commit, branch, file count, total bytes
#   - README.md             what + the one-line rollback command
#
# Pruning: keeps the 20 most recent snapshots, drops older.
#
# Usage:
#   ./scripts/snapshot.sh create [--trigger <name>] [--quiet]
#   ./scripts/snapshot.sh list
#   ./scripts/snapshot.sh restore <snapshot-dir>
#   ./scripts/snapshot.sh prune [--keep N]
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

CMD="${1:-create}"; shift || true

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

cmd_create() {
    local trigger="manual"
    local quiet=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --trigger) shift; trigger="${1:-manual}" ;;
            --trigger=*) trigger="${1#--trigger=}" ;;
            --quiet) quiet=true ;;
        esac
        shift
    done

    # Second-precision plus a 3-digit fractional suffix so two snapshots taken
    # within the same second by chained scripts (e.g. fresh → snapshot → init)
    # don't collide and clobber each other.
    local ts frac
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    frac="$(date -u +%N 2>/dev/null | cut -c1-3)"
    [ -z "$frac" ] || [ "$frac" = "N" ] && frac="$(printf '%03d' $((RANDOM % 1000)))"
    local snap="archive/snapshot-${ts}-${frac}"

    # Self-protect: ensure archive/snapshot-*/ is gitignored before we write
    # anything. Otherwise a later `git add -A && git commit` can sweep the
    # snapshot into version control, and a subsequent `git reset --hard` to
    # the captured commit will then DELETE the snapshot we need to restore.
    if [ -f .gitignore ]; then
        grep -qF "archive/snapshot-*/" .gitignore 2>/dev/null \
            || echo "archive/snapshot-*/" >> .gitignore
        grep -qF "archive/fresh-*/" .gitignore 2>/dev/null \
            || echo "archive/fresh-*/" >> .gitignore
    else
        printf "archive/snapshot-*/\narchive/fresh-*/\n" > .gitignore
    fi
    # If somehow it still collides (very fast loop on a system without %N),
    # bump until unique.
    local n=0
    while [ -d "$snap" ] && [ "$n" -lt 1000 ]; do
        n=$((n + 1))
        snap="archive/snapshot-${ts}-${frac}-${n}"
    done
    mkdir -p "$snap/state"

    # Manifest: tracked + untracked files with sizes. Bounded — exclude the
    # huge / regenerable trees so the snapshot stays small.
    {
        echo "# manifest"
        echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# columns: bytes path"
        git ls-files 2>/dev/null | while IFS= read -r f; do
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            echo "$sz $f"
        done
        git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
            case "$f" in
                node_modules/*|.venv/*|venv/*|graphify-out/*|archive/*|.next/*|dist/*|build/*|target/*) continue ;;
            esac
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            echo "$sz $f"
        done
    } > "$snap/manifest.txt"

    # Working-tree patch: every TRACKED uncommitted change in one file.
    git diff HEAD > "$snap/working-tree.patch" 2>/dev/null || true
    [ -s "$snap/working-tree.patch" ] || rm -f "$snap/working-tree.patch"

    # Untracked file CONTENTS as a tar — the manifest lists names but a real
    # rollback needs bodies. Excludes the same vendored / regenerable trees
    # the manifest excludes. Empty tar gets removed.
    git ls-files --others --exclude-standard 2>/dev/null \
        | grep -vE '^(node_modules|\.venv|venv|graphify-out|archive|\.next|dist|build|target)/' \
        > "$snap/.untracked-list" 2>/dev/null || true
    if [ -s "$snap/.untracked-list" ]; then
        tar -czf "$snap/untracked.tar.gz" -T "$snap/.untracked-list" 2>/dev/null || true
        [ -s "$snap/untracked.tar.gz" ] || rm -f "$snap/untracked.tar.gz"
    fi
    rm -f "$snap/.untracked-list"

    # State: things NOT in git that the project depends on.
    [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$snap/state/settings.json"
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -E "(claude_preflight: $PROJECT_NAME|$PROJECT_DIR/scripts/graphify-sync)" \
            > "$snap/state/crontab.lines" 2>/dev/null || true
        [ -s "$snap/state/crontab.lines" ] || rm -f "$snap/state/crontab.lines"
    fi
    [ -f "$HOME/.bashrc" ] && grep -E "(claude_preflight: $PROJECT_NAME|sync-${PROJECT_NAME}\.sh)" "$HOME/.bashrc" \
        > "$snap/state/bashrc.lines" 2>/dev/null || true
    [ -s "$snap/state/bashrc.lines" ] || rm -f "$snap/state/bashrc.lines"
    local startup_script="$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"
    [ -f "$startup_script" ] && cp "$startup_script" "$snap/state/startup.sh"

    # Meta: machine-readable summary.
    local commit branch file_count total_bytes
    commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    branch="$(git branch --show-current 2>/dev/null || echo detached)"
    file_count="$(wc -l < "$snap/manifest.txt")"
    total_bytes="$(awk '{s+=$1} END {print s+0}' "$snap/manifest.txt")"
    cat > "$snap/meta.json" <<META
{
  "timestamp": "${ts}",
  "trigger": "${trigger}",
  "project": "${PROJECT_NAME}",
  "commit": "${commit}",
  "branch": "${branch}",
  "file_count": ${file_count},
  "total_bytes": ${total_bytes}
}
META

    # README: what's here + the one-line rollback.
    cat > "$snap/README.md" <<README
# Snapshot ${ts}

Captured before: \`${trigger}\`
Project:         ${PROJECT_NAME}
Branch:          ${branch}
Commit:          ${commit}
Files tracked:   ${file_count}

## Contents

- \`manifest.txt\` — file listing with sizes (tracked + untracked, vendored dirs excluded)
- \`working-tree.patch\` — uncommitted changes as a single git patch (omitted if working tree was clean)
- \`state/\` — what's not in git: \`~/.claude/settings.json\`, this project's cron entries, \`.bashrc\` lines, startup script
- \`meta.json\` — machine-readable summary

## Rollback

\`\`\`bash
./scripts/snapshot.sh restore archive/snapshot-${ts}
\`\`\`

Restore semantics:
- \`git reset --hard ${commit}\` to put the working tree back at the captured commit
- Apply \`working-tree.patch\` to recover uncommitted work
- Copy \`state/settings.json\` back to \`~/.claude/settings.json\` (after diffing)
- Re-add captured cron / .bashrc / startup lines (deduped)

The restore is interactive and prompts at each step.
README

    [ "$quiet" = true ] || {
        echo -e "${CYAN}[snapshot]${NC} state captured to ${snap}"
        echo -e "           rollback: ./scripts/snapshot.sh restore ${snap}"
    }

    # Stdout the snapshot path so callers can capture it.
    echo "$snap"

    # Auto-prune.
    cmd_prune --keep 20 --quiet >/dev/null 2>&1 || true
}

cmd_list() {
    if [ ! -d archive ] || [ -z "$(ls -A archive/ 2>/dev/null | grep '^snapshot-')" ]; then
        echo "  (no snapshots)"
        return
    fi
    printf "%-32s %-14s %-8s %s\n" "snapshot" "trigger" "files" "branch@commit"
    for d in archive/snapshot-*/; do
        [ -d "$d" ] || continue
        local meta="$d/meta.json"
        [ -f "$meta" ] || continue
        python3 - "$meta" "$d" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(f"{sys.argv[2].rstrip('/'):<32} {m.get('trigger','?'):<14} {m.get('file_count','?'):<8} {m.get('branch','?')}@{m.get('commit','?')[:8]}")
PY
    done
}

cmd_restore() {
    local snap="${1:-}"
    [ -z "$snap" ] && { echo "usage: snapshot.sh restore <snapshot-dir>" >&2; exit 2; }
    [ -d "$snap" ] || { echo "no such snapshot: $snap" >&2; exit 2; }
    [ -f "$snap/meta.json" ] || { echo "missing $snap/meta.json — refusing to restore" >&2; exit 2; }

    echo -e "${CYAN}[snapshot]${NC} restoring from $snap"
    cat "$snap/README.md" | head -10
    echo ""
    read -r -p "  Restore git working tree to captured commit? (y/N) " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        local commit; commit="$(python3 -c "import json; print(json.load(open('$snap/meta.json'))['commit'])")"
        if [ "$commit" != "unknown" ]; then
            git reset --hard "$commit" 2>&1 | tail -1
            echo -e "  ${GREEN}[OK]${NC} reset to $commit"
        fi
    fi
    if [ -f "$snap/working-tree.patch" ]; then
        read -r -p "  Apply working-tree.patch (tracked uncommitted changes)? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            git apply "$snap/working-tree.patch" && echo -e "  ${GREEN}[OK]${NC} patch applied"
        fi
    fi
    if [ -f "$snap/untracked.tar.gz" ]; then
        read -r -p "  Restore untracked files from snapshot? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            tar -xzf "$snap/untracked.tar.gz" && echo -e "  ${GREEN}[OK]${NC} untracked files restored"
        fi
    fi
    if [ -f "$snap/state/settings.json" ]; then
        read -r -p "  Diff captured ~/.claude/settings.json against current? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            diff -u "$HOME/.claude/settings.json" "$snap/state/settings.json" | head -40 || true
            read -r -p "  Overwrite current settings.json with the captured one? (y/N) " ans2
            if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
                cp "$snap/state/settings.json" "$HOME/.claude/settings.json"
                echo -e "  ${GREEN}[OK]${NC} settings.json restored"
            fi
        fi
    fi
    if [ -f "$snap/state/crontab.lines" ] && command -v crontab >/dev/null 2>&1; then
        read -r -p "  Re-add captured cron lines (deduped against existing)? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            ( crontab -l 2>/dev/null; cat "$snap/state/crontab.lines" ) | awk '!seen[$0]++' | crontab -
            echo -e "  ${GREEN}[OK]${NC} cron entries restored"
        fi
    fi
    if [ -f "$snap/state/bashrc.lines" ]; then
        read -r -p "  Re-add captured .bashrc lines (deduped)? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            ( cat "$HOME/.bashrc"; cat "$snap/state/bashrc.lines" ) | awk '!seen[$0]++' > "$HOME/.bashrc.tmp" \
                && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
            echo -e "  ${GREEN}[OK]${NC} .bashrc restored"
        fi
    fi
    if [ -f "$snap/state/startup.sh" ]; then
        local startup_script="$HOME/.claude/startup/sync-${PROJECT_NAME}.sh"
        read -r -p "  Restore startup script $startup_script? (y/N) " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            mkdir -p "$(dirname "$startup_script")"
            cp "$snap/state/startup.sh" "$startup_script"
            chmod +x "$startup_script"
            echo -e "  ${GREEN}[OK]${NC} startup script restored"
        fi
    fi
    echo -e "${CYAN}[snapshot]${NC} restore complete."
}

cmd_keep() {
    local snap="${1:-}"
    [ -z "$snap" ] && { echo "usage: snapshot.sh keep <snapshot-dir>" >&2; exit 2; }
    [ -d "$snap" ] || { echo "no such snapshot: $snap" >&2; exit 2; }
    touch "$snap/.keep"
    echo "  marked $snap as keep — auto-prune will skip it"
}

cmd_unkeep() {
    local snap="${1:-}"
    [ -z "$snap" ] && { echo "usage: snapshot.sh unkeep <snapshot-dir>" >&2; exit 2; }
    rm -f "$snap/.keep"
    echo "  removed keep marker on $snap"
}

cmd_prune() {
    local keep=20
    local quiet=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep) shift; keep="${1:-20}" ;;
            --keep=*) keep="${1#--keep=}" ;;
            --quiet) quiet=true ;;
        esac
        shift
    done
    [ -d archive ] || return 0
    # Separate "keeper" snapshots (have .keep) from prunable ones.
    local prunable kept
    prunable=$(ls -1d archive/snapshot-*/ 2>/dev/null | while IFS= read -r d; do
        [ -f "$d/.keep" ] || echo "$d"
    done | sort)
    kept=$(ls -1d archive/snapshot-*/ 2>/dev/null | while IFS= read -r d; do
        [ -f "$d/.keep" ] && echo "$d"
    done | wc -l)
    local count; count=$(echo "$prunable" | grep -c '.' || true)
    [ -z "$prunable" ] && { [ "$quiet" = true ] || echo "  (no prunable snapshots; ${kept} keeper(s))"; return 0; }
    if [ "$count" -le "$keep" ]; then
        [ "$quiet" = true ] || echo "  ${count} prunable snapshot(s) — under cap (${keep}); ${kept} keeper(s) protected"
        return 0
    fi
    local to_drop=$((count - keep))
    [ "$quiet" = true ] || echo "  pruning $to_drop snapshot(s); ${kept} keeper(s) protected"
    echo "$prunable" | head -"$to_drop" | while IFS= read -r d; do
        rm -rf "$d"
        [ "$quiet" = true ] || echo "    dropped $d"
    done
}

case "$CMD" in
    create)  cmd_create  "$@" ;;
    list)    cmd_list ;;
    restore) cmd_restore "$@" ;;
    prune)   cmd_prune   "$@" ;;
    keep)    cmd_keep    "$@" ;;
    unkeep)  cmd_unkeep  "$@" ;;
    *)
        cat <<EOF
Usage: snapshot.sh <command>

Commands:
  create [--trigger <name>] [--quiet]   Snapshot the project, print the rollback command
  list                                  List all snapshots
  restore <snapshot-dir>                Interactive restore from a snapshot
  prune [--keep N]                      Drop prunable snapshots older than the most recent N (default 20)
  keep <snapshot-dir>                   Mark a snapshot as protected from auto-prune
  unkeep <snapshot-dir>                 Remove the protection marker
EOF
        exit 2
        ;;
esac
