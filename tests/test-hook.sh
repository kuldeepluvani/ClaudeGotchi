#!/bin/bash
# tests/test-hook.sh — Comprehensive test harness for breath-hook.sh
# Covers: basic flow, velocity, frustration, adaptive, streaks, scoring, messages
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${PLUGIN_DIR}/scripts/breath-hook.sh"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local name="$1" json="$2" field="$3" expected="$4"
  actual=$(echo "$json" | jq -r "$field")
  assert_eq "$name" "$expected" "$actual"
}

assert_ge() {
  local name="$1" val="$2" min="$3"
  if [ "$val" -ge "$min" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (got $val, expected >= $min)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  expected to contain: $needle"
    echo "  actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================
# SECTION 1: Basic Flow
# =============================================
echo "--- Basic Flow ---"

# --- Test: config auto-creation ---
test_config_auto_creation() {
  local dir="${TEST_DIR}/test_config"
  mkdir -p "$dir"
  BREATH_DIR="$dir" bash "$SRC"
  assert_eq "config.json created" "true" "$([ -f "$dir/config.json" ] && echo true || echo false)"
  assert_json_field "default nudge_system_message" "$(cat "$dir/config.json")" '.nudge_system_message' "true"
  assert_json_field "default session_gap_min" "$(cat "$dir/config.json")" '.session_gap_min' "15"
  assert_json_field "default break_gap_min" "$(cat "$dir/config.json")" '.break_gap_min' "5"
  assert_json_field "has velocity_window_sec" "$(cat "$dir/config.json")" '.velocity_window_sec' "300"
  assert_json_field "has velocity_threshold" "$(cat "$dir/config.json")" '.velocity_threshold' "15"
  assert_json_field "has frustration_threshold" "$(cat "$dir/config.json")" '.frustration_threshold' "20"
  assert_json_field "has adaptive_thresholds" "$(cat "$dir/config.json")" '.adaptive_thresholds' "true"
}

# --- Test: config invalid JSON fallback ---
test_config_invalid_json_fallback() {
  local dir="${TEST_DIR}/test_config_fallback"
  mkdir -p "$dir"
  echo "NOT JSON" > "$dir/config.json"
  BREATH_DIR="$dir" bash "$SRC"
  assert_json_field "fallback nudge_system_message" "$(cat "$dir/config.json")" '.nudge_system_message' "true"
}

# --- Test: state.json created on first run ---
test_state_creation() {
  local dir="${TEST_DIR}/test_state"
  mkdir -p "$dir"
  BREATH_DIR="$dir" bash "$SRC"
  assert_eq "state.json created" "true" "$([ -f "$dir/state.json" ] && echo true || echo false)"
  assert_json_field "prompt_count is 1" "$(cat "$dir/state.json")" '.prompt_count' "1"
  assert_json_field "has prompt_timestamps" "$(cat "$dir/state.json")" '.prompt_timestamps | length' "1"
  assert_json_field "session_score is 100" "$(cat "$dir/state.json")" '.session_score' "100"
  assert_json_field "frustration_count is 0" "$(cat "$dir/state.json")" '.frustration_count' "0"
}

# --- Test: prompt count increments ---
test_prompt_count_increment() {
  local dir="${TEST_DIR}/test_increment"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 60))" --argjson lp "$((now - 10))" --argjson now_ts "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 5,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [$now_ts], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" bash "$SRC"
  assert_json_field "prompt_count incremented to 6" "$(cat "$dir/state.json")" '.prompt_count' "6"
}

# --- Test: break detection — full self-heal ---
test_break_detection() {
  local dir="${TEST_DIR}/test_break"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3600))" --argjson lp "$((now - 480))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 20,
    last_nudge_level: 2, last_nudge_time: '"$((now - 600))"', break_count: 0,
    prompt_timestamps: ['"$((now - 600))"', '"$((now - 500))"'], peak_velocity: 8,
    frustration_count: 1, session_score: 60,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" bash "$SRC"
  assert_json_field "break_count is 1" "$(cat "$dir/state.json")" '.break_count' "1"
  assert_json_field "nudge_level reset to 0" "$(cat "$dir/state.json")" '.last_nudge_level' "0"
  assert_json_field "prompt_count reset to 1" "$(cat "$dir/state.json")" '.prompt_count' "1"
  assert_json_field "session_start reset" "$(cat "$dir/state.json")" '.session_start' "$now"
  assert_json_field "frustration_count reset" "$(cat "$dir/state.json")" '.frustration_count' "0"
  assert_json_field "peak_velocity reset" "$(cat "$dir/state.json")" '.peak_velocity' "0"
}

