#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
preview_dir="$PWD/dist/preview/SayRoute Preview.app"
mkdir -p "$preview_dir/Contents/MacOS"
sources=(SayRoute/*.swift Shared/*.swift)
sources=(${sources:#SayRoute/SayRouteApp.swift})
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    -swift-version 5 "${sources[@]}" scripts/preview-ui/main.swift -lsqlite3 \
    -o "$preview_dir/Contents/MacOS/SayRoute Preview"
cat > "$preview_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.devonkong.sayroute.documentation</string>
<key>CFBundleName</key><string>SayRoute Preview</string>
<key>CFBundleExecutable</key><string>SayRoute Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$preview_dir"
print "$preview_dir"
