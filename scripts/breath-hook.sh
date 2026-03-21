#!/bin/bash
# breath-hook.sh — Claude Code UserPromptSubmit hook for developer wellness
# Smart behavioral intelligence: velocity tracking, frustration detection,
# adaptive thresholds, streak awareness, session scoring, message variety.
# Outputs JSON for Claude Code hook API. Near-zero token cost.
set -euo pipefail

# Consume hook event JSON from stdin (Claude Code pipes it)
HOOK_INPUT=$(cat 2>/dev/null || true)

# --- Paths & Overrides ---
BREATH_DIR="${BREATH_DIR:-${CLAUDE_PLUGIN_DATA:-$(cd "$(dirname "$0")/.." && pwd)}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${BREATH_DIR}/config.json"
STATE_FILE="${BREATH_DIR}/state.json"
HISTORY_FILE="${BREATH_DIR}/history.jsonl"

mkdir -p "$BREATH_DIR"

# Source message pool if available
MESSAGES_FILE="${SCRIPT_DIR}/breath-messages.sh"
HAS_MESSAGES=0
if [ -f "$MESSAGES_FILE" ]; then
  # shellcheck source=breath-messages.sh
  source "$MESSAGES_FILE"
  HAS_MESSAGES=1
fi

# Source creature engine if available
CREATURE_FILE="${SCRIPT_DIR}/breath-creature.sh"
HAS_CREATURE=0
if [ -f "$CREATURE_FILE" ]; then
  # shellcheck source=breath-creature.sh
  source "$CREATURE_FILE"
  HAS_CREATURE=1
fi

# --- Default config (embedded) ---
DEFAULT_CONFIG='{
  "nudge_system_message": true,
  "nudge_thresholds_min": [90, 120, 180],
  "prompt_density_threshold": 20,
  "off_hours_multiplier": 0.67,
  "off_hours_start": 23,
  "off_hours_end": 7,
  "weekend_multiplier": 0.75,
  "break_gap_min": 5,
  "session_gap_min": 15,
  "nudge_cooldown_min": 15,
  "explicit_acknowledgment": false,
  "escalation_timeout_min": 20,
  "vault_summaries": false,
  "vault_summary_path": "",
  "history_retention_days": 14,
  "velocity_window_sec": 300,
  "velocity_threshold": 15,
  "frustration_threshold": 20,
  "streak_alert_days": 3,
  "adaptive_thresholds": true,
  "message_variety": true
}'

# --- Load or create config ---
load_config() {
  if [ ! -f "$CONFIG_FILE" ] || ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "$DEFAULT_CONFIG" > "$CONFIG_FILE"
  fi
  CONFIG=$(cat "$CONFIG_FILE")
}

cfg() {
  echo "$CONFIG" | jq -r "$1 // empty" 2>/dev/null
}

cfg_num() {
  local val
  val=$(echo "$CONFIG" | jq -r "$1 // empty" 2>/dev/null)
  [ -z "$val" ] && echo "$2" && return
  printf "%.0f" "$val" 2>/dev/null || echo "$2"
}

# --- Output helpers ---
suppress() {
  printf '{"suppressOutput":true}'
  exit 0
}

nudge() {
  local msg="$1"
  jq -nc --arg m "$msg" '{suppressOutput:false,systemMessage:$m}'
  exit 0
}

# --- State helpers ---
DEFAULT_STATE='{
  "session_start": 0,
  "last_prompt": 0,
  "prompt_count": 0,
  "last_nudge_level": 0,
  "last_nudge_time": 0,
  "break_count": 0,
  "prompt_timestamps": [],
  "peak_velocity": 0,
  "frustration_count": 0,
  "session_score": 100,
  "overwork_streak": 0,
  "healthy_streak": 0,
  "adaptive_multiplier": 1.0
}'