# --- Test: new session detection (>=15 min gap) ---
test_new_session() {
  local dir="${TEST_DIR}/test_new_session"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 7200))" --argjson lp "$((now - 1200))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 30,
    last_nudge_level: 1, last_nudge_time: 0, break_count: 2,
    prompt_timestamps: [], peak_velocity: 5,
    frustration_count: 0, session_score: 80,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  touch "$dir/history.jsonl"
  BREATH_DIR="$dir" bash "$SRC"
  assert_json_field "prompt_count reset to 1" "$(cat "$dir/state.json")" '.prompt_count' "1"
  assert_json_field "break_count reset to 0" "$(cat "$dir/state.json")" '.break_count' "0"
  assert_json_field "session_score reset to 100" "$(cat "$dir/state.json")" '.session_score' "100"
  assert_json_field "frustration_count reset" "$(cat "$dir/state.json")" '.frustration_count' "0"
  assert_eq "history entry logged" "true" "$([ -s "$dir/history.jsonl" ] && echo true || echo false)"
}

# =============================================
# SECTION 2: Nudge Behavior
# =============================================
echo "--- Nudge Behavior ---"

# --- Test: no nudge when under threshold ---
test_no_nudge_under_threshold() {
  local dir="${TEST_DIR}/test_no_nudge"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 1800))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 5,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "suppressOutput is true" "$output" '.suppressOutput' "true"
}

# --- Test: level 1 nudge fires at 90+ min ---
test_nudge_level1() {
  local dir="${TEST_DIR}/test_nudge_l1"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 5700))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 15,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "suppressOutput is false" "$output" '.suppressOutput' "false"
  assert_contains "contains BREATH" "$(echo "$output" | jq -r '.systemMessage')" "BREATH"
}

# --- Test: nudge cooldown suppresses re-fire ---
test_nudge_cooldown() {
  local dir="${TEST_DIR}/test_cooldown"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 5700))" --argjson lp "$((now - 10))" --argjson nt "$((now - 300))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 15,
    last_nudge_level: 1, last_nudge_time: $nt, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 90,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "suppressed by cooldown" "$output" '.suppressOutput' "true"
}

# --- Test: higher level fires despite cooldown ---
test_nudge_escalation_through_cooldown() {
  local dir="${TEST_DIR}/test_escalation"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 7500))" --argjson lp "$((now - 10))" --argjson nt "$((now - 300))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 20,
    last_nudge_level: 1, last_nudge_time: $nt, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 80,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "level 2 fires" "$output" '.suppressOutput' "false"
}

# --- Test: density boost ---
test_density_boost() {
  local dir="${TEST_DIR}/test_density"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3000))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 45,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "density boost fires nudge" "$output" '.suppressOutput' "false"
}

# --- Test: silent mode ---
test_silent_mode() {
  local dir="${TEST_DIR}/test_silent"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n '{
    nudge_system_message: false,
    nudge_thresholds_min: [90, 120, 180],
    prompt_density_threshold: 40,
    off_hours_multiplier: 0.67, off_hours_start: 23, off_hours_end: 7,
    weekend_multiplier: 0.75, break_gap_min: 5, session_gap_min: 15,
    nudge_cooldown_min: 15, explicit_acknowledgment: false,
    escalation_timeout_min: 20, vault_summaries: false,
    vault_summary_path: "", history_retention_days: 14,
    velocity_window_sec: 300, velocity_threshold: 15,
    frustration_threshold: 20, streak_alert_days: 3,
    adaptive_thresholds: false, message_variety: false
  }' > "$dir/config.json"
  jq -n --argjson ss "$((now - 5700))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 15,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "silent mode suppresses" "$output" '.suppressOutput' "true"
}

