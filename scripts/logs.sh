#!/bin/bash
# Tail logs from running SayRoute process via unified logging
# Usage: ./scripts/logs.sh [filter]
# Examples:
#   ./scripts/logs.sh              # all app logs
#   ./scripts/logs.sh HotkeyManager  # only hotkey logs
#   ./scripts/logs.sh Overlay        # only overlay logs

cd "$(dirname "$0")/.."

FILTER="${1:-}"

if pgrep -x "SayRoute" > /dev/null 2>&1; then
  PID=$(pgrep -x "SayRoute")
  echo "📋 Tailing logs for SayRoute (PID: $PID)"
  if [ -n "$FILTER" ]; then
    echo "   Filter: $FILTER"
  fi
  echo "   Press Ctrl+C to stop."
  echo "---"

  if [ -n "$FILTER" ]; then
    log stream --process "$PID" --style compact 2>/dev/null | grep --line-buffered "$FILTER"
  else
    log stream --process "$PID" --style compact 2>/dev/null
  fi
else
  echo "⚠️  SayRoute is not running."
  echo "   Start it with: ./scripts/run.sh or ./scripts/dev.sh"
fi
