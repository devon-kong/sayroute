#!/bin/bash
# Build and run in one step, with logs streaming
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
echo "🔨 Building..."
xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  build \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)'

APP="build/Build/Products/Debug/Doubao Murmur.app"

# Kill existing instance
pkill -x "Doubao Murmur" 2>/dev/null || true
sleep 0.5

echo ""
echo "🚀 Starting Doubao Murmur..."
echo "---"
"$APP/Contents/MacOS/Doubao Murmur" 2>&1
