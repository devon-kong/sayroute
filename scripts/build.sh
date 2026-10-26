#!/bin/bash
# Build the app
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
echo "🔨 Building SayRoute..."
xcodebuild -project SayRoute.xcodeproj \
  -scheme SayRoute \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  build \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED|CompileSwift|Linking)'

echo ""
echo "✅ Build complete"
