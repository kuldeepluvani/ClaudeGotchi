#!/bin/bash
# breath-creature.sh — Tamagotchi Terminal creature engine for Claude Breath
# Manages creature lifecycle: hatching, evolution, HP, XP, coins, death, rebirth.
# Sourced by breath-hook.sh. All functions operate on CREATURE variable.
# Data persisted in creature.json.

# --- Species definitions ---
# Each lineage: egg, baby, teen, adult, legendary
SPECIES_DRAGON=("🥚" "🐛" "🦎" "🐲" "🐉")
SPECIES_BIRD=("🥚" "🐣" "🐥" "🦅" "🔱")
SPECIES_PLANT=("🥚" "🌱" "🌿" "🌳" "🌲")
SPECIES_DEEPSEA=("🥚" "🫧" "🐡" "🐙" "🌊")

SPECIES_NAMES=("dragon" "bird" "plant" "deepsea")
STAGE_NAMES=("egg" "baby" "teen" "adult" "legendary")
XP_THRESHOLDS=(0 50 300 1000 3000)

# Mood definitions: [min_hp] = "mood_name mood_emoji"
# HP 80-100: thriving, 60-79: content, 40-59: hungry, 20-39: sick, 1-19: critical, 0: dead

CREATURE_FILE="${BREATH_DIR}/creature.json"

DEFAULT_CREATURE='{
  "name": null,
  "species": null,
  "stage": 0,
  "hp": 50,
  "xp": 0,
  "coins": 0,
  "born": null,
  "mood": "content",
  "shield_active": false,
  "ghost_sessions_remaining": 0,
  "near_deaths": 0,
  "lifetime_creatures": 0,
  "hall_of_legends": []
}'

# --- Load/Save ---
load_creature() {
  if [ ! -f "$CREATURE_FILE" ] || ! jq empty "$CREATURE_FILE" 2>/dev/null; then
    CREATURE="$DEFAULT_CREATURE"
    local today
    today=$(date "+%Y-%m-%d" 2>/dev/null)
    CREATURE=$(echo "$CREATURE" | jq --arg d "$today" '.born = $d')
  else
    CREATURE=$(cat "$CREATURE_FILE")
    # Migrate missing fields
    CREATURE=$(echo "$CREATURE" | jq '
      .shield_active //= false |
      .ghost_sessions_remaining //= 0 |
      .near_deaths //= 0 |
      .lifetime_creatures //= 0 |
      .hall_of_legends //= []
    ')
  fi
}

save_creature() {
  echo "$CREATURE" | jq '.' > "${CREATURE_FILE}.tmp"
  mv "${CREATURE_FILE}.tmp" "$CREATURE_FILE"
}

creature_val() {
  echo "$CREATURE" | jq -r "$1 // empty" 2>/dev/null
}

creature_num() {
  echo "$CREATURE" | jq -r "$1 // 0" 2>/dev/null
}

# --- Species & Stage ---
get_creature_emoji() {
  local species="$1" stage="$2"
  case "$species" in
    dragon)  echo "${SPECIES_DRAGON[$stage]}" ;;
    bird)    echo "${SPECIES_BIRD[$stage]}" ;;
    plant)   echo "${SPECIES_PLANT[$stage]}" ;;
    deepsea) echo "${SPECIES_DEEPSEA[$stage]}" ;;
    *)       echo "🥚" ;;
  esac
}

get_mood_emoji() {
  local hp="$1"
  if [ "$hp" -le 0 ]; then
    echo "👻"
  elif [ "$hp" -le 19 ]; then
    echo "😵"
  elif [ "$hp" -le 39 ]; then
    echo "🤒"
  elif [ "$hp" -le 59 ]; then
    echo "😟"
  elif [ "$hp" -le 79 ]; then
    echo "😌"
  else
    echo "😊"
  fi
}

get_mood_name() {
  local hp="$1"
  if [ "$hp" -le 0 ]; then
    echo "dead"
  elif [ "$hp" -le 19 ]; then
    echo "critical"
  elif [ "$hp" -le 39 ]; then
    echo "sick"
  elif [ "$hp" -le 59 ]; then
    echo "hungry"
  elif [ "$hp" -le 79 ]; then
    echo "content"
  else
    echo "thriving"
  fi
}

# --- Random species ---
roll_species() {
  local seed="${1:-$(date +%s)}"
  local idx=$(( seed % 4 ))
  echo "${SPECIES_NAMES[$idx]}"
}

