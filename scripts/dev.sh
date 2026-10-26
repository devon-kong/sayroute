#!/bin/bash
# Build and run in one step, with logs streaming
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
echo "🔨 Building..."
xcodebuild -project SayRoute.xcodeproj \
  -scheme SayRoute \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  build \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)'

APP="build/Build/Products/Debug/SayRoute.app"

# Kill existing instance
pkill -x "SayRoute" 2>/dev/null || true
sleep 0.5

echo ""
echo "🚀 Starting SayRoute..."
echo "---"
"$APP/Contents/MacOS/SayRoute" 2>&1
