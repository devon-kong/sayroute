#!/bin/bash
# Build and run the app, streaming logs to stdout
set -e
cd "$(dirname "$0")/.."

APP="build/Build/Products/Debug/SayRoute.app"

# Kill existing instance
pkill -x "SayRoute" 2>/dev/null || true
sleep 0.5

if [ ! -d "$APP" ]; then
  echo "⚠️  App not found at: $APP"
  echo "   Run scripts/build.sh first"
  exit 1
fi

echo "🚀 Starting SayRoute..."
echo "   Path: $APP"
echo "   Logs will stream below. Press Ctrl+C to stop."
echo "---"
"$APP/Contents/MacOS/SayRoute" 2>&1
