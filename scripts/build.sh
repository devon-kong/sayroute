#!/bin/bash
# Build the app
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
echo "🔨 Building doubao-murmur..."
xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  build \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED|CompileSwift|Linking)'

echo ""
echo "✅ Build complete"
