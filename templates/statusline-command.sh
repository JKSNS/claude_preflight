#!/usr/bin/env bash
# Claude Code statusLine — context health + model + session cost
# Shows: model | context usage % (color-coded) | $cost this session

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null || echo "")
pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
model=$(echo "$input" | jq -r '.model.display_name // "?"' 2>/dev/null)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

# Color context % — green <50, yellow 50-79, red 80+
if [ "${pct:-0}" -ge 80 ] 2>/dev/null; then
    pct_color='\033[01;31m'
elif [ "${pct:-0}" -ge 50 ] 2>/dev/null; then
    pct_color='\033[01;33m'
else
    pct_color='\033[01;32m'
fi

# Line 1: user@host:path
printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m' \
    "$(whoami)" "$(hostname -s)" "$cwd"
# Line 2: model | context | cost
printf '\n%s | ctx: %b%s%%\033[00m | $%.4f' \
    "$model" "$pct_color" "${pct:-0}" "${cost:-0}"
