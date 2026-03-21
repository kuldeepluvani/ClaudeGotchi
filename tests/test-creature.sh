#!/bin/bash
# tests/test-creature.sh — Test harness for breath-creature.sh
# Covers: lifecycle, HP, XP, evolution, death, ghost, rebirth, shop, coins
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

assert_le() {
  local name="$1" val="$2" max="$3"
  if [ "$val" -le "$max" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (got $val, expected <= $max)"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================
# SECTION 1: Initialization
# =============================================
echo "--- Initialization ---"

test_default_creature() {
  local dir="${TEST_DIR}/test_default"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  assert_eq "default species is null" "" "$(creature_val '.species')"
  assert_eq "default stage is 0" "0" "$(creature_num '.stage')"
  assert_eq "default hp is 50" "50" "$(creature_num '.hp')"
  assert_eq "default xp is 0" "0" "$(creature_num '.xp')"
  assert_eq "default coins is 0" "0" "$(creature_num '.coins')"
}

test_save_load_roundtrip() {
  local dir="${TEST_DIR}/test_roundtrip"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  earn_coins 25
  earn_xp 100
  save_creature
  # Reload
  load_creature
  assert_eq "coins persisted" "25" "$(creature_num '.coins')"
  assert_eq "xp persisted" "100" "$(creature_num '.xp')"
}

# =============================================
# SECTION 2: Hatching
# =============================================
echo "--- Hatching ---"

test_hatch_assigns_species() {
  local dir="${TEST_DIR}/test_hatch"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "12345"
  local species=$(creature_val '.species')
  assert_eq "species assigned" "true" "$([ -n "$species" ] && [ "$species" != "null" ] && echo true || echo false)"
  assert_eq "stage is 1 (baby)" "1" "$(creature_num '.stage')"
  assert_eq "lifetime_creatures incremented" "1" "$(creature_num '.lifetime_creatures')"
}

test_hatch_species_from_seed() {
  local dir="${TEST_DIR}/test_hatch_seed"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  # Seed 0 % 4 = 0 = dragon
  local sp=$(roll_species "0")
  assert_eq "seed 0 = dragon" "dragon" "$sp"
  sp=$(roll_species "1")
  assert_eq "seed 1 = bird" "bird" "$sp"
  sp=$(roll_species "2")
  assert_eq "seed 2 = plant" "plant" "$sp"
  sp=$(roll_species "3")
  assert_eq "seed 3 = deepsea" "deepsea" "$sp"
}

# =============================================
# SECTION 3: Emoji System
# =============================================
echo "--- Emoji System ---"

test_creature_emojis() {
  local dir="${TEST_DIR}/test_emoji"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  assert_eq "dragon egg" "🥚" "$(get_creature_emoji dragon 0)"
  assert_eq "dragon baby" "🐛" "$(get_creature_emoji dragon 1)"
  assert_eq "dragon teen" "🦎" "$(get_creature_emoji dragon 2)"
  assert_eq "dragon adult" "🐲" "$(get_creature_emoji dragon 3)"
  assert_eq "dragon legendary" "🐉" "$(get_creature_emoji dragon 4)"
  assert_eq "bird baby" "🐣" "$(get_creature_emoji bird 1)"
  assert_eq "plant adult" "🌳" "$(get_creature_emoji plant 3)"
  assert_eq "deepsea legendary" "🌊" "$(get_creature_emoji deepsea 4)"
}

test_mood_emojis() {
  local dir="${TEST_DIR}/test_mood"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  assert_eq "thriving at 90" "😊" "$(get_mood_emoji 90)"
  assert_eq "content at 70" "😌" "$(get_mood_emoji 70)"
  assert_eq "hungry at 50" "😟" "$(get_mood_emoji 50)"
  assert_eq "sick at 30" "🤒" "$(get_mood_emoji 30)"
  assert_eq "critical at 10" "😵" "$(get_mood_emoji 10)"
  assert_eq "dead at 0" "👻" "$(get_mood_emoji 0)"
}

# =============================================
# SECTION 4: HP System
# =============================================
echo "--- HP System ---"

test_hp_adjust_positive() {
  local dir="${TEST_DIR}/test_hp_pos"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  adjust_hp 20
  assert_eq "hp increased to 70" "70" "$(creature_num '.hp')"
}

test_hp_capped_at_100() {
  local dir="${TEST_DIR}/test_hp_cap"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  adjust_hp 80
  assert_eq "hp capped at 100" "100" "$(creature_num '.hp')"
}

test_hp_floor_at_0() {
  local dir="${TEST_DIR}/test_hp_floor"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  adjust_hp -200 || true
  assert_eq "hp floored at 0" "0" "$(creature_num '.hp')"
}

test_hp_updates_mood() {
  local dir="${TEST_DIR}/test_hp_mood"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  adjust_hp 40 || true  # 50 + 40 = 90
  assert_eq "mood is thriving at 90hp" "thriving" "$(creature_val '.mood')"
  adjust_hp -60 || true  # 90 - 60 = 30
  assert_eq "mood is sick at 30hp" "sick" "$(creature_val '.mood')"
}

test_shield_absorbs_damage() {
  local dir="${TEST_DIR}/test_shield"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  CREATURE=$(echo "$CREATURE" | jq '.shield_active = true | .hp = 50')
  adjust_hp -25 || true
  assert_eq "hp unchanged with shield" "50" "$(creature_num '.hp')"
  # shield_active returns empty for false via creature_val (// empty)
  local shield_val=$(echo "$CREATURE" | jq -r '.shield_active')
  assert_eq "shield consumed" "false" "$shield_val"
}

# =============================================
# SECTION 5: Evolution
# =============================================
echo "--- Evolution ---"

test_evolution_at_xp_threshold() {
  local dir="${TEST_DIR}/test_evolve"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"  # dragon, stage 1
  earn_xp 300  # teen threshold
  check_evolution || true
  assert_eq "evolved to teen (stage 2)" "2" "$(creature_num '.stage')"
}

test_evolution_gives_coin_bonus() {
  local dir="${TEST_DIR}/test_evolve_coins"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  local coins_before=$(creature_num '.coins')
  earn_xp 300
  check_evolution || true
  local coins_after=$(creature_num '.coins')
  assert_eq "got 50 coin bonus" "50" "$(( coins_after - coins_before ))"
}

test_no_evolution_below_threshold() {
  local dir="${TEST_DIR}/test_no_evolve"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"  # stage 1
  earn_xp 49  # below 50 for teen
  check_evolution 2>/dev/null || true
  assert_eq "still baby (stage 1)" "1" "$(creature_num '.stage')"
}

# =============================================
# SECTION 6: Death & Ghost & Rebirth
# =============================================
echo "--- Death & Ghost & Rebirth ---"

test_death_creates_ghost() {
  local dir="${TEST_DIR}/test_death"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  CREATURE=$(echo "$CREATURE" | jq '.hp = 0')
  kill_creature
  assert_eq "ghost_sessions is 3" "3" "$(creature_num '.ghost_sessions_remaining')"
  assert_eq "mood is dead" "dead" "$(creature_val '.mood')"
  assert_eq "hall_of_legends has entry" "1" "$(echo "$CREATURE" | jq '.hall_of_legends | length')"
}

test_ghost_progress_decrements() {
  local dir="${TEST_DIR}/test_ghost_progress"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  CREATURE=$(echo "$CREATURE" | jq '.hp = 0 | .ghost_sessions_remaining = 3')
  ghost_progress || true  # 3 → 2
  assert_eq "ghost_sessions is 2" "2" "$(creature_num '.ghost_sessions_remaining')"
}

test_ghost_final_session_triggers_rebirth() {
  local dir="${TEST_DIR}/test_ghost_rebirth"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  earn_coins 30
  CREATURE=$(echo "$CREATURE" | jq '.hp = 0 | .ghost_sessions_remaining = 1')
  ghost_progress || true  # 1 → rebirth
  assert_eq "ghost cleared" "0" "$(creature_num '.ghost_sessions_remaining')"
  assert_eq "coins preserved" "30" "$(creature_num '.coins')"
  assert_eq "xp reset" "0" "$(creature_num '.xp')"
  assert_eq "hp reset to 50" "50" "$(creature_num '.hp')"
  assert_eq "species reset to null" "" "$(creature_val '.species')"
}

test_near_death_save() {
  local dir="${TEST_DIR}/test_near_death"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  CREATURE=$(echo "$CREATURE" | jq '.hp = 3')
  near_death_save
  assert_eq "hp got +20 bonus" "23" "$(creature_num '.hp')"
  assert_eq "near_deaths incremented" "1" "$(creature_num '.near_deaths')"
}

# =============================================
# SECTION 7: Shop
# =============================================
echo "--- Shop ---"

# Note: shop functions echo a result AND modify CREATURE.
# Using $() runs in a subshell, so we save/reload to test state changes.

test_shop_feed() {
  local dir="${TEST_DIR}/test_shop_feed"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  earn_coins 20
  CREATURE=$(echo "$CREATURE" | jq '.hp = 60')
  save_creature
  # Run in current shell to preserve CREATURE changes
  shop_feed > /tmp/shop_result.txt || true
  local result=$(cat /tmp/shop_result.txt)
  assert_eq "feed succeeded" "fed" "$result"
  assert_eq "hp is 80" "80" "$(creature_num '.hp')"
  assert_eq "coins deducted" "5" "$(creature_num '.coins')"
}

test_shop_feed_insufficient_coins() {
  local dir="${TEST_DIR}/test_shop_feed_broke"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  earn_coins 5
  shop_feed > /tmp/shop_result.txt || true
  local result=$(cat /tmp/shop_result.txt)
  assert_eq "feed rejected" "not_enough_coins" "$result"
}

test_shop_shield() {
  local dir="${TEST_DIR}/test_shop_shield"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  earn_coins 30
  shop_shield > /tmp/shop_result.txt || true
  local result=$(cat /tmp/shop_result.txt)
  assert_eq "shield activated" "shielded" "$result"
  assert_eq "shield_active is true" "true" "$(creature_val '.shield_active')"
  assert_eq "coins deducted" "0" "$(creature_num '.coins')"
}

test_shop_revive() {
  local dir="${TEST_DIR}/test_shop_revive"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  earn_coins 60
  CREATURE=$(echo "$CREATURE" | jq '.hp = 0 | .ghost_sessions_remaining = 3')
  shop_revive > /tmp/shop_result.txt || true
  local result=$(cat /tmp/shop_result.txt)
  assert_eq "revive succeeded" "revived" "$result"
  assert_eq "ghost cleared" "0" "$(creature_num '.ghost_sessions_remaining')"
  assert_eq "hp set to 30" "30" "$(creature_num '.hp')"
  assert_eq "coins deducted" "10" "$(creature_num '.coins')"
}

test_shop_name() {
  local dir="${TEST_DIR}/test_shop_name"
  mkdir -p "$dir"
  BREATH_DIR="$dir" source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  earn_coins 15
  shop_name "Drakon" > /tmp/shop_result.txt || true
  local result=$(cat /tmp/shop_result.txt)
  assert_eq "name succeeded" "named" "$result"
  assert_eq "name is Drakon" "Drakon" "$(creature_val '.name')"
  assert_eq "coins deducted" "5" "$(creature_num '.coins')"
}

# =============================================
# SECTION 8: Session Processing
# =============================================
echo "--- Session Processing ---"

test_session_healthy_rewards() {
  local dir="${TEST_DIR}/test_session_healthy"
  mkdir -p "$dir"
  BREATH_DIR="$dir"
  CREATURE_FILE="${dir}/creature.json"
  source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  save_creature
  local hp_before=$(creature_num '.hp')
  local xp_before=$(creature_num '.xp')
  local coins_before=$(creature_num '.coins')
  process_session_end 90 1 0 0 0
  load_creature
  assert_ge "hp increased" "$(creature_num '.hp')" "$((hp_before + 15))"
  assert_ge "xp increased" "$(creature_num '.xp')" "$((xp_before + 15))"
  assert_ge "coins increased" "$(creature_num '.coins')" "$((coins_before + 10))"
  unset BREATH_DIR CREATURE_FILE
}

test_session_terrible_damages() {
  local dir="${TEST_DIR}/test_session_terrible"
  mkdir -p "$dir"
  BREATH_DIR="$dir"
  CREATURE_FILE="${dir}/creature.json"
  source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  CREATURE=$(echo "$CREATURE" | jq '.hp = 80')
  save_creature
  process_session_end 20 0 2 0 0
  load_creature
  local hp=$(creature_num '.hp')
  assert_le "hp decreased significantly" "$hp" "50"
  unset BREATH_DIR CREATURE_FILE
}

test_session_egg_hatches_on_healthy() {
  local dir="${TEST_DIR}/test_session_hatch"
  mkdir -p "$dir"
  BREATH_DIR="$dir"
  CREATURE_FILE="${dir}/creature.json"
  source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  save_creature
  process_session_end 85 0 0 0 0
  load_creature
  local species=$(creature_val '.species')
  assert_eq "hatched" "true" "$([ -n "$species" ] && echo true || echo false)"
  assert_eq "stage is 1" "1" "$(creature_num '.stage')"
  unset BREATH_DIR CREATURE_FILE
}

test_session_ghost_progresses() {
  local dir="${TEST_DIR}/test_session_ghost"
  mkdir -p "$dir"
  BREATH_DIR="$dir"
  CREATURE_FILE="${dir}/creature.json"
  source "${PLUGIN_DIR}/scripts/breath-creature.sh"
  load_creature
  hatch_creature "0"
  CREATURE=$(echo "$CREATURE" | jq '.hp = 0 | .ghost_sessions_remaining = 2')
  save_creature
  process_session_end 85 0 0 0 0
  load_creature
  assert_eq "ghost progressed" "1" "$(creature_num '.ghost_sessions_remaining')"
  unset BREATH_DIR CREATURE_FILE
}

# =============================================
# RUN ALL
# =============================================
test_default_creature
test_save_load_roundtrip
test_hatch_assigns_species
test_hatch_species_from_seed
test_creature_emojis
test_mood_emojis
test_hp_adjust_positive
test_hp_capped_at_100
test_hp_floor_at_0
test_hp_updates_mood
test_shield_absorbs_damage
test_evolution_at_xp_threshold
test_evolution_gives_coin_bonus
test_no_evolution_below_threshold
test_death_creates_ghost
test_ghost_progress_decrements
test_ghost_final_session_triggers_rebirth
test_near_death_save
test_shop_feed
test_shop_feed_insufficient_coins
test_shop_shield
test_shop_revive
test_shop_name
test_session_healthy_rewards
test_session_terrible_damages
test_session_egg_hatches_on_healthy
test_session_ghost_progresses

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
