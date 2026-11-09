#!/bin/zsh
# Real native smoke test, not a mocked hdiutil/Finder test. Does not build the app.
set -euo pipefail
repo_root="${0:A:h:h}"
[[ $# -le 1 ]] || { print -u2 'Usage: test-dmg.sh [/path/to/SayRoute.app]'; exit 64; }
temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent:A}"
readonly temporary_root="$(/usr/bin/mktemp -d "${temp_parent}/sayroute-dmg-test.XXXXXXXX")"
readonly resolved_temporary_root="${temporary_root:A}"
[[ "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-dmg-test.* ]]
mounted=0
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if (( mounted )); then
        if ! /usr/bin/hdiutil detach "${temporary_root}/mounted image"; then
            print -u2 'Detach failed; preserving test directory.'
            exit 1
        fi
    fi
    if [[ "${temporary_root:A}" == "${resolved_temporary_root}" && "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-dmg-test.* ]]; then
        /bin/rm -rf -- "${resolved_temporary_root}"
    else
        print -u2 'Temporary path changed; refusing cleanup.'
        result=1
    fi
    exit "${result}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
/bin/mkdir "${temporary_root}/input with spaces" "${temporary_root}/mounted image"
app="${1:-${temporary_root}/input with spaces/SayRoute.app}"
app="${app:A}"
if [[ $# == 0 ]]; then
    /bin/mkdir -p "${app}/Contents/MacOS"
    /bin/cp /usr/bin/true "${app}/Contents/MacOS/SayRoute"
    /usr/bin/plutil -create xml1 "${app}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string SayRoute "${app}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string com.devonkong.sayroute.dmg-test "${app}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleName -string SayRoute "${app}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "${app}/Contents/Info.plist"
    /usr/bin/codesign --force --sign - "${app}"
fi
# Failures must propagate and must not create an output or modify caller files.
if "${repo_root}/scripts/create-dmg.sh" "${temporary_root}/missing.app" "${temporary_root}/invalid.dmg" > "${temporary_root}/negative.log" 2>&1; then
    print -u2 'Missing app was incorrectly accepted'; exit 1
fi
[[ ! -e "${temporary_root}/invalid.dmg" ]]
/bin/ln -s "${app}/Contents/Info.plist" "${temporary_root}/symlink.dmg"
if "${repo_root}/scripts/create-dmg.sh" "${app}" "${temporary_root}/symlink.dmg" >> "${temporary_root}/negative.log" 2>&1; then
    print -u2 'Symlink output was incorrectly accepted'; exit 1
fi
image="${temporary_root}/SayRoute test.dmg"
"${repo_root}/scripts/create-dmg.sh" "${app}" "${image}"
/usr/bin/hdiutil imageinfo -plist "${image}" > "${temporary_root}/image-info.plist"
[[ "$(/usr/bin/plutil -extract Format raw "${temporary_root}/image-info.plist")" == UDZO ]]
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "${temporary_root}/mounted image" "${image}"
mounted=1
[[ -L "${temporary_root}/mounted image/Applications" ]]
[[ "$(/usr/bin/readlink "${temporary_root}/mounted image/Applications")" == /Applications ]]
[[ -s "${temporary_root}/mounted image/.DS_Store" ]]
/usr/bin/codesign --verify --deep --strict "${temporary_root}/mounted image/SayRoute.app"
/usr/bin/diff -qr "${app}" "${temporary_root}/mounted image/SayRoute.app"
# Validate persisted settings on the final read-only image, not the staging disk.
/usr/bin/osascript - "${temporary_root}/mounted image" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        open (POSIX file mountPath as alias)
        set imageWindow to front Finder window
        set imageFolder to target of imageWindow
            if current view of imageWindow is not icon view then error "Not icon view"
            if toolbar visible of imageWindow then error "Toolbar visible"
            if statusbar visible of imageWindow then error "Status bar visible"
            if pathbar visible of imageWindow then error "Path bar visible"
            set windowBounds to bounds of imageWindow
            if (item 3 of windowBounds) - (item 1 of windowBounds) is not 640 then error "Wrong window width"
            if (item 4 of windowBounds) - (item 2 of windowBounds) is not 448 then error "Wrong window height"
            if position of item "SayRoute.app" of imageFolder is not {165, 196} then error "Wrong app position"
            if position of item "Applications" of imageFolder is not {475, 196} then error "Wrong Applications position"
            tell icon view options of imageWindow
                if arrangement is not not arranged then error "Unexpected icon arrangement"
                if icon size is not 96 then error "Wrong icon size"
                if text size is not 14 then error "Wrong text size"
            end tell
        close imageWindow
    end tell
end run
APPLESCRIPT
/usr/bin/sips -g pixelWidth -g pixelHeight "${temporary_root}/mounted image/.background/background.png"
/usr/bin/hdiutil detach "${temporary_root}/mounted image"
mounted=0
print 'PASS: DMG UDZO, signature, bundle identity, Applications symlink, persisted Finder layout/background, spaces and invalid inputs.'
