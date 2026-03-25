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

# Fresh session — still show daily aggregate
if [ "$DURATION_MIN" -lt 1 ]; then
  # Quick daily stats even for fresh sessions
  fg="${esc}[38;5;252m"
  highlight="${esc}[38;5;213m"
  HISTORY_FILE="${BREATH_DIR}/history.jsonl"
  fresh_today_str=$(date "+%Y-%m-%d" 2>/dev/null)
  fresh_daily=""
  if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
    fresh_data=$(jq -sc --arg d "$fresh_today_str" '
      [.[] | select(.date == $d)] |
      { s: length, p: ([.[].prompts] | add // 0), m: ([.[].duration_min] | add // 0),
        sc: (if length > 0 then ([.[].score] | add / length | floor) else 0 end) }
    ' "$HISTORY_FILE" 2>/dev/null)
    if [ -n "$fresh_data" ]; then
      fs=$(echo "$fresh_data" | jq -r '.s // 0')
      fp=$(echo "$fresh_data" | jq -r '.p // 0')
      fm=$(echo "$fresh_data" | jq -r '.m // 0')
      fsc=$(echo "$fresh_data" | jq -r '.sc // 0')
      if [ "$fs" -gt 0 ]; then
        fh=$((fm / 60)); fmn=$((fm % 60))
        fsc_c="$good"; [ "$fsc" -lt 80 ] && fsc_c="$warn"; [ "$fsc" -lt 50 ] && fsc_c="$bad"
        fc="$good"; [ "$((fs + 1))" -ge 8 ] && fc="$warn"; [ "$((fs + 1))" -ge 12 ] && fc="$bad"
        fresh_daily="  ${muted}│${reset}  ${muted}today${reset} ${fc}$((fs + 1))${reset}${muted}s${reset} ${fg}${fp}${reset}${muted}p${reset} ${highlight}${fh}h$(printf '%02d' $fmn)m${reset} ${muted}avg${reset} ${fsc_c}${fsc}${reset}"
      fi
    fi
  fi
  printf "${muted}[${reset}${good}0h00m${reset} ${muted}|${reset} ${good}fresh${reset}${muted}]${reset}${fresh_daily}"
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

# --- Creature tag ---
creature_tag=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREATURE_ENGINE="${SCRIPT_DIR}/breath-creature.sh"
CREATURE_FILE="${BREATH_DIR}/creature.json"
if [ -f "$CREATURE_ENGINE" ] && [ -f "$CREATURE_FILE" ] && jq empty "$CREATURE_FILE" 2>/dev/null; then
  source "$CREATURE_ENGINE"
  load_creature

  local_species=$(creature_val '.species')
  local_stage=$(creature_num '.stage')
  local_hp=$(creature_num '.hp')
  local_coins=$(creature_num '.coins')
  local_ghost=$(creature_num '.ghost_sessions_remaining')
  local_name=$(creature_val '.name')

  if [ "$local_ghost" -gt 0 ]; then
    creature_tag=" ${muted}|${reset} ${bad}👻${local_ghost}${reset} ${purple}${local_coins}💎${reset}"
  elif [ -z "$local_species" ] || [ "$local_species" = "null" ]; then
    creature_tag=" ${muted}|${reset} 🥚 ${purple}${local_coins}💎${reset}"
  else
    local_emoji=$(get_creature_emoji "$local_species" "$local_stage")
    local_mood=$(get_mood_emoji "$local_hp")

    # HP color
    hp_color="$good"
    if [ "$local_hp" -lt 20 ]; then
      hp_color="$bad"
    elif [ "$local_hp" -lt 40 ]; then
      hp_color="$orange"
    elif [ "$local_hp" -lt 60 ]; then
      hp_color="$warn"
    fi

    local_name_tag=""
    if [ -n "$local_name" ] && [ "$local_name" != "null" ]; then
      local_name_tag="${blue}${local_name}${reset} "
    fi

    creature_tag=" ${muted}|${reset} ${local_name_tag}${local_emoji}${local_mood} ${hp_color}${local_hp}hp${reset} ${purple}${local_coins}💎${reset}"
  fi
fi

# --- Daily aggregate (multi-session) ---
HISTORY_FILE="${BREATH_DIR}/history.jsonl"
today_str=$(date "+%Y-%m-%d" 2>/dev/null)
fg="${esc}[38;5;252m"
highlight="${esc}[38;5;213m"

d_past_sessions=0
d_past_prompts=0
d_past_minutes=0
d_past_avg_score=0
d_past_breaks=0

if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
  daily_data=$(jq -sc --arg d "$today_str" '
    [.[] | select(.date == $d)] |
    {
      sessions: length,
      prompts: ([.[].prompts] | add // 0),
      minutes: ([.[].duration_min] | add // 0),
      avg_score: (if length > 0 then ([.[].score] | add / length | floor) else 0 end),
      breaks: ([.[].breaks] | add // 0)
    }
  ' "$HISTORY_FILE" 2>/dev/null)

  if [ -n "$daily_data" ]; then
    d_past_sessions=$(echo "$daily_data" | jq -r '.sessions // 0')
    d_past_prompts=$(echo "$daily_data" | jq -r '.prompts // 0')
    d_past_minutes=$(echo "$daily_data" | jq -r '.minutes // 0')
    d_past_avg_score=$(echo "$daily_data" | jq -r '.avg_score // 0')
    d_past_breaks=$(echo "$daily_data" | jq -r '.breaks // 0')
  fi
fi

# Current session counts toward today
d_total_sessions=$(( d_past_sessions + 1 ))
d_total_prompts=$(( d_past_prompts + PROMPT_COUNT ))
d_total_minutes=$(( d_past_minutes + DURATION_MIN ))
d_total_breaks=$(( d_past_breaks + BREAK_COUNT ))
d_total_hrs=$(( d_total_minutes / 60 ))
d_total_mins=$(( d_total_minutes % 60 ))

# Daily avg score
if [ "$d_past_sessions" -gt 0 ]; then
  d_avg_score=$(( (d_past_avg_score * d_past_sessions + SESSION_SCORE) / d_total_sessions ))
else
  d_avg_score=$SESSION_SCORE
fi

# Avg score color
d_sc="$good"
[ "$d_avg_score" -lt 80 ] && d_sc="$warn"
[ "$d_avg_score" -lt 50 ] && d_sc="$bad"

# Session count color (more sessions = more fatigue risk)
d_sess_color="$good"
[ "$d_total_sessions" -ge 8 ] && d_sess_color="$warn"
[ "$d_total_sessions" -ge 12 ] && d_sess_color="$bad"

daily_tag="  ${muted}│${reset}  ${muted}today${reset}"
daily_tag="${daily_tag} ${d_sess_color}${d_total_sessions}${reset}${muted}s${reset}"
daily_tag="${daily_tag} ${fg}${d_total_prompts}${reset}${muted}p${reset}"
daily_tag="${daily_tag} ${highlight}${d_total_hrs}h$(printf '%02d' $d_total_mins)m${reset}"
[ "$d_total_breaks" -gt 0 ] && daily_tag="${daily_tag} ${good}☕${d_total_breaks}${reset}"
daily_tag="${daily_tag} ${muted}avg${reset} ${d_sc}${d_avg_score}${reset}"

# --- Build output ---
# Format: [1h32m | 27p | ☀️ 92 | 🐸😊 85hp 45💎]  │  today 3s 42p 2h15m avg 88
printf "${muted}[${reset}${dur_color}${DUR_STR}${reset} ${muted}|${reset} ${dur_color}${PROMPT_COUNT}p${reset}${vel_tag}${break_tag} ${muted}|${reset} ${indicator} ${score_color}${SESSION_SCORE}${reset}${streak_tag}${creature_tag}${muted}]${reset}${daily_tag}"
