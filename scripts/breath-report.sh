#!/bin/bash
# breath-report.sh — On-demand wellness report generator
# Enhanced: weekly scores, velocity patterns, streaks, trends, day-of-week analysis.
set -euo pipefail

BREATH_DIR="${BREATH_DIR:-${CLAUDE_PLUGIN_DATA:-$(cd "$(dirname "$0")/.." && pwd)}}"
HISTORY_FILE="${BREATH_DIR}/history.jsonl"
CONFIG_FILE="${BREATH_DIR}/config.json"

if [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ]; then
  echo "No session history found."
  exit 0
fi

# --- Basic stats ---
TOTAL_SESSIONS=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
TOTAL_HOURS=$(jq -s '[.[].duration_min] | add / 60' "$HISTORY_FILE" 2>/dev/null || echo 0)
AVG_DURATION=$(jq -s '[.[].duration_min] | add / length | floor' "$HISTORY_FILE" 2>/dev/null || echo 0)
AVG_PROMPTS=$(jq -s '[.[].prompts] | add / length | floor' "$HISTORY_FILE" 2>/dev/null || echo 0)
TOTAL_BREAKS=$(jq -s '[.[].breaks] | add' "$HISTORY_FILE" 2>/dev/null || echo 0)
TOTAL_NUDGES=$(jq -s '[.[].nudges_fired] | add' "$HISTORY_FILE" 2>/dev/null || echo 0)
SESSIONS_WITH_BREAKS=$(jq -s '[.[] | select(.breaks > 0)] | length' "$HISTORY_FILE" 2>/dev/null || echo 0)
LONGEST=$(jq -s '[.[].duration_min] | max' "$HISTORY_FILE" 2>/dev/null || echo 0)
DATE_RANGE_START=$(head -1 "$HISTORY_FILE" | jq -r '.date')
DATE_RANGE_END=$(tail -1 "$HISTORY_FILE" | jq -r '.date')

