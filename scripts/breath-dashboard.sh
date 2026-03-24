#!/bin/bash
# breath-dashboard.sh — Launch the Claude Breath web dashboard
# Uses the API server for live data + shop/config endpoints
set -euo pipefail

BREATH_DIR="${BREATH_DIR:-${CLAUDE_PLUGIN_DATA:-$(cd "$(dirname "$0")/.." && pwd)}}"
SERVER="$(cd "$(dirname "$0")/../web" && pwd)/server.py"
PORT="${1:-8420}"

# Auto-open browser after a short delay
(sleep 1 && open "http://localhost:${PORT}/dashboard.html" 2>/dev/null || true) &

BREATH_DIR="$BREATH_DIR" python3 "$SERVER" "$PORT"