# =============================================
# SECTION 3: Time Context
# =============================================
echo "--- Time Context ---"

# --- Test: off-hours reduces threshold ---
test_off_hours_threshold() {
  local dir="${TEST_DIR}/test_offhours"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3900))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=1 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "off-hours nudge fires" "$output" '.suppressOutput' "false"
}

# --- Test: weekend reduces threshold ---
test_weekend_threshold() {
  local dir="${TEST_DIR}/test_weekend"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 4200))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=6 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "weekend nudge fires" "$output" '.suppressOutput' "false"
}

# --- Test: off-hours + weekend uses min() ---
test_offhours_weekend_min() {
  local dir="${TEST_DIR}/test_offhours_weekend"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3720))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=2 BREATH_DAY=7 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "min() rule fires nudge" "$output" '.suppressOutput' "false"
}

# --- Test: normal hours no threshold reduction ---
test_normal_hours_no_reduction() {
  local dir="${TEST_DIR}/test_normal_hours"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3900))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "normal hours no nudge" "$output" '.suppressOutput' "true"
}

# =============================================
# SECTION 4: Velocity & Frustration
# =============================================
echo "--- Velocity & Frustration ---"

# --- Test: velocity tracking stores timestamps ---
test_velocity_timestamps() {
  local dir="${TEST_DIR}/test_velocity_ts"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 300))" --argjson lp "$((now - 5))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 3,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 60))"', '"$((now - 30))"', '"$((now - 5))"'],
    peak_velocity: 3, frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" BREATH_NOW="$now" BREATH_HOUR=10 BREATH_DAY=3 bash "$SRC"
  local ts_count=$(jq '.prompt_timestamps | length' "$dir/state.json")
  assert_ge "timestamps stored" "$ts_count" "3"
}

# --- Test: high velocity boosts nudge level ---
test_velocity_boost() {
  local dir="${TEST_DIR}/test_velocity_boost"
  mkdir -p "$dir"
  local now=$(date +%s)
  # 16 prompts in last 5 min = high velocity (threshold=15)
  # Session at 80 min (under 90 min T1), so without velocity boost = no nudge
  local timestamps=""
  for i in $(seq 1 16); do
    [ -n "$timestamps" ] && timestamps="${timestamps},"
    timestamps="${timestamps}$((now - (300 - i * 15)))"
  done
  jq -n --argjson ss "$((now - 4800))" --argjson lp "$((now - 3))" "{
    session_start: \$ss, last_prompt: \$lp, prompt_count: 16,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [${timestamps}],
    peak_velocity: 0, frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }" > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "velocity boost fires nudge" "$output" '.suppressOutput' "false"
}

# --- Test: frustration detection ---
test_frustration_detection() {
  local dir="${TEST_DIR}/test_frustration"
  mkdir -p "$dir"
  local now=$(date +%s)
  # 22 prompts in last 5 min = frustration (threshold=20)
  local timestamps=""
  for i in $(seq 1 22); do
    [ -n "$timestamps" ] && timestamps="${timestamps},"
    timestamps="${timestamps}$((now - (300 - i * 12)))"
  done
  jq -n --argjson ss "$((now - 600))" --argjson lp "$((now - 3))" "{
    session_start: \$ss, last_prompt: \$lp, prompt_count: 22,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [${timestamps}],
    peak_velocity: 0, frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }" > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC")
  assert_json_field "frustration fires nudge" "$output" '.suppressOutput' "false"
  assert_json_field "frustration_count incremented" "$(cat "$dir/state.json")" '.frustration_count' "1"
  local peak=$(jq '.peak_velocity' "$dir/state.json")
  assert_ge "peak_velocity tracked" "$peak" "20"
}

# =============================================
# SECTION 5: Session Scoring
# =============================================
echo "--- Session Scoring ---"

# --- Test: score starts at 100 for fresh session ---
test_score_fresh() {
  local dir="${TEST_DIR}/test_score_fresh"
  mkdir -p "$dir"
  BREATH_DIR="$dir" bash "$SRC"
  assert_json_field "initial score is 100" "$(cat "$dir/state.json")" '.session_score' "100"
}