# --- Evolution check ---
check_evolution() {
  local xp=$(creature_num '.xp')
  local current_stage=$(creature_num '.stage')
  local species=$(creature_val '.species')

  [ -z "$species" ] || [ "$species" = "null" ] && return 1

  local new_stage="$current_stage"
  for i in 4 3 2 1; do
    if [ "$xp" -ge "${XP_THRESHOLDS[$i]}" ]; then
      new_stage="$i"
      break
    fi
  done

  if [ "$new_stage" -gt "$current_stage" ]; then
    CREATURE=$(echo "$CREATURE" | jq --argjson s "$new_stage" '.stage = $s')
    # Evolution milestone bonus
    CREATURE=$(echo "$CREATURE" | jq '.coins = (.coins + 50)')
    echo "$new_stage"
    return 0
  fi
  return 1
}

# --- Hatch ---
hatch_creature() {
  local seed="${1:-$(date +%s)}"
  local species=$(roll_species "$seed")
  local today
  today=$(date "+%Y-%m-%d" 2>/dev/null)

  CREATURE=$(echo "$CREATURE" | jq --arg sp "$species" --arg d "$today" '
    .species = $sp |
    .stage = 1 |
    .born = $d |
    .lifetime_creatures = (.lifetime_creatures + 1)
  ')
}

# --- HP management ---
adjust_hp() {
  local delta="$1"
  local shield=$(creature_val '.shield_active')

  # Shield absorbs negative HP
  if [ "$delta" -lt 0 ] && [ "$shield" = "true" ]; then
    CREATURE=$(echo "$CREATURE" | jq '.shield_active = false')
    return 0
  fi

  CREATURE=$(echo "$CREATURE" | jq --argjson d "$delta" '
    .hp = ((.hp + $d) | if . > 100 then 100 elif . < 0 then 0 else . end)
  ')

  local hp=$(creature_num '.hp')
  local mood=$(get_mood_name "$hp")
  CREATURE=$(echo "$CREATURE" | jq --arg m "$mood" '.mood = $m')

  # Near-death detection
  if [ "$hp" -ge 1 ] && [ "$hp" -le 5 ]; then
    return 2  # Signal near-death state
  fi

  # Death detection
  if [ "$hp" -le 0 ]; then
    return 1  # Signal death
  fi

  return 0
}

# --- Death & Ghost ---
kill_creature() {
  local hp=$(creature_num '.hp')
  local species=$(creature_val '.species')
  local stage=$(creature_num '.stage')
  local xp=$(creature_num '.xp')
  local name=$(creature_val '.name')
  local born=$(creature_val '.born')
  local near_deaths=$(creature_num '.near_deaths')
  local today
  today=$(date "+%Y-%m-%d" 2>/dev/null)

  [ "$name" = "null" ] || [ -z "$name" ] && name="Unnamed"

  local emoji=$(get_creature_emoji "$species" "$stage")
  local stage_name="${STAGE_NAMES[$stage]}"

  # Calculate days lived
  local days_lived="?"
  if [ -n "$born" ] && [ "$born" != "null" ]; then
    local born_epoch
    born_epoch=$(date -j -f "%Y-%m-%d" "$born" "+%s" 2>/dev/null || date -d "$born" "+%s" 2>/dev/null || echo 0)
    local now_epoch=$(date +%s)
    if [ "$born_epoch" -gt 0 ]; then
      days_lived=$(( (now_epoch - born_epoch) / 86400 ))
    fi
  fi

  # Add to hall of legends
  CREATURE=$(echo "$CREATURE" | jq --arg emoji "$emoji" --arg name "$name" --arg species "$species" \
    --arg stage "$stage_name" --argjson xp "$xp" --argjson nd "$near_deaths" \
    --arg born "$born" --arg died "$today" --argjson days "$days_lived" '
    .hall_of_legends += [{
      emoji: $emoji,
      name: $name,
      species: $species,
      stage: $stage,
      xp: $xp,
      near_deaths: $nd,
      born: $born,
      died: $died,
      days_lived: $days
    }]
  ')

  # Enter ghost mode
  CREATURE=$(echo "$CREATURE" | jq '
    .hp = 0 |
    .ghost_sessions_remaining = 3 |
    .mood = "dead"
  ')
}

# --- Ghost phase progression ---
ghost_progress() {
  local remaining=$(creature_num '.ghost_sessions_remaining')
  if [ "$remaining" -le 1 ]; then
    # Ghost passes on — rebirth
    rebirth_creature
    return 0
  else
    CREATURE=$(echo "$CREATURE" | jq '.ghost_sessions_remaining = (.ghost_sessions_remaining - 1)')
    return 1
  fi
}

# --- Rebirth ---
rebirth_creature() {
  local coins=$(creature_num '.coins')
  local hall=$(echo "$CREATURE" | jq '.hall_of_legends')
  local lifetime=$(creature_num '.lifetime_creatures')
  local seed=$(date +%s)
  local today
  today=$(date "+%Y-%m-%d" 2>/dev/null)

  CREATURE="$DEFAULT_CREATURE"
  CREATURE=$(echo "$CREATURE" | jq --argjson c "$coins" --argjson lc "$lifetime" \
    --argjson hall "$hall" --arg d "$today" '
    .coins = $c |
    .lifetime_creatures = $lc |
    .hall_of_legends = $hall |
    .born = $d
  ')
}

# --- Near-death save ---
near_death_save() {
  CREATURE=$(echo "$CREATURE" | jq '
    .near_deaths = (.near_deaths + 1) |
    .hp = ((.hp + 20) | if . > 100 then 100 else . end)
  ')
  local mood=$(get_mood_name "$(creature_num '.hp')")
  CREATURE=$(echo "$CREATURE" | jq --arg m "$mood" '.mood = $m')
}

# --- Coin management ---
earn_coins() {
  local amount="$1"
  CREATURE=$(echo "$CREATURE" | jq --argjson a "$amount" '.coins = (.coins + $a)')
}

# --- XP management ---
earn_xp() {
  local amount="$1"
  CREATURE=$(echo "$CREATURE" | jq --argjson a "$amount" '.xp = (.xp + $a)')
}

# --- Shop actions ---
shop_feed() {
  local coins=$(creature_num '.coins')
  [ "$coins" -lt 15 ] && echo "not_enough_coins" && return 1
  CREATURE=$(echo "$CREATURE" | jq '.coins = (.coins - 15)')
  adjust_hp 20
  echo "fed"
  return 0
}

shop_shield() {
  local coins=$(creature_num '.coins')
  [ "$coins" -lt 30 ] && echo "not_enough_coins" && return 1
  CREATURE=$(echo "$CREATURE" | jq '.coins = (.coins - 30) | .shield_active = true')
  echo "shielded"
  return 0
}

shop_revive() {
  local coins=$(creature_num '.coins')
  local ghost=$(creature_num '.ghost_sessions_remaining')
  [ "$coins" -lt 50 ] && echo "not_enough_coins" && return 1
  [ "$ghost" -le 0 ] && echo "not_dead" && return 1
  CREATURE=$(echo "$CREATURE" | jq '
    .coins = (.coins - 50) |
    .ghost_sessions_remaining = 0 |
    .hp = 30 |
    .mood = "sick"
  ')
  # Re-hatch with same species but reset stage/xp
  local species=$(creature_val '.species')
  if [ -z "$species" ] || [ "$species" = "null" ]; then
    hatch_creature
  fi
  echo "revived"
  return 0
}

shop_name() {
  local new_name="$1"
  local coins=$(creature_num '.coins')
  [ "$coins" -lt 10 ] && echo "not_enough_coins" && return 1
  CREATURE=$(echo "$CREATURE" | jq --arg n "$new_name" '.coins = (.coins - 10) | .name = $n')
  echo "named"
  return 0
}

# --- Session end processing ---
# Called when a session ends or a new session begins.
# Takes session_score, break_count, frustration_count, overwork_streak, healthy_streak
process_session_end() {
  local score="$1" breaks="$2" frust="$3" ow_streak="$4" h_streak="$5"
  local ghost=$(creature_num '.ghost_sessions_remaining')
  local species=$(creature_val '.species')
  local stage=$(creature_num '.stage')
  local was_near_death=0
  local hp=$(creature_num '.hp')

  # Check if creature was in near-death before this session
  [ "$hp" -ge 1 ] && [ "$hp" -le 5 ] && was_near_death=1

  # --- Ghost mode handling ---
  if [ "$ghost" -gt 0 ]; then
    if [ "$score" -ge 80 ]; then
      ghost_progress || true
      # Earn reduced coins during ghost phase
      earn_coins 3
    fi
    save_creature
    return
  fi

  # --- Egg handling: hatch on first healthy session ---
  if [ -z "$species" ] || [ "$species" = "null" ] || [ "$stage" -eq 0 ]; then
    if [ "$score" -ge 80 ]; then
      hatch_creature "$(date +%s)"
      earn_coins 10
      earn_xp 15
    fi
    save_creature
    return
  fi

  # --- HP adjustments based on session score ---
  # adjust_hp returns non-zero for near-death/death signals; we handle death below
  if [ "$score" -ge 80 ]; then
    adjust_hp 15 || true
    earn_coins 10
    earn_xp 15
  elif [ "$score" -ge 60 ]; then
    adjust_hp 5 || true
    earn_coins 3
    earn_xp 5
  elif [ "$score" -ge 30 ]; then
    adjust_hp -10 || true
  else
    adjust_hp -25 || true
  fi

  # Break bonuses
  local i=0
  while [ "$i" -lt "$breaks" ] && [ "$i" -lt 3 ]; do
    adjust_hp 3 || true
    earn_coins 5
    earn_xp 3
    i=$((i + 1))
  done

  # Frustration penalties
  i=0
  while [ "$i" -lt "$frust" ]; do
    adjust_hp -5 || true
    i=$((i + 1))
  done

  # Zero-frustration bonus
  if [ "$frust" -eq 0 ] && [ "$score" -ge 60 ]; then
    earn_coins 5
    earn_xp 5
  fi

  # Streak effects
  if [ "$ow_streak" -ge 3 ]; then
    adjust_hp -10 || true
  fi
  if [ "$h_streak" -ge 3 ]; then
    adjust_hp 5 || true
    earn_coins 3
    earn_xp 10
  fi

  # --- Check near-death save ---
  hp=$(creature_num '.hp')
  if [ "$was_near_death" -eq 1 ] && [ "$hp" -gt 5 ]; then
    near_death_save
  fi

  # --- Check death ---
  hp=$(creature_num '.hp')
  if [ "$hp" -le 0 ]; then
    kill_creature
    save_creature
    return
  fi

  # --- Check evolution ---
  check_evolution || true

  save_creature
}

# --- Creature message for nudges ---
get_creature_message() {
  local species=$(creature_val '.species')
  local stage=$(creature_num '.stage')
  local hp=$(creature_num '.hp')
  local name=$(creature_val '.name')
  local ghost=$(creature_num '.ghost_sessions_remaining')

  [ -z "$species" ] || [ "$species" = "null" ] && echo "" && return
  [ "$name" = "null" ] || [ -z "$name" ] && name="Your creature"

  local emoji=$(get_creature_emoji "$species" "$stage")

  if [ "$ghost" -gt 0 ]; then
    echo "👻 ${name}'s ghost watches over you... (${ghost} healthy sessions to pass on)"
    return
  fi

  local mood=$(get_mood_name "$hp")
  case "$mood" in
    thriving)
      case $(( $(date +%s) % 4 )) in
        0) echo "${emoji} ${name} does a happy dance!" ;;
        1) echo "${emoji} ${name} is glowing with energy!" ;;
        2) echo "${emoji} ${name} purrs contentedly." ;;
        3) echo "${emoji} ${name} gives you a proud look." ;;
      esac
      ;;
    content)
      case $(( $(date +%s) % 3 )) in
        0) echo "${emoji} ${name} stretches alongside you." ;;
        1) echo "${emoji} ${name} nods approvingly." ;;
        2) echo "${emoji} ${name} is keeping pace with you." ;;
      esac
      ;;
    hungry)
      case $(( $(date +%s) % 3 )) in
        0) echo "${emoji} ${name} looks at you with worried eyes." ;;
        1) echo "${emoji} ${name} tugs at your sleeve." ;;
        2) echo "${emoji} ${name} whimpers softly." ;;
      esac
      ;;
    sick)
      case $(( $(date +%s) % 3 )) in
        0) echo "${emoji} ${name} is shivering. Please take a break." ;;
        1) echo "${emoji} ${name} can barely stand up." ;;
        2) echo "${emoji} ${name} coughs weakly." ;;
      esac
      ;;
    critical)
      case $(( $(date +%s) % 2 )) in
        0) echo "${emoji} ${name} can barely keep its eyes open..." ;;
        1) echo "${emoji} ${name} is fading. It needs you to stop." ;;
      esac
      ;;
  esac
}

# --- Compact status for statusline ---
get_creature_status() {
  local species=$(creature_val '.species')
  local stage=$(creature_num '.stage')
  local hp=$(creature_num '.hp')
  local coins=$(creature_num '.coins')
  local ghost=$(creature_num '.ghost_sessions_remaining')

  if [ -z "$species" ] || [ "$species" = "null" ]; then
    # Egg state
    echo "🥚"
    return
  fi

  if [ "$ghost" -gt 0 ]; then
    echo "👻${ghost}"
    return
  fi

  local emoji=$(get_creature_emoji "$species" "$stage")
  local mood_emoji=$(get_mood_emoji "$hp")
  echo "${emoji}${mood_emoji} ${hp}hp ${coins}💎"
}
