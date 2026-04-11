#!/usr/bin/env bash
# sync-health.sh - Health check + optional restart for the graphify sync daemon.
#
# Status modes:
#   running       — pid file exists AND process is alive
#   crashed       — pid file exists but process is gone
#   stopped       — no pid file
#   not-installed — graphify-out/ does not exist (no graph to sync)
#
# Usage:
#   ./scripts/sync-health.sh            # report status, exit 0=running, 1=anything else
#   ./scripts/sync-health.sh --restart  # restart if crashed/stopped (idempotent)
#   ./scripts/sync-health.sh --status   # same as no args
set -uo pipefail

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR"

RESTART=false
for arg in "$@"; do
    case "$arg" in
        --restart) RESTART=true ;;
        --status)  RESTART=false ;;
    esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

PID_FILE="graphify-out/.sync.pid"
LOG_FILE="graphify-out/sync.log"

determine_status() {
    if [ ! -d graphify-out ]; then echo "not-installed"; return; fi
    if [ ! -f "$PID_FILE" ]; then echo "stopped"; return; fi
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "crashed"; return
    fi
    echo "running"
}

start_daemon() {
    if [ ! -x scripts/graphify-sync.sh ]; then
        echo -e "  ${RED}[ERR]${NC} scripts/graphify-sync.sh not present" >&2
        return 1
    fi
    rm -f "$PID_FILE"
    nohup ./scripts/graphify-sync.sh --watch > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1
    if ps -p "$pid" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} started (PID $pid)"
        return 0
    fi
    echo -e "  ${RED}[ERR]${NC} daemon exited within 1s — see $LOG_FILE" >&2
    return 1
}

last_error_from_log() {
    [ -f "$LOG_FILE" ] || return
    grep -iE "(error|traceback|fatal|fail)" "$LOG_FILE" | tail -3
}

STATUS="$(determine_status)"
case "$STATUS" in
    running)
        PID="$(cat "$PID_FILE")"
        echo -e "  ${GREEN}[OK]${NC} sync daemon running (PID $PID)"
        UPTIME_S=$(($(date +%s) - $(stat -c %Y "$PID_FILE" 2>/dev/null || echo 0)))
        if [ "$UPTIME_S" -gt 0 ]; then
            echo "       uptime: ~$((UPTIME_S/60))m"
        fi
        exit 0
        ;;
    crashed)
        PID="$(cat "$PID_FILE")"
        echo -e "  ${YELLOW}[WARN]${NC} sync daemon crashed (PID $PID gone)"
        echo "         last error from $LOG_FILE:"
        last_error_from_log | sed 's/^/           /'
        if [ "$RESTART" = "true" ]; then
            echo "  restarting..."
            start_daemon || exit 1
            exit 0
        fi
        echo "         restart with: ./scripts/sync-health.sh --restart"
        exit 1
        ;;
    stopped)
        echo -e "  ${YELLOW}[WARN]${NC} sync daemon stopped"
        if [ "$RESTART" = "true" ]; then
            echo "  starting..."
            start_daemon || exit 1
            exit 0
        fi
        echo "         start with: ./scripts/sync-health.sh --restart"
        exit 1
        ;;
    not-installed)
        echo -e "  ${YELLOW}[WARN]${NC} no graphify-out/ — run /graphify . first"
        exit 1
        ;;
esac