# --- Test: score decays past T1 ---
test_score_decay() {
  local dir="${TEST_DIR}/test_score_decay"
  mkdir -p "$dir"
  local now=$(date +%s)
  # 100 min session (10 min past T1=90)
  jq -n --argjson ss "$((now - 6000))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 15,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: ['"$((now - 10))"'], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" BREATH_HOUR=10 BREATH_DAY=3 BREATH_NOW="$now" bash "$SRC" > /dev/null
  local score=$(jq '.session_score' "$dir/state.json")
  # score should be < 100 (100 - 10*1 + 5 no-frust bonus = 95)
  if [ "$score" -lt 100 ]; then
    echo "PASS: score decayed to $score"
    PASS=$((PASS + 1))
  else
    echo "FAIL: score should have decayed (got $score)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test: break gives score bonus ---
test_score_break_bonus() {
  local dir="${TEST_DIR}/test_score_break"
  mkdir -p "$dir"
  local now=$(date +%s)
  # After a break, score should include break bonus
  jq -n --argjson ss "$((now - 3600))" --argjson lp "$((now - 480))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 20,
    last_nudge_level: 1, last_nudge_time: 0, break_count: 1,
    prompt_timestamps: [], peak_velocity: 0,
    frustration_count: 0, session_score: 60,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" BREATH_NOW="$now" bash "$SRC"
  local score=$(jq '.session_score' "$dir/state.json")
  # After break heal: duration=0, break_count=2, frust=0 → 100 + 20 + 5 = 125 → capped at 100
  assert_eq "break heals score" "100" "$score"
}

# =============================================
# SECTION 6: State Migration
# =============================================
echo "--- State Migration ---"

# --- Test: old state without new fields gets migrated ---
test_state_migration() {
  local dir="${TEST_DIR}/test_migration"
  mkdir -p "$dir"
  local now=$(date +%s)
  # Old-format state (no velocity/score fields)
  jq -n --argjson ss "$((now - 60))" --argjson lp "$((now - 10))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 5,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0
  }' > "$dir/state.json"
  BREATH_DIR="$dir" BREATH_NOW="$now" BREATH_HOUR=10 BREATH_DAY=3 bash "$SRC"
  assert_json_field "migrated prompt_timestamps" "$(cat "$dir/state.json")" '.prompt_timestamps | type' "array"
  assert_json_field "migrated peak_velocity" "$(cat "$dir/state.json")" '.peak_velocity | type' "number"
  assert_json_field "migrated session_score" "$(cat "$dir/state.json")" '.session_score | type' "number"
  assert_json_field "migrated frustration_count" "$(cat "$dir/state.json")" '.frustration_count | type' "number"
}

# =============================================
# SECTION 7: History Logging
# =============================================
echo "--- History Logging ---"

# --- Test: history includes new fields ---
test_history_new_fields() {
  local dir="${TEST_DIR}/test_history_fields"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 7200))" --argjson lp "$((now - 1200))" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 30,
    last_nudge_level: 2, last_nudge_time: 0, break_count: 1,
    prompt_timestamps: [], peak_velocity: 12,
    frustration_count: 2, session_score: 55,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  touch "$dir/history.jsonl"
  BREATH_DIR="$dir" BREATH_NOW="$now" bash "$SRC"
  local entry=$(cat "$dir/history.jsonl")
  assert_contains "history has peak_velocity" "$entry" "peak_velocity"
  assert_contains "history has frustration_events" "$entry" "frustration_events"
  assert_contains "history has score" "$entry" "score"
}

# =============================================
# RUN ALL
# =============================================
test_config_auto_creation
test_config_invalid_json_fallback
test_state_creation
test_prompt_count_increment
test_break_detection
test_new_session
test_no_nudge_under_threshold
test_nudge_level1
test_nudge_cooldown
test_nudge_escalation_through_cooldown
test_density_boost
test_silent_mode
test_off_hours_threshold
test_weekend_threshold
test_offhours_weekend_min
test_normal_hours_no_reduction
test_velocity_timestamps
test_velocity_boost
test_frustration_detection
test_score_fresh
test_score_decay
test_score_break_bonus
test_state_migration
test_history_new_fields

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
