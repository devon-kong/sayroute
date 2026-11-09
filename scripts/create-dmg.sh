#!/bin/zsh
# Native macOS drag-to-Applications image. No app compilation or icon generation.
set -euo pipefail

fail() { print -u2 -- "$*"; exit 1; }
[[ $# == 2 ]] || { print -u2 'Usage: create-dmg.sh /path/to/SayRoute.app /path/to/output.dmg'; exit 64; }
script_dir="${0:A:h}"
app="${1:A}"
output="${2:a}"
[[ "${app:t}" == SayRoute.app && -d "${app}/Contents" ]] || fail 'Expected an existing SayRoute.app bundle.'
[[ "${output:e}" == dmg && -d "${output:h}" && ! -L "${output}" ]] || fail 'Output must be a .dmg in an existing directory, not a symlink.'
[[ ! -e "${output}" || -f "${output}" ]] || fail 'Output is not a regular file.'
[[ "${output}" != "${app}"/* ]] || fail 'Output cannot be inside the source app.'
/usr/bin/codesign --verify --strict --deep "${app}"

# Only this exact mktemp directory may ever be recursively removed. Resolve the
# parent first (macOS /var -> /private/var), then check both parent and basename.
temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent:A}"
readonly temporary_root="$(/usr/bin/mktemp -d "${temp_parent}/sayroute-dmg.XXXXXXXX")"
readonly resolved_temporary_root="${temporary_root:A}"
[[ "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-dmg.* ]] || fail 'Unexpected mktemp path; refusing cleanup.'
mounted=0
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if (( mounted )); then
        if ! /usr/bin/hdiutil detach "${temporary_root}/mount"; then
            print -u2 -- "Could not detach ${temporary_root}/mount; preserving temporary directory."
            exit 1
        fi
    fi
    if [[ "${temporary_root:A}" == "${resolved_temporary_root}" && "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-dmg.* ]]; then
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

/bin/mkdir "${temporary_root}/stage" "${temporary_root}/mount"
/bin/mkdir "${temporary_root}/stage/.background"
/usr/bin/ditto "${app}" "${temporary_root}/stage/SayRoute.app"
/bin/ln -s /Applications "${temporary_root}/stage/Applications"
/usr/bin/xcrun swift "${script_dir}/render-dmg-background.swift" "${temporary_root}/stage/.background/background.png"
# Extra headroom is needed for HFS+ metadata and Finder's persisted .DS_Store.
size_kb="$(/usr/bin/du -sk "${temporary_root}/stage" | /usr/bin/awk '{print $1}')"
size_mb=$(( (size_kb + 1023) / 1024 + 32 ))
/usr/bin/hdiutil create -quiet -size "${size_mb}m" -fs HFS+ -volname SayRoute "${temporary_root}/writable.dmg"
/usr/bin/hdiutil attach -quiet -readwrite -noautoopen -nobrowse -mountpoint "${temporary_root}/mount" "${temporary_root}/writable.dmg"
mounted=1
/usr/bin/ditto "${temporary_root}/stage" "${temporary_root}/mount"
# Finder is required in a logged-in GUI session. Fail, rather than silently
# shipping an unstyled image, if Automation permission or Finder is unavailable.
/usr/bin/osascript - "${temporary_root}/mount" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set imageFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias
    tell application "Finder"
        open imageFolder
        set imageWindow to front Finder window
        set imageFolder to target of imageWindow
        tell imageWindow
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            -- 640 x 420 content, plus the native 28-point title bar.
            set bounds to {200, 160, 840, 608}
        end tell
        tell icon view options of imageWindow
            set arrangement to not arranged
            set icon size to 96
            set text size to 14
            set shows item info to false
            set shows icon preview to false
            set background picture to backgroundFile
        end tell
        set position of item "SayRoute.app" of imageFolder to {165, 196}
        set position of item "Applications" of imageFolder to {475, 196}
        update imageFolder without registering applications
        delay 2
        close container window of imageFolder
        -- Reopen once so Finder flushes window and icon settings to .DS_Store.
        open imageFolder
        delay 1
        close container window of imageFolder
    end tell
end run
APPLESCRIPT
[[ -s "${temporary_root}/mount/.DS_Store" ]] || fail 'Finder did not persist .DS_Store.'
/bin/sync
/usr/bin/hdiutil detach "${temporary_root}/mount"
mounted=0
/usr/bin/hdiutil convert -quiet "${temporary_root}/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "${temporary_root}/result.dmg"
/usr/bin/hdiutil verify "${temporary_root}/result.dmg"
/usr/bin/hdiutil attach -quiet -readonly -noautoopen -nobrowse -mountpoint "${temporary_root}/mount" "${temporary_root}/result.dmg"
mounted=1
[[ -s "${temporary_root}/mount/.DS_Store" && -s "${temporary_root}/mount/.background/background.png" ]]
[[ -L "${temporary_root}/mount/Applications" && "$(/usr/bin/readlink "${temporary_root}/mount/Applications")" == /Applications ]]
/usr/bin/codesign --verify --strict --deep "${temporary_root}/mount/SayRoute.app"
/usr/bin/diff -qr "${app}" "${temporary_root}/mount/SayRoute.app"
/usr/bin/xcrun swift "${script_dir}/verify-dmg-layout.swift" "${temporary_root}/mount"
/usr/bin/hdiutil detach "${temporary_root}/mount"
mounted=0
/bin/cp "${temporary_root}/result.dmg" "${output}"
print -r -- "Created ${output}"
