#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
temporary_root="$(mktemp -d -t sayroute-native-visuals)"
trap 'rm -rf "$temporary_root"' EXIT
# Access control only: keep the production view body byte-for-byte unchanged.
# This copied file is documentation build input, never compiled into SayRoute.app.
sed 's/^private struct RecoveryListView: View {/struct RecoveryListView: View {/' \
    SayRoute/RecoveryWindow.swift > "$temporary_root/RecoveryWindow.swift"
sources=(SayRoute/*.swift Shared/*.swift)
sources=(${sources:#SayRoute/SayRouteApp.swift})
sources=(${sources:#SayRoute/RecoveryWindow.swift})
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    -swift-version 5 "${sources[@]}" "$temporary_root/RecoveryWindow.swift" \
    scripts/native-visuals/main.swift -lsqlite3 -o "$temporary_root/render-native-visuals"
"$temporary_root/render-native-visuals" "${1:-docs/visuals}"
