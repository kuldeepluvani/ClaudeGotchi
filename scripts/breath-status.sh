#!/bin/bash
# breath-status.sh — Statusline segment for Claude Breath
# Reads state.json, outputs a compact wellness indicator string.
# Enhanced: shows velocity, streak, and score indicators.
set -euo pipefail

BREATH_DIR="${BREATH_DIR:-${CLAUDE_PLUGIN_DATA:-$(cd "$(dirname "$0")/.." && pwd)}}"
STATE_FILE="${BREATH_DIR}/state.json"
CONFIG_FILE="${BREATH_DIR}/config.json"

# Colors
esc=$(printf '\033')
reset="${esc}[0m"
muted="${esc}[38;5;240m"
good="${esc}[38;5;42m"
warn="${esc}[38;5;220m"
orange="${esc}[38;5;208m"
bad="${esc}[38;5;196m"
blue="${esc}[38;5;75m"
purple="${esc}[38;5;141m"

if [ ! -f "$STATE_FILE" ] || ! jq empty "$STATE_FILE" 2>/dev/null; then
  echo ""
  exit 0
fi

STATE=$(cat "$STATE_FILE")
NOW=$(date +%s)

SESSION_START=$(echo "$STATE" | jq -r '.session_start // 0')
PROMPT_COUNT=$(echo "$STATE" | jq -r '.prompt_count // 0')
LAST_NUDGE_LEVEL=$(echo "$STATE" | jq -r '.last_nudge_level // 0')
PEAK_VELOCITY=$(echo "$STATE" | jq -r '.peak_velocity // 0')
FRUSTRATION_COUNT=$(echo "$STATE" | jq -r '.frustration_count // 0')
SESSION_SCORE=$(echo "$STATE" | jq -r '.session_score // 100')
OVERWORK_STREAK=$(echo "$STATE" | jq -r '.overwork_streak // 0')
HEALTHY_STREAK=$(echo "$STATE" | jq -r '.healthy_streak // 0')
BREAK_COUNT=$(echo "$STATE" | jq -r '.break_count // 0')

DURATION_SEC=$((NOW - SESSION_START))
DURATION_MIN=$((DURATION_SEC / 60))

# Calculate current velocity (prompts in last 5 min)
VELOCITY=0
if echo "$STATE" | jq -e '.prompt_timestamps | length > 0' >/dev/null 2>&1; then
  CUTOFF=$((NOW - 300))
  VELOCITY=$(echo "$STATE" | jq --argjson cutoff "$CUTOFF" '
    [.prompt_timestamps[] | select(. >= $cutoff)] | length
  ' 2>/dev/null || echo 0)
fi

# Fresh session
if [ "$DURATION_MIN" -lt 1 ]; then
  printf "${muted}[${reset}${good}0h00m${reset} ${muted}|${reset} ${good}fresh${reset}${muted}]${reset}"
  exit 0
fi

DUR_H=$((DURATION_MIN / 60))
DUR_M=$((DURATION_MIN % 60))
DUR_STR="${DUR_H}h$(printf '%02d' $DUR_M)m"

# Load config for thresholds
MULTIPLIER="1.0"
if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
  T1=$(jq -r '.nudge_thresholds_min[0] // 90' "$CONFIG_FILE")
  VEL_THRESH=$(jq -r '.velocity_threshold // 15' "$CONFIG_FILE")
  FRUST_THRESH=$(jq -r '.frustration_threshold // 20' "$CONFIG_FILE")
  STREAK_ALERT=$(jq -r '.streak_alert_days // 3' "$CONFIG_FILE")
else
  T1=90
  VEL_THRESH=15
  FRUST_THRESH=20
  STREAK_ALERT=3
fi

ET1=$(awk -v t="$T1" -v m="$MULTIPLIER" 'BEGIN { printf "%.0f", t * m }')

# --- Primary indicator (same logic as before, enhanced) ---
if [ "$LAST_NUDGE_LEVEL" -ge 3 ] || [ "$DURATION_MIN" -ge 180 ]; then
  indicator="${bad}🔴${reset}"
  dur_color="$bad"
elif [ "$FRUSTRATION_COUNT" -gt 0 ]; then
  indicator="${bad}🌀${reset}"
  dur_color="$orange"
elif [ "$LAST_NUDGE_LEVEL" -ge 2 ] || [ "$DURATION_MIN" -ge 120 ]; then
  indicator="${orange}🟠${reset}"
  dur_color="$orange"
elif [ "$LAST_NUDGE_LEVEL" -ge 1 ] || [ "$DURATION_MIN" -ge "$ET1" ]; then
  indicator="${warn}🟡${reset}"
  dur_color="$warn"
else
  indicator="${good}☀️${reset}"
  dur_color="$good"
fi

# --- Velocity tag ---
vel_tag=""
if [ "$VELOCITY" -ge "$FRUST_THRESH" ]; then
  vel_tag=" ${bad}⚡${VELOCITY}${reset}"
elif [ "$VELOCITY" -ge "$VEL_THRESH" ]; then
  vel_tag=" ${warn}⚡${VELOCITY}${reset}"
fi

# --- Streak tag ---
streak_tag=""
if [ "$OVERWORK_STREAK" -ge "$STREAK_ALERT" ]; then
  streak_tag=" ${orange}🔥${OVERWORK_STREAK}d${reset}"
elif [ "$HEALTHY_STREAK" -ge 3 ]; then
  streak_tag=" ${good}💚${HEALTHY_STREAK}d${reset}"
fi

# --- Break indicator ---
break_tag=""
if [ "$BREAK_COUNT" -gt 0 ]; then
  break_tag=" ${good}☕${BREAK_COUNT}${reset}"
fi

# --- Score color ---
score_color="$good"
if [ "$SESSION_SCORE" -lt 30 ]; then
  score_color="$bad"
elif [ "$SESSION_SCORE" -lt 60 ]; then
  score_color="$orange"
elif [ "$SESSION_SCORE" -lt 80 ]; then
  score_color="$warn"
fi

# --- Build output ---
# Format: [1h32m | 27p | ☀️ 92]  or  [2h05m | 41p ⚡18 | 🌀 45 🔥4d]
printf "${muted}[${reset}${dur_color}${DUR_STR}${reset} ${muted}|${reset} ${dur_color}${PROMPT_COUNT}p${reset}${vel_tag}${break_tag} ${muted}|${reset} ${indicator} ${score_color}${SESSION_SCORE}${reset}${streak_tag}${muted}]${reset}"
