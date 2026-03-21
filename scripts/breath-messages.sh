#!/bin/bash
# breath-messages.sh — Contextual message pool for Claude Breath
# Sourced by breath-hook.sh. Provides varied, actionable nudge messages.

get_nudge_message() {
  local level="$1"
  local context="${2:-normal}"
  local seed="${3:-0}"

  # Message pools organized by level and context
  # Each pool has multiple messages — seed selects which one

  local -a msgs=()

  case "${level}_${context}" in
    # --- Level 1: Gentle reminder ---
    1_normal)
      msgs=(
        "Consider a stretch or water break."
        "Good time to rest your eyes — look at something 20 feet away for 20 seconds."
        "Your body has been still a while. A quick stretch goes a long way."
        "Hydration check — when did you last drink water?"
        "Stand up, roll your shoulders, take three deep breaths."
      )
      ;;
    1_velocity)
      msgs=(
        "You're moving fast. Pause — is this the right approach?"
        "High prompt rate detected. Sometimes stepping back reveals the answer."
        "Rapid iteration often means the problem needs a different angle."
        "Fast fingers, but is the strategy right? Take a breath."
      )
      ;;
    1_offhours)
      msgs=(
        "Late night coding — is this worth losing sleep over?"
        "Your future self will thank you for stopping now."
        "The bug will still be there tomorrow. Your energy won't."
        "Off-hours work rarely produces your best thinking."
      )
      ;;
    1_weekend)
      msgs=(
        "It's the weekend. Is this truly urgent?"
        "Weekend work should be the exception, not the habit."
        "Your personal time matters. Can this wait until Monday?"
      )
      ;;
    1_streak)
      msgs=(
        "You've been pushing hard for multiple days. Your brain needs recovery."
        "Consecutive long sessions compound fatigue. Consider a shorter day."
        "Multi-day streaks reduce code quality. Protect your output by resting."
      )
      ;;
    1_frustration)
      msgs=(
        "You're in a rapid-fire loop. Step back and rethink the approach."
        "Frustration pattern detected. Take 5 — the answer often comes when you stop looking."
        "Rapid retries rarely solve the problem. What assumption might be wrong?"
        "You're iterating fast but not converging. A break might unstick you."
      )
      ;;

    # --- Level 2: Firm suggestion ---
    2_normal)
      msgs=(
        "Extended focus — take 5-10 minutes away from the screen."
        "Your concentration is past its peak. A real break will restore it."
        "Two hours of focused work is excellent. Now let your brain consolidate."
        "Step away for 10 minutes. The code will still be here."
      )
      ;;
    2_velocity)
      msgs=(
        "High intensity for too long. You're likely in diminishing returns."
        "Your prompt rate suggests you're grinding, not solving. Take 10."
        "Fast and long is a recipe for mistakes. Break now."
      )
      ;;
    2_offhours)
      msgs=(
        "It's late and you've been going a while. Seriously, stop."
        "Sleep deprivation causes more bugs than it fixes. Shut it down."
        "Nothing you ship at this hour will be your best work."
      )
      ;;
    2_weekend)
      msgs=(
        "Extended weekend session. You're burning recovery time you'll need Monday."
        "Weekends exist for a reason. Close the laptop."
      )
      ;;
    2_streak)
      msgs=(
        "Multiple days of overwork detected. This is unsustainable."
        "Your streak of long sessions is a warning sign. Take the rest seriously."
      )
      ;;
    2_frustration)
      msgs=(
        "Sustained frustration pattern. Walk away — literally. Move your body."
        "You've been hammering at this. The solution isn't more prompts, it's perspective."
        "Debugging spirals get worse with fatigue. Break now, solve faster later."
      )
      ;;

    # --- Level 3: Strong recommendation ---
    3_normal)
      msgs=(
        "Strongly recommend a real break. You've earned it."
        "Marathon session. Your cognitive resources are depleted — rest."
        "3+ hours of focus is heroic but unsustainable. Stop now."
        "You've given this session everything. Come back fresh."
      )
      ;;
    3_velocity)
      msgs=(
        "Extreme session — high intensity, long duration. Stop."
        "Your brain is running on fumes and caffeine. This needs to end."
      )
      ;;
    3_offhours)
      msgs=(
        "It's very late and you've been at this for hours. Go to bed."
        "This is past the point of productivity. Sleep is the best debugger."
      )
      ;;
    3_weekend)
      msgs=(
        "A full weekend session at this intensity is a red flag. Please stop."
        "You're deep into weekend work. Whatever this is, it can wait."
      )
      ;;
    3_streak)
      msgs=(
        "Multi-day overwork streak at critical level. You need a full day off."
        "Your streak data shows a pattern that leads to burnout. Take tomorrow off."
      )
      ;;
    3_frustration)
      msgs=(
        "Severe frustration pattern for an extended period. Stop. Walk. Think."
        "You're deep in a debugging spiral. The answer isn't here right now. Leave."
      )
      ;;

    # --- Fallback ---
    *)
      msgs=("Take a break.")
      ;;
  esac

  # Deterministic selection using seed
  local count=${#msgs[@]}
  local idx=$(( seed % count ))
  echo "${msgs[$idx]}"
}