# --- Score stats (new fields may not exist in old history) ---
AVG_SCORE=$(jq -s '
  [.[] | select(.score != null) | .score] |
  if length > 0 then add / length | floor else null end
' "$HISTORY_FILE" 2>/dev/null)
[ "$AVG_SCORE" = "null" ] || [ -z "$AVG_SCORE" ] && AVG_SCORE="N/A"

TOTAL_FRUSTRATIONS=$(jq -s '
  [.[] | select(.frustration_events != null) | .frustration_events] |
  if length > 0 then add else 0 end
' "$HISTORY_FILE" 2>/dev/null || echo 0)

AVG_PEAK_VELOCITY=$(jq -s '
  [.[] | select(.peak_velocity != null and .peak_velocity > 0) | .peak_velocity] |
  if length > 0 then add / length | floor else null end
' "$HISTORY_FILE" 2>/dev/null)
[ "$AVG_PEAK_VELOCITY" = "null" ] || [ -z "$AVG_PEAK_VELOCITY" ] && AVG_PEAK_VELOCITY="N/A"

# --- Weekly score trend ---
WEEKLY_TREND=$(jq -sc '
  [.[] | select(.score != null)] |
  if length < 2 then "insufficient data"
  else
    sort_by(.date) |
    (length / 2 | floor) as $mid |
    ([.[:$mid][].score] | add / length) as $first_half |
    ([.[$mid:][].score] | add / length) as $second_half |
    if ($second_half - $first_half) > 5 then "↑ improving"
    elif ($first_half - $second_half) > 5 then "↓ declining"
    else "→ stable" end
  end
' "$HISTORY_FILE" 2>/dev/null || echo "insufficient data")

# --- Break ratio ---
BREAK_RATIO="0%"
if [ "$TOTAL_SESSIONS" -gt 0 ]; then
  BREAK_RATIO=$(awk -v wb="$SESSIONS_WITH_BREAKS" -v tot="$TOTAL_SESSIONS" 'BEGIN { printf "%.0f%%", (wb/tot)*100 }')
fi

# --- Day of week breakdown ---
DOW_BREAKDOWN=$(jq -sc '
  def dow(d):
    # Approximate day of week from date string (Zellers-like)
    d | split("-") | map(tonumber) |
    .[0] as $y | .[1] as $m | .[2] as $d |
    (if $m < 3 then ($m + 12) else $m end) as $m2 |
    (if $m < 3 then ($y - 1) else $y end) as $y2 |
    (($d + (13*($m2+1)/5|floor) + $y2 + ($y2/4|floor) - ($y2/100|floor) + ($y2/400|floor)) % 7) |
    if . == 0 then "Sat" elif . == 1 then "Sun" elif . == 2 then "Mon"
    elif . == 3 then "Tue" elif . == 4 then "Wed" elif . == 5 then "Thu"
    else "Fri" end;

  group_by(.date | split("-") | .[0:3] | join("-")) |
  map({
    date: .[0].date,
    day: (.[0].date | dow(.)),
    total_min: ([.[].duration_min] | add),
    sessions: length,
    avg_score: ([.[] | select(.score != null) | .score] | if length > 0 then add/length|floor else null end)
  }) |
  group_by(.day) |
  map({
    day: .[0].day,
    avg_min: ([.[].total_min] | add / length | floor),
    days_worked: length,
    avg_score: ([.[] | select(.avg_score != null) | .avg_score] | if length > 0 then add/length|floor else null end)
  }) |
  sort_by(
    if .day == "Mon" then 0 elif .day == "Tue" then 1 elif .day == "Wed" then 2
    elif .day == "Thu" then 3 elif .day == "Fri" then 4 elif .day == "Sat" then 5
    else 6 end
  )
' "$HISTORY_FILE" 2>/dev/null)

# --- Top 3 longest sessions ---
TOP_SESSIONS=$(jq -sc '
  sort_by(.duration_min) | reverse | .[0:3] |
  map("\(.date) \(.start)-\(.end) (\(.duration_min)min, \(.prompts)p" +
    (if .score then ", score:\(.score)" else "" end) + ")")
' "$HISTORY_FILE" 2>/dev/null)

# --- Build report ---
REPORT="# Breath — Wellness Intelligence Report

**Period:** ${DATE_RANGE_START} to ${DATE_RANGE_END}
**Trend:** ${WEEKLY_TREND}

## Summary

| Metric | Value |
|:---|:---|
| Total sessions | ${TOTAL_SESSIONS} |
| Total hours | $(printf '%.1f' "$TOTAL_HOURS") |
| Avg session duration | ${AVG_DURATION} min |
| Avg prompts/session | ${AVG_PROMPTS} |
| Longest session | ${LONGEST} min |
| Total breaks taken | ${TOTAL_BREAKS} |
| Break compliance | ${BREAK_RATIO} (${SESSIONS_WITH_BREAKS}/${TOTAL_SESSIONS} sessions) |
| Total nudges fired | ${TOTAL_NUDGES} |

## Behavioral Intelligence

| Metric | Value |
|:---|:---|
| Avg wellness score | ${AVG_SCORE}/100 |
| Avg peak velocity | ${AVG_PEAK_VELOCITY} prompts/5min |
| Total frustration events | ${TOTAL_FRUSTRATIONS} |
| Score trend | ${WEEKLY_TREND} |
"

# Day of week table
if [ -n "$DOW_BREAKDOWN" ] && [ "$DOW_BREAKDOWN" != "null" ]; then
  REPORT="${REPORT}
## Day of Week Patterns

| Day | Avg Minutes | Days Worked | Avg Score |
|:---|:---|:---|:---|"
  DOW_TABLE=$(echo "$DOW_BREAKDOWN" | jq -r '.[] | "| \(.day) | \(.avg_min) | \(.days_worked) | \(.avg_score // "N/A") |"' 2>/dev/null)
  if [ -n "$DOW_TABLE" ]; then
    REPORT="${REPORT}
${DOW_TABLE}"
  fi
fi

# Top sessions
if [ -n "$TOP_SESSIONS" ] && [ "$TOP_SESSIONS" != "null" ] && [ "$TOP_SESSIONS" != "[]" ]; then
  REPORT="${REPORT}

## Longest Sessions

$(echo "$TOP_SESSIONS" | jq -r '.[] | "- \(.)"' 2>/dev/null)
"
fi

REPORT="${REPORT}
---
*Generated $(date '+%Y-%m-%d %H:%M') by Claude Breath*"

echo "$REPORT"

# Save to vault if configured
if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
  VAULT_SUMMARIES=$(jq -r '.vault_summaries // false' "$CONFIG_FILE")
  VAULT_PATH=$(jq -r '.vault_summary_path // empty' "$CONFIG_FILE")
  if [ "$VAULT_SUMMARIES" = "true" ] && [ -n "$VAULT_PATH" ] && [ -d "$VAULT_PATH" ]; then
    FILENAME="${VAULT_PATH}/breath-report-$(date '+%Y-%m-%d').md"
    echo "$REPORT" > "$FILENAME"
    echo "Report saved to: $FILENAME"
  fi
fi
