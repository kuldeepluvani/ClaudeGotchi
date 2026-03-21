# Claude Breath

A **smart wellness plugin** for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with a virtual creature that thrives when you code healthy and dies when you don't.

**Near-zero token cost.** All intelligence runs in bash — Claude only hears about it when you actually need to stop.

## Your Creature

A Tamagotchi-style companion lives in your statusline. Take breaks, it thrives. Overwork, it dies.

```
[1h32m | 27p ☕1 | ☀️ 92 | Luna 🐸😊 85hp 45💎]     ← Happy frog
[2h30m | 58p ⚡22 | 🌀 45 | 🐛😵 8hp 12💎]           ← Creature dying
[0h10m | 3p | ☀️ 100 | 👻2]                           ← Ghost phase
[0h05m | 2p | ☀️ 100 | 🥚 0💎]                        ← New egg after rebirth
```

### Evolution (permanent, earned through XP)

| Stage | Dragon | Bird | Plant | Deep Sea | XP |
|:---|:---|:---|:---|:---|:---|
| Egg | 🥚 | 🥚 | 🥚 | 🥚 | 0 |
| Baby | 🐛 | 🐣 | 🌱 | 🫧 | 50 |
| Teen | 🦎 | 🐥 | 🌿 | 🐡 | 300 |
| Adult | 🐲 | 🦅 | 🌳 | 🐙 | 1000 |
| Legendary | 🐉 | 🔱 | 🌲 | 🌊 | 3000 |

Species is randomly assigned at hatch. XP is never lost — only death resets it.

### Moods (based on HP)

| HP | Mood | Your creature... |
|:---|:---|:---|
| 80-100 | 😊 Thriving | does happy dances, glows with energy |
| 60-79 | 😌 Content | nods approvingly, keeps pace |
| 40-59 | 😟 Hungry | tugs at your sleeve, whimpers |
| 20-39 | 🤒 Sick | shivers, can barely stand |
| 1-19 | 😵 Critical | fading, begging you to stop |
| 0 | 👻 Dead | haunts your statusline |

### Death & Rebirth

When HP hits 0, your creature becomes a ghost (👻). You must complete **3 consecutive healthy sessions** (score ≥ 80) for it to pass on. It's logged to the **Hall of Legends** with its full life story. Then a new egg appears — coins carry over, XP resets, new species.

**Near-death saves:** If your creature is at 1-5 HP and your next session is healthy, it gets a +20 HP "second wind" and the save is recorded as a badge of honor.

### Breath Coins (💎)

Earn coins through healthy behavior, spend them in the shop:

**Earning:**
| Action | Coins |
|:---|:---|
| Healthy session (score ≥ 80) | +10 |
| Break taken | +5 |
| Zero frustration | +5 |
| Streak day | +3 |
| Evolution milestone | +50 |

**Shop:**
| Item | Cost | Effect |
|:---|:---|:---|
| Feed | 15💎 | +20 HP |
| Shield | 30💎 | Blocks 1 bad session |
| Revive | 50💎 | Skip ghost phase |
| Name | 10💎 | Name your creature |

## What makes it smart

| Intelligence | What it does |
|:---|:---|
| **Velocity tracking** | Monitors prompts-per-5-minute rate — detects grinding vs. thinking |
| **Frustration detection** | Rapid-fire loops trigger early intervention before you spiral |
| **Adaptive thresholds** | Learns from your history — adjusts timing to your natural rhythm |
| **Streak awareness** | Tracks consecutive overwork days and healthy streaks |
| **Session scoring** | 0-100 wellness score per session, logged for trend analysis |
| **Self-healing breaks** | Real breaks fully reset the session — timer, density, score |
| **Message variety** | 60+ contextual messages — never the same nudge twice |
| **Time awareness** | Nudges earlier during off-hours and weekends |
| **Creature system** | Tamagotchi companion with evolution, death, coins, and shop |

## What it costs

| Prompt type | Token cost |
|:---|:---|
| Normal prompt (99% of the time) | **0 tokens** |
| Nudge fires | ~50-100 tokens |

The hook runs pure bash + `jq`. Claude never sees it unless you need a break.

## Install

**Requirements:** `bash 3.2+`, `jq`

### As a Claude Code plugin (recommended)

```bash
claude --plugin-dir /path/to/claude-breath
```

### Manual install

```bash
git clone https://github.com/kuldeep-luvani/claude-breath.git ~/.claude-breath
```

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-breath/scripts/breath-hook.sh"
          }
        ]
      }
    ]
  }
}
```

## Statusline

The enhanced statusline shows real-time intelligence:

```
[0h00m | fresh]                          ← New session
[1h32m | 27p ☕1 | ☀️ 92]               ← Healthy, took a break
[2h05m | 41p ⚡18 | 🟡 75]              ← High velocity warning
[2h30m | 58p ⚡22 | 🌀 45 🔥4d]         ← Frustration + overwork streak
[0h45m | 12p ☕2 | ☀️ 100 💚5d]          ← Healthy streak, great habits
```

| Symbol | Meaning |
|:---|:---|
| ☀️ | All good |
| 🟡 | Nudge level 1 |
| 🟠 | Nudge level 2 |
| 🔴 | Nudge level 3 |
| 🌀 | Frustration detected |
| ⚡N | Velocity (prompts/5min) |
| ☕N | Breaks taken |
| 🔥Nd | Overwork streak (days) |
| 💚Nd | Healthy streak (days) |
| **92** | Session wellness score |

Add to your statusline script:

```bash
BREATH_STATUS="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude-breath}/scripts/breath-status.sh"
if [ -x "$BREATH_STATUS" ]; then
  breath_out=$("$BREATH_STATUS" 2>/dev/null)
  [ -n "$breath_out" ] && echo "$breath_out"
