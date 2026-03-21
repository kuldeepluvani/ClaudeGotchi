#!/bin/bash
# tests/test-status.sh — Test harness for breath-status.sh
# Enhanced: tests velocity indicators, streak badges, score display
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${PLUGIN_DIR}/scripts/breath-status.sh"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  local clean=$(printf "%s" "$haystack" | perl -pe 's/\e\[[0-9;]*m//g')
  if echo "$clean" | grep -q "$needle"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  expected to contain: $needle"
    echo "  actual (clean): $clean"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  local clean=$(printf "%s" "$haystack" | perl -pe 's/\e\[[0-9;]*m//g')
  if echo "$clean" | grep -q "$needle"; then
    echo "FAIL: $name"
    echo "  should not contain: $needle"
    echo "  actual (clean): $clean"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

# --- Test: fresh session ---
test_fresh_session() {
  local dir="${TEST_DIR}/test1"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson now "$now" '{
    session_start: $now, last_prompt: $now, prompt_count: 1,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [$now], peak_velocity: 0,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows fresh" "$output" "fresh"
}

# --- Test: normal session displays duration, prompts, and score ---
test_normal_session() {
  local dir="${TEST_DIR}/test2"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 5520))" --argjson lp "$now" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 27,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [], peak_velocity: 5,
    frustration_count: 0, session_score: 92,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows duration" "$output" "1h32m"
  assert_contains "shows prompt count" "$output" "27p"
  assert_contains "shows score" "$output" "92"
}

# --- Test: no state file outputs empty ---
test_no_state() {
  local dir="${TEST_DIR}/test3"
  mkdir -p "$dir"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  local clean=$(printf "%s" "$output" | tr -d '[:space:]')
  if [ -z "$clean" ]; then
    echo "PASS: empty on no state"
    PASS=$((PASS + 1))
  else
    echo "FAIL: empty on no state"
    echo "  expected empty, got: $clean"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test: frustration shows spiral indicator ---
test_frustration_indicator() {
  local dir="${TEST_DIR}/test_frust"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3600))" --argjson lp "$now" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 40,
    last_nudge_level: 1, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [], peak_velocity: 22,
    frustration_count: 2, session_score: 55,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows frustration spiral" "$output" "🌀"
  assert_contains "shows low score" "$output" "55"
}

# --- Test: overwork streak shows fire badge ---
test_overwork_streak() {
  local dir="${TEST_DIR}/test_streak"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 1800))" --argjson lp "$now" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 0,
    prompt_timestamps: [], peak_velocity: 3,
    frustration_count: 0, session_score: 95,
    overwork_streak: 5, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows overwork streak" "$output" "🔥5d"
}

# --- Test: healthy streak shows heart badge ---
test_healthy_streak() {
  local dir="${TEST_DIR}/test_healthy"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 1800))" --argjson lp "$now" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 10,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 1,
    prompt_timestamps: [], peak_velocity: 3,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 5, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows healthy streak" "$output" "💚5d"
}

# --- Test: break indicator shows coffee cup ---
test_break_indicator() {
  local dir="${TEST_DIR}/test_breaks"
  mkdir -p "$dir"
  local now=$(date +%s)
  jq -n --argjson ss "$((now - 3600))" --argjson lp "$now" '{
    session_start: $ss, last_prompt: $lp, prompt_count: 20,
    last_nudge_level: 0, last_nudge_time: 0, break_count: 2,
    prompt_timestamps: [], peak_velocity: 5,
    frustration_count: 0, session_score: 100,
    overwork_streak: 0, healthy_streak: 0, adaptive_multiplier: 1.0
  }' > "$dir/state.json"
  local output=$(BREATH_DIR="$dir" bash "$SRC")
  assert_contains "shows break count" "$output" "☕2"
}

# --- Run ---
test_fresh_session
test_normal_session
test_no_state
test_frustration_indicator
test_overwork_streak
test_healthy_streak
test_break_indicator

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
