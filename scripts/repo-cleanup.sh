#!/usr/bin/env bash
# repo-cleanup.sh - Analyze and reorganize the repo structure.
#
# SAFE BY DESIGN:
#   - Never deletes files. Moves them to organized locations.
#   - Binary blobs move to archive/, not trash.
#   - Dry run by default. --execute to apply.
#   - Git mv preserves history.
#
# Usage:
#   ./scripts/repo-cleanup.sh              # analyze only (dry run)
#   ./scripts/repo-cleanup.sh --execute    # apply reorganization
#
# Recommended sequence:
#   1. ./scripts/repo-cleanup.sh                    # review plan
#   2. ./scripts/repo-cleanup.sh --execute          # reorganize
#   3. ./scripts/graphify-rebuild.sh --ast-only     # remap clean structure
#   4. git add -A && git commit && git push

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

EXECUTE=false
[[ "${1:-}" == "--execute" ]] && EXECUTE=true

ACTIONS=()

plan()  { ACTIONS+=("$1|$2|$3"); echo "  → $1: $2 → $3"; }
planmk() { ACTIONS+=("MKDIR||$1"); }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Repository Cleanup & Reorganization            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
$EXECUTE && echo "[EXECUTE MODE]" || echo "[DRY RUN - use --execute to apply]"
echo ""

# ── Phase 1: Move binary assets to archive/ ───────────────
echo "Phase 1: Binary Assets → archive/"
planmk "archive/pdfs"
planmk "archive/legacy-js"
planmk "archive/legacy-docs"

for f in *.pdf; do
    [ -f "$f" ] && plan "MOVE" "$f" "archive/pdfs/$f"
done

for f in *.docx; do
    [ -f "$f" ] && plan "MOVE" "$f" "archive/legacy-docs/$f"
done

[ -d research/pdfs ] && for f in research/pdfs/*.pdf; do
    [ -f "$f" ] && plan "MOVE" "$f" "archive/pdfs/$(basename "$f")"
done

echo ""

# ── Phase 2: Root .md files → docs/ ───────────────────────
echo "Phase 2: Root Markdown → docs/"
planmk "docs/guides"
planmk "docs/operations"
planmk "docs/research"
planmk "docs/roadmap"

for f in *.md; do
    [ ! -f "$f" ] && continue
    BASENAME="$f"
    # Keep these at root
    case "$BASENAME" in
        README.md|CLAUDE.md|CONTRIBUTING.md|CHANGELOG.md|GRAPHIFY_INSTALL.md|PREFLIGHT_CHECKLIST.md)
            continue ;;
    esac
    # Route by content type
    case "$BASENAME" in
        TECHNIQUES.md|HANDOFF.md|QUICKSTART.md)
            plan "MOVE" "$f" "docs/guides/$BASENAME" ;;
        METHODOLOGY.md)
            plan "MOVE" "$f" "docs/research/$BASENAME" ;;
        ROADMAP.md)
            plan "MOVE" "$f" "docs/roadmap/$BASENAME" ;;
        blog-post*.md)
            planmk "blog/drafts"
            plan "MOVE" "$f" "blog/drafts/$BASENAME" ;;
        *)
            plan "MOVE" "$f" "docs/$BASENAME" ;;
    esac
done

echo ""

# ── Phase 3: Root scripts → scripts/ ──────────────────────
echo "Phase 3: Root Scripts → scripts/"

for f in *.js; do
    [ -f "$f" ] && plan "MOVE" "$f" "archive/legacy-js/$f"
done

[ -f setup.sh ] && plan "MOVE" "setup.sh" "scripts/setup.sh"
[ -f setup_gitbash.sh ] && plan "MOVE" "setup_gitbash.sh" "scripts/setup_gitbash.sh"

echo ""

# ── Phase 4: Consolidate scattered dirs ────────────────────
echo "Phase 4: Directory Consolidation"

# methodology/ → docs/methodology/ (if not already there)
if [ -d methodology ] && [ ! -d docs/methodology ]; then
    plan "MOVE" "methodology" "docs/methodology"
fi

# research/ → archive/research/ (if it's just PDFs)
if [ -d research ]; then
    NON_PDF=$(find research -type f -not -name '*.pdf' 2>/dev/null | head -1)
    if [ -z "$NON_PDF" ]; then
        plan "MOVE" "research" "archive/research"
    else
        plan "MOVE" "research" "docs/research-refs"
    fi
fi

echo ""

# ── Phase 5: .gitignore updates ───────────────────────────
echo "Phase 5: .gitignore Updates"

IGNORE_ADDS=()
grep -qx '*.pdf' .gitignore 2>/dev/null || IGNORE_ADDS+=('*.pdf')
grep -qx '*.docx' .gitignore 2>/dev/null || IGNORE_ADDS+=('*.docx')
grep -q '.claude/worktrees' .gitignore 2>/dev/null || IGNORE_ADDS+=('.claude/worktrees/')

if [ ${#IGNORE_ADDS[@]} -gt 0 ]; then
    echo "  → ADD to .gitignore: ${IGNORE_ADDS[*]}"
fi

echo ""

# ── Summary ────────────────────────────────────────────────
ROOT_FILES=$(ls -1 2>/dev/null | wc -l)
echo "Summary:"
echo "  Root items before: $ROOT_FILES"
echo "  Actions planned:   ${#ACTIONS[@]}"
echo "  Files deleted:     0 (reorganize only, never deletes)"
echo ""

# ── Execute ────────────────────────────────────────────────
if $EXECUTE; then
    echo "Executing..."
    echo ""

    # Create all target directories first
    for action in "${ACTIONS[@]}"; do
        IFS='|' read -r TYPE SRC DST <<< "$action"
        if [ "$TYPE" = "MKDIR" ]; then
            mkdir -p "$DST"
        fi
    done

    # Execute moves
    MOVED=0
    for action in "${ACTIONS[@]}"; do
        IFS='|' read -r TYPE SRC DST <<< "$action"
        [ "$TYPE" = "MKDIR" ] && continue
        if [ -e "$SRC" ]; then
            mkdir -p "$(dirname "$DST")"
            git mv "$SRC" "$DST" 2>/dev/null || mv "$SRC" "$DST"
            echo "  moved: $SRC → $DST"
            MOVED=$((MOVED + 1))
        fi
    done

    # .gitignore updates
    for entry in "${IGNORE_ADDS[@]:-}"; do
        [ -z "$entry" ] && continue
        if ! grep -qx "$entry" .gitignore 2>/dev/null; then
            echo "$entry" >> .gitignore
            echo "  added to .gitignore: $entry"
        fi
    done

    echo ""
    echo "Done. $MOVED files reorganized."
    echo ""
    echo "Next steps:"
    echo "  1. Review: git status"
    echo "  2. Commit: git add -A && git commit -m 'chore: repo reorganization'"
    echo "  3. Remap:  ./scripts/graphify-rebuild.sh --ast-only"
    echo "  4. Push:   git push origin main"
else
    echo "Run with --execute to apply."
    echo ""
    echo "Recommended sequence:"
    echo "  ./scripts/repo-cleanup.sh --execute"
    echo "  git add -A && git commit -m 'chore: repo reorganization'"
    echo "  ./scripts/graphify-rebuild.sh --ast-only"
    echo "  git push origin main"
fi