load_state() {
  if [ ! -f "$STATE_FILE" ] || ! jq empty "$STATE_FILE" 2>/dev/null; then
    STATE="$DEFAULT_STATE"
  else
    STATE=$(cat "$STATE_FILE")
    # Migrate: add new fields if missing (backward compat)
    STATE=$(echo "$STATE" | jq '
      .prompt_timestamps //= [] |
      .peak_velocity //= 0 |
      .frustration_count //= 0 |
      .session_score //= 100 |
      .overwork_streak //= 0 |
      .healthy_streak //= 0 |
      .adaptive_multiplier //= 1.0
    ')
  fi
}

state() {
  echo "$STATE" | jq -r "$1 // 0" 2>/dev/null
}

state_raw() {
  echo "$STATE" | jq -r "$1 // empty" 2>/dev/null
}

write_state() {
  echo "$STATE" | jq '.' > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- Velocity helpers ---
calculate_velocity() {
  local window_sec="$1"
  local cutoff=$(( NOW - window_sec ))
  echo "$STATE" | jq --argjson cutoff "$cutoff" '
    [.prompt_timestamps[] | select(. >= $cutoff)] | length
  ' 2>/dev/null || echo 0
}

update_timestamps() {
  local window_sec=$(cfg_num '.velocity_window_sec' 300)
  local cutoff=$(( NOW - window_sec ))
  STATE=$(echo "$STATE" | jq --argjson now "$NOW" --argjson cutoff "$cutoff" '
    .prompt_timestamps = ([.prompt_timestamps[] | select(. >= $cutoff)] + [$now]) |
    if (.prompt_timestamps | length) > 30 then .prompt_timestamps = .prompt_timestamps[-30:] else . end
  ')
}

# --- Streak helpers ---
calculate_streaks() {
  [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ] && return
  local t2=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[1] // 120')
  local streak_data
  streak_data=$(jq -sc '
    [.[].date] | unique | sort | reverse |
    . as $dates |
    {dates: $dates}
  ' "$HISTORY_FILE" 2>/dev/null) || return

  # Count consecutive recent days with long sessions
  local overwork_streak=0
  local today
  today=$(date "+%Y-%m-%d" 2>/dev/null)
  overwork_streak=$(jq -sc --arg t2 "$t2" --arg today "$today" '
    . as $sessions |
    [$sessions[] | select(.duration_min >= ($t2 | tonumber))] |
    [.[].date] | unique | sort | reverse |
    . as $overwork_dates |
    # Count consecutive days from today/yesterday backward
    reduce range(0; 30) as $i (
      {streak: 0, check_date: ($today | split("-") | .[0] as $y | .[1] as $m | .[2] as $d | $today), found_any: false};
      . as $acc |
      if $acc.streak == $i then
        ($today | . as $td |
          # Simple day subtraction (approximate, good enough for streaks)
          $overwork_dates | map(select(. != null)) |
          if any(. != null) then
            if ($overwork_dates | index($acc.check_date) != null) or ($i == 0 and ($overwork_dates[0] // "" | . >= ($today | explode | . as $e | $today))) then
              {streak: ($acc.streak + 1), check_date: $acc.check_date, found_any: true}
            else $acc end
          else $acc end
        )
      else $acc end
    ) | .streak
  ' "$HISTORY_FILE" 2>/dev/null) || overwork_streak=0

  # Simpler approach: count unique dates in last 7 days with overwork
  local week_ago
  week_ago=$(date -v-7d "+%Y-%m-%d" 2>/dev/null || date -d "7 days ago" "+%Y-%m-%d" 2>/dev/null || echo "2000-01-01")
  overwork_streak=$(jq -sc --arg t2 "$t2" --arg cutoff "$week_ago" '
    [.[] | select(.date >= $cutoff and .duration_min >= ($t2 | tonumber))] |
    [.[].date] | unique | length
  ' "$HISTORY_FILE" 2>/dev/null) || overwork_streak=0

  # Healthy streak: recent days where all sessions had breaks and stayed under T2
  local healthy_streak=0
  healthy_streak=$(jq -sc --arg t2 "$t2" --arg cutoff "$week_ago" '
    [.[] | select(.date >= $cutoff)] | group_by(.date) |
    map({date: .[0].date, max_dur: ([.[].duration_min] | max), had_breaks: (any(.[]; .breaks > 0))}) |
    sort_by(.date) | reverse |
    reduce .[] as $day ({streak: 0, broken: false};
      if .broken then .
      elif ($day.max_dur < ($t2 | tonumber)) and $day.had_breaks then {streak: (.streak + 1), broken: false}
      else {streak: .streak, broken: true} end
    ) | .streak
  ' "$HISTORY_FILE" 2>/dev/null) || healthy_streak=0

  STATE=$(echo "$STATE" | jq --argjson os "$overwork_streak" --argjson hs "$healthy_streak" '
    .overwork_streak = $os | .healthy_streak = $hs
  ')
}

# --- Adaptive threshold helpers ---
calculate_adaptive_multiplier() {
  [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ] && return
  local adapt=$(cfg '.adaptive_thresholds')
  [ "$adapt" != "true" ] && return

  local multiplier
  multiplier=$(jq -sc '
    # Median session duration
    [.[].duration_min] | sort |
    . as $sorted |
    ($sorted | length) as $len |
    if $len < 3 then 1.0  # Not enough data
    elif $len % 2 == 0 then (($sorted[$len/2 - 1] + $sorted[$len/2]) / 2)
    else $sorted[($len - 1) / 2] end |
    . as $median |
    # Sessions with breaks vs total
    ($sorted | length) as $total |
    ([.[] | select(.breaks > 0)] | length) as $with_breaks |
    ($with_breaks / ([1, $total] | max)) as $break_ratio |
    # Good habits (short sessions, regular breaks) = relax thresholds
    # Bad habits (long sessions, no breaks) = tighten thresholds
    if $break_ratio > 0.6 and $median < 90 then 1.1      # Good habits: +10%
    elif $break_ratio > 0.4 and $median < 120 then 1.0    # Normal
    elif $break_ratio < 0.2 and $median > 120 then 0.85   # Bad habits: -15%
    elif $median > 180 then 0.8                             # Very bad: -20%
    else 1.0 end |
    # Cap to ±30%
    if . > 1.3 then 1.3 elif . < 0.7 then 0.7 else . end
  ' "$HISTORY_FILE" 2>/dev/null) || multiplier="1.0"

  [ -z "$multiplier" ] && multiplier="1.0"
  STATE=$(echo "$STATE" | jq --arg m "$multiplier" '.adaptive_multiplier = ($m | tonumber)')
}

# --- Session score helpers ---
calculate_score() {
  local duration="$1" t1="$2" t2="$3" t3="$4" breaks="$5" frust="$6"
  local score=100

  # Decay past thresholds
  if [ "$duration" -ge "$t3" ]; then
    local past_t3=$(( duration - t3 ))
    local past_t2_t3=$(( t3 - t2 ))
    local past_t1_t2=$(( t2 - t1 ))
    score=$(( score - (past_t1_t2 * 1) - (past_t2_t3 * 2) - (past_t3 * 5) ))
  elif [ "$duration" -ge "$t2" ]; then
    local past_t2=$(( duration - t2 ))
    local past_t1_t2=$(( t2 - t1 ))
    score=$(( score - (past_t1_t2 * 1) - (past_t2 * 2) ))
  elif [ "$duration" -ge "$t1" ]; then
    local past_t1=$(( duration - t1 ))
    score=$(( score - (past_t1 * 1) ))
  fi

  # Break bonus (capped at +30)
  local break_bonus=$(( breaks * 10 ))
  [ "$break_bonus" -gt 30 ] && break_bonus=30
  score=$(( score + break_bonus ))

  # Frustration penalty
  score=$(( score - (frust * 10) ))

  # No frustration bonus
  [ "$frust" -eq 0 ] && score=$(( score + 5 ))

  # Clamp 0-100
  [ "$score" -lt 0 ] && score=0
  [ "$score" -gt 100 ] && score=100

  echo "$score"
}

# --- History helpers ---
log_session() {
  local s_start="$1" s_end="$2" s_prompts="$3" s_breaks="$4" s_nudges="$5"
  local duration_min=$(( (s_end - s_start) / 60 ))
  [ "$duration_min" -lt 1 ] && return

  local peak_vel=$(state '.peak_velocity')
  local frust=$(state '.frustration_count')
  local score=$(state '.session_score')

  local date_str=$(date -r "$s_start" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")
  local start_str=$(date -r "$s_start" "+%H:%M" 2>/dev/null || echo "??:??")
  local end_str=$(date -r "$s_end" "+%H:%M" 2>/dev/null || echo "??:??")

  printf '{"date":"%s","start":"%s","end":"%s","duration_min":%d,"prompts":%d,"breaks":%d,"nudges_fired":%d,"peak_velocity":%d,"frustration_events":%d,"score":%d}\n' \
    "$date_str" "$start_str" "$end_str" "$duration_min" "$s_prompts" "$s_breaks" "$s_nudges" \
    "$peak_vel" "$frust" "$score" \
    >> "$HISTORY_FILE"
}

prune_history() {
  [ ! -f "$HISTORY_FILE" ] && return
  local retention=$(cfg_num '.history_retention_days' 14)
  local cutoff_epoch=$(( $(date +%s) - (retention * 86400) ))
  local cutoff_date=$(date -r "$cutoff_epoch" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")
  local tmp="${HISTORY_FILE}.tmp"
  jq -c "select(.date >= \"$cutoff_date\")" "$HISTORY_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$HISTORY_FILE"
  local lines=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt 1000 ]; then
    tail -n 1000 "$HISTORY_FILE" > "$tmp"
    mv "$tmp" "$HISTORY_FILE"
  fi
}

# --- Message selection ---
select_message() {
  local level="$1" context="$2"

  if [ "$HAS_MESSAGES" -eq 1 ] && [ "$(cfg '.message_variety')" = "true" ]; then
    local seed=$(state '.session_start')
    get_nudge_message "$level" "$context" "$seed"
  else
    # Fallback static messages
    case "$level" in
      1) echo "Consider a stretch or water break." ;;
      2) echo "Extended focus — take 5-10 minutes." ;;
      3) echo "Strongly recommend a real break." ;;
    esac
  fi
}

# --- Determine nudge context ---
get_nudge_context() {
  local velocity="$1" is_frustrated="$2" is_off_hours="$3" is_weekend="$4" overwork_streak="$5"
  local streak_threshold=$(cfg_num '.streak_alert_days' 3)

  if [ "$is_frustrated" -eq 1 ]; then
    echo "frustration"
  elif [ "$overwork_streak" -ge "$streak_threshold" ]; then
    echo "streak"
  elif [ "$velocity" -ge "$(cfg_num '.velocity_threshold' 15)" ]; then
    echo "velocity"
  elif [ "$is_off_hours" -eq 1 ]; then
    echo "offhours"
  elif [ "$is_weekend" -eq 1 ]; then
    echo "weekend"
  else
    echo "normal"
  fi
}

# ============================================================
# MAIN
# ============================================================
load_config
load_state

NOW="${BREATH_NOW:-$(date +%s)}"
LAST_PROMPT=$(state '.last_prompt')
SESSION_GAP=$(cfg_num '.session_gap_min' 15)
BREAK_GAP=$(cfg_num '.break_gap_min' 5)
GAP_SEC=$(( NOW - LAST_PROMPT ))

# --- First prompt ever ---
if [ "$LAST_PROMPT" -eq 0 ]; then
  STATE=$(echo "$STATE" | jq --argjson now "$NOW" '
    .session_start = $now |
    .last_prompt = $now |
    .prompt_count = 1 |
    .last_nudge_level = 0 |
    .last_nudge_time = 0 |
    .break_count = 0 |
    .prompt_timestamps = [$now] |
    .peak_velocity = 0 |
    .frustration_count = 0 |
    .session_score = 100 |
    .overwork_streak = 0 |
    .healthy_streak = 0 |
    .adaptive_multiplier = 1.0
  ')
  calculate_streaks
  calculate_adaptive_multiplier
  write_state
  suppress

# --- New session (gap >= session_gap) ---
elif [ "$GAP_SEC" -ge $(( SESSION_GAP * 60 )) ]; then
  # Compute final score before logging
  local_t1=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[0] // 90')
  local_t2=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[1] // 120')
  local_t3=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[2] // 180')
  prev_duration=$(( (LAST_PROMPT - $(state '.session_start')) / 60 ))
  final_score=$(calculate_score "$prev_duration" "$local_t1" "$local_t2" "$local_t3" \
    "$(state '.break_count')" "$(state '.frustration_count')")
  STATE=$(echo "$STATE" | jq --argjson s "$final_score" '.session_score = $s')

  log_session "$(state '.session_start')" "$LAST_PROMPT" \
    "$(state '.prompt_count')" "$(state '.break_count')" "$(state '.last_nudge_level')"
  prune_history

  # Process creature at session boundary
  if [ "$HAS_CREATURE" -eq 1 ]; then
    load_creature
    process_session_end "$final_score" "$(state '.break_count')" \
      "$(state '.frustration_count')" "$(state '.overwork_streak')" "$(state '.healthy_streak')"
  fi

  STATE=$(echo "$STATE" | jq --argjson now "$NOW" '
    .session_start = $now |
    .last_prompt = $now |
    .prompt_count = 1 |
    .last_nudge_level = 0 |
    .last_nudge_time = 0 |
    .break_count = 0 |
    .prompt_timestamps = [$now] |
    .peak_velocity = 0 |
    .frustration_count = 0 |
    .session_score = 100
  ')
  calculate_streaks
  calculate_adaptive_multiplier
  write_state
  suppress

# --- Break detected (gap >= break_gap) — full self-heal ---
elif [ "$GAP_SEC" -ge $(( BREAK_GAP * 60 )) ]; then
  STATE=$(echo "$STATE" | jq --argjson now "$NOW" '
    .session_start = $now |
    .last_prompt = $now |
    .prompt_count = 1 |
    .last_nudge_level = 0 |
    .last_nudge_time = 0 |
    .break_count = (.break_count + 1) |
    .prompt_timestamps = [$now] |
    .peak_velocity = 0 |
    .frustration_count = 0
  ')
  # Recalculate score with break bonus
  local_t1=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[0] // 90')
  local_t2=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[1] // 120')
  local_t3=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[2] // 180')
  break_count=$(echo "$STATE" | jq -r '.break_count')
  fresh_score=$(calculate_score "0" "$local_t1" "$local_t2" "$local_t3" "$break_count" "0")
  STATE=$(echo "$STATE" | jq --argjson s "$fresh_score" '.session_score = $s')
  write_state
  suppress

# --- Normal prompt ---
else
  # Update timestamps and prompt count
  update_timestamps
  STATE=$(echo "$STATE" | jq --argjson now "$NOW" '
    .last_prompt = $now |
    .prompt_count = (.prompt_count + 1)
  ')

  # --- Calculate velocity ---
  VELOCITY_WINDOW=$(cfg_num '.velocity_window_sec' 300)
  VELOCITY=$(calculate_velocity "$VELOCITY_WINDOW")
  VELOCITY_THRESHOLD=$(cfg_num '.velocity_threshold' 15)
  FRUSTRATION_THRESHOLD=$(cfg_num '.frustration_threshold' 20)

  # Track peak velocity
  CURRENT_PEAK=$(state '.peak_velocity')
  if [ "$VELOCITY" -gt "$CURRENT_PEAK" ]; then
    STATE=$(echo "$STATE" | jq --argjson v "$VELOCITY" '.peak_velocity = $v')
  fi

  # Detect frustration
  IS_FRUSTRATED=0
  if [ "$VELOCITY" -ge "$FRUSTRATION_THRESHOLD" ]; then
    IS_FRUSTRATED=1
    STATE=$(echo "$STATE" | jq '.frustration_count = (.frustration_count + 1)')
  fi

  SESSION_START=$(state '.session_start')
  DURATION_MIN=$(( (NOW - SESSION_START) / 60 ))
  PROMPT_COUNT=$(echo "$STATE" | jq -r '.prompt_count')
  LAST_NUDGE_LEVEL=$(state '.last_nudge_level')
  LAST_NUDGE_TIME=$(state '.last_nudge_time')
  NUDGE_SYSTEM_MSG=$(cfg '.nudge_system_message')
  COOLDOWN=$(cfg_num '.nudge_cooldown_min' 15)
  DENSITY_THRESHOLD=$(cfg_num '.prompt_density_threshold' 40)
  OVERWORK_STREAK=$(state '.overwork_streak')

  HOUR="${BREATH_HOUR:-$(date +%-H)}"
  DAY="${BREATH_DAY:-$(date +%u)}"
  OFF_START=$(cfg_num '.off_hours_start' 23)
  OFF_END=$(cfg_num '.off_hours_end' 7)
  OFF_MULT=$(cfg '.off_hours_multiplier')
  WKND_MULT=$(cfg '.weekend_multiplier')
  [ -z "$OFF_MULT" ] && OFF_MULT="0.67"
  [ -z "$WKND_MULT" ] && WKND_MULT="0.75"

  IS_OFF_HOURS=0
  if [ "$OFF_START" -gt "$OFF_END" ]; then
    [ "$HOUR" -ge "$OFF_START" ] || [ "$HOUR" -lt "$OFF_END" ] && IS_OFF_HOURS=1
  else
    [ "$HOUR" -ge "$OFF_START" ] && [ "$HOUR" -lt "$OFF_END" ] && IS_OFF_HOURS=1
  fi

  IS_WEEKEND=0
  [ "$DAY" -ge 6 ] && IS_WEEKEND=1

  # --- Compute effective multiplier (time-of-day * adaptive) ---
  ADAPTIVE_MULT=$(state_raw '.adaptive_multiplier')
  [ -z "$ADAPTIVE_MULT" ] && ADAPTIVE_MULT="1.0"

  TIME_MULT="1.0"
  if [ "$IS_OFF_HOURS" -eq 1 ] && [ "$IS_WEEKEND" -eq 1 ]; then
    TIME_MULT=$(awk -v a="$OFF_MULT" -v b="$WKND_MULT" 'BEGIN { print (a < b) ? a : b }')
  elif [ "$IS_OFF_HOURS" -eq 1 ]; then
    TIME_MULT="$OFF_MULT"
  elif [ "$IS_WEEKEND" -eq 1 ]; then
    TIME_MULT="$WKND_MULT"
  fi

  MULTIPLIER=$(awk -v t="$TIME_MULT" -v a="$ADAPTIVE_MULT" 'BEGIN { printf "%.2f", t * a }')

  T1=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[0] // 90')
  T2=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[1] // 120')
  T3=$(echo "$CONFIG" | jq -r '.nudge_thresholds_min[2] // 180')

  ET1=$(awk -v t="$T1" -v m="$MULTIPLIER" 'BEGIN { printf "%.0f", t * m }')
  ET2=$(awk -v t="$T2" -v m="$MULTIPLIER" 'BEGIN { printf "%.0f", t * m }')
  ET3=$(awk -v t="$T3" -v m="$MULTIPLIER" 'BEGIN { printf "%.0f", t * m }')

  NUDGE_LEVEL=0
  [ "$DURATION_MIN" -ge "$ET1" ] && NUDGE_LEVEL=1
  [ "$DURATION_MIN" -ge "$ET2" ] && NUDGE_LEVEL=2
  [ "$DURATION_MIN" -ge "$ET3" ] && NUDGE_LEVEL=3

  # Density boost
  if [ "$PROMPT_COUNT" -gt "$DENSITY_THRESHOLD" ]; then
    NUDGE_LEVEL=$((NUDGE_LEVEL + 1))
    [ "$NUDGE_LEVEL" -gt 3 ] && NUDGE_LEVEL=3
  fi

  # Velocity boost: high velocity adds +1
  if [ "$VELOCITY" -ge "$VELOCITY_THRESHOLD" ] && [ "$VELOCITY" -lt "$FRUSTRATION_THRESHOLD" ]; then
    NUDGE_LEVEL=$((NUDGE_LEVEL + 1))
    [ "$NUDGE_LEVEL" -gt 3 ] && NUDGE_LEVEL=3
  fi

  # Frustration override: force at least level 2
  if [ "$IS_FRUSTRATED" -eq 1 ] && [ "$NUDGE_LEVEL" -lt 2 ]; then
    NUDGE_LEVEL=2
  fi

  # --- Update session score ---
  BREAK_COUNT=$(state '.break_count')
  FRUST_COUNT=$(state '.frustration_count')
  CURRENT_SCORE=$(calculate_score "$DURATION_MIN" "$T1" "$T2" "$T3" "$BREAK_COUNT" "$FRUST_COUNT")
  STATE=$(echo "$STATE" | jq --argjson s "$CURRENT_SCORE" '.session_score = $s')

  # --- Decide whether to fire nudge ---
  SHOULD_NUDGE=0
  if [ "$NUDGE_LEVEL" -gt 0 ]; then
    if [ "$NUDGE_LEVEL" -gt "$LAST_NUDGE_LEVEL" ]; then
      SHOULD_NUDGE=1
    elif [ "$IS_FRUSTRATED" -eq 1 ] && [ "$LAST_NUDGE_LEVEL" -lt 2 ]; then
      SHOULD_NUDGE=1
    elif [ "$LAST_NUDGE_TIME" -gt 0 ]; then
      COOLDOWN_SEC=$((COOLDOWN * 60))
      ELAPSED=$((NOW - LAST_NUDGE_TIME))
      [ "$ELAPSED" -ge "$COOLDOWN_SEC" ] && SHOULD_NUDGE=1
    else
      SHOULD_NUDGE=1
    fi
  fi

  # --- Format duration string ---
  DUR_H=$((DURATION_MIN / 60))
  DUR_M=$((DURATION_MIN % 60))
  if [ "$DUR_H" -gt 0 ]; then
    DUR_STR="${DUR_H}h$(printf '%02d' $DUR_M)m"
  else
    DUR_STR="${DUR_M}m"
  fi

  TIME_CTX=""
  if [ "$IS_OFF_HOURS" -eq 1 ]; then
    TIME_CTX="It's $(date '+%l:%M%p' | sed 's/^ //')"
  elif [ "$IS_WEEKEND" -eq 1 ]; then
    TIME_CTX="It's $(date '+%A')"
  fi

  # --- Fire or suppress ---
  if [ "$SHOULD_NUDGE" -eq 1 ] && [ "$NUDGE_SYSTEM_MSG" = "true" ]; then
    STATE=$(echo "$STATE" | jq --argjson nl "$NUDGE_LEVEL" --argjson nt "$NOW" '
      .last_nudge_level = $nl |
      .last_nudge_time = $nt
    ')
    write_state

    CONTEXT=$(get_nudge_context "$VELOCITY" "$IS_FRUSTRATED" "$IS_OFF_HOURS" "$IS_WEEKEND" "$OVERWORK_STREAK")
    MSG_BODY=$(select_message "$NUDGE_LEVEL" "$CONTEXT")

    # Build the full message
    MSG="[BREATH] Session: ${DUR_STR}. ${PROMPT_COUNT} prompts."
    [ "$VELOCITY" -ge "$VELOCITY_THRESHOLD" ] && MSG="${MSG} Velocity: ${VELOCITY}p/5m."
    [ -n "$TIME_CTX" ] && MSG="${MSG} ${TIME_CTX}."

    STREAK_THRESHOLD=$(cfg_num '.streak_alert_days' 3)
    [ "$OVERWORK_STREAK" -ge "$STREAK_THRESHOLD" ] && MSG="${MSG} Overwork streak: ${OVERWORK_STREAK} days."

    MSG="${MSG} ${MSG_BODY}"
    [ "$CURRENT_SCORE" -lt 50 ] && MSG="${MSG} (Score: ${CURRENT_SCORE}/100)"

    # Add creature personality to nudge
    if [ "$HAS_CREATURE" -eq 1 ]; then
      load_creature
      CREATURE_MSG=$(get_creature_message)
      [ -n "$CREATURE_MSG" ] && MSG="${MSG} ${CREATURE_MSG}"
    fi

    nudge "$MSG"
  else
    write_state
    suppress
  fi
fi