fi
```

## How nudges work

```
You prompt Claude
    ↓
breath-hook.sh runs (bash, ~10ms)
    ↓
Reads state → calculates duration, velocity, score, streaks
    ↓
Under threshold? → {"suppressOutput":true}  (0 tokens)
    ↓
Over threshold?  → {"systemMessage":"[BREATH] ..."}  (~50 tokens)
    ↓
Claude acknowledges and checks if your work is urgent
```

### Smart nudge examples

```
[BREATH] Session: 1h32m. 16 prompts. Stand up, roll your shoulders, take three deep breaths.
[BREATH] Session: 50m. 24 prompts. Velocity: 18p/5m. You're moving fast. Pause — is this the right approach?
[BREATH] Session: 2h05m. 34 prompts. Overwork streak: 4 days. Your streak data shows a pattern that leads to burnout. Take tomorrow off.
[BREATH] Session: 15m. 22 prompts. Velocity: 22p/5m. You're in a rapid-fire loop. Step back and rethink the approach. (Score: 45/100)
[BREATH] Session: 3h10m. 58 prompts. It's 1:30AM. This is past the point of productivity. Sleep is the best debugger.
```

## Self-healing breaks

When you take a real break (5+ min of inactivity), the system **fully heals**:
- Session timer resets
- Prompt count resets
- Velocity clears
- Frustration counter clears
- Score recalculates with break bonus

This means breaks are genuinely rewarding — the system recognizes recovery, not just elapsed time.

## Session scoring (0-100)

| Factor | Effect |
|:---|:---|
| Past threshold 1 | -1 per minute |
| Past threshold 2 | -2 per minute |
| Past threshold 3 | -5 per minute |
| Each break taken | +10 (max +30) |
| No frustration events | +5 |
| Each frustration event | -10 |

Scores are logged per session and tracked over time for trend analysis.

## Adaptive thresholds

When `adaptive_thresholds: true`, the system analyzes your last 7 days of history:

- **Good habits** (regular breaks, shorter sessions): thresholds relax +10%
- **Normal patterns**: no adjustment
- **Bad habits** (long sessions, no breaks): thresholds tighten -15 to -20%

Adjustments are capped at ±30% to prevent runaway adaptation.

## Configuration

On first run, `config.json` is auto-created. Edit anytime — changes take effect on the next prompt.

```json
{
  "nudge_system_message": true,
  "nudge_thresholds_min": [90, 120, 180],
  "prompt_density_threshold": 40,
  "off_hours_multiplier": 0.67,
  "off_hours_start": 23,
  "off_hours_end": 7,
  "weekend_multiplier": 0.75,
  "break_gap_min": 5,
  "session_gap_min": 15,
  "nudge_cooldown_min": 15,
  "velocity_window_sec": 300,
  "velocity_threshold": 15,
  "frustration_threshold": 20,
  "streak_alert_days": 3,
  "adaptive_thresholds": true,
  "message_variety": true,
  "history_retention_days": 14
}
```

| Setting | What it does | Default |
|:---|:---|:---|
| `nudge_thresholds_min` | Minutes for Level 1/2/3 nudges | `[90, 120, 180]` |
| `prompt_density_threshold` | Prompts that trigger a density boost | `40` |
| `velocity_window_sec` | Rolling window for velocity calculation | `300` (5 min) |
| `velocity_threshold` | Prompts/window = high velocity warning | `15` |
| `frustration_threshold` | Prompts/window = frustration intervention | `20` |
| `streak_alert_days` | Overwork days before streak warning | `3` |
| `adaptive_thresholds` | Learn from history to adjust timing | `true` |
| `message_variety` | Rotate contextual nudge messages | `true` |
| `off_hours_multiplier` | Threshold multiplier during off-hours | `0.67` |
| `weekend_multiplier` | Threshold multiplier on weekends | `0.75` |
| `break_gap_min` | Minutes of inactivity = break (full heal) | `5` |
| `session_gap_min` | Minutes of inactivity = new session | `15` |
| `nudge_cooldown_min` | Minutes before same nudge level re-fires | `15` |

## Reports

Generate a wellness intelligence report:

```bash
bash scripts/breath-report.sh
```

Includes: summary stats, behavioral intelligence (scores, velocity, frustration), day-of-week patterns, longest sessions, trend analysis.

## Plugin structure

```
claude-breath/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── hooks/
│   └── hooks.json           # Auto-registers UserPromptSubmit hook
├── scripts/
│   ├── breath-hook.sh       # Core intelligence engine
│   ├── breath-creature.sh   # Creature lifecycle, HP, XP, shop, death
│   ├── breath-status.sh     # Enhanced statusline segment
│   ├── breath-report.sh     # Wellness intelligence report
│   └── breath-messages.sh   # Contextual message pool (60+ messages)
├── tests/
│   ├── test-hook.sh         # 52 assertions
│   ├── test-creature.sh     # 70 assertions
│   └── test-status.sh       # 10 assertions
├── .gitignore
├── LICENSE
└── README.md
```

## Tests

```bash
bash tests/test-hook.sh       # 52 assertions
bash tests/test-creature.sh   # 70 assertions
bash tests/test-status.sh     # 10 assertions
```

## License

MIT
