#!/bin/zsh
set -euo pipefail

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "${repo_root}"
source scripts/package-policy.sh
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
[[ -x "${developer_dir}/usr/bin/xcodebuild" ]] || {
    print -u2 "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory."
    exit 1
}
temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent:A}"
readonly temporary_root="$(/usr/bin/mktemp -d "${temp_parent}/sayroute-app-package.XXXXXXXX")"
readonly resolved_temporary_root="${temporary_root:A}"
[[ "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-app-package.* ]] || { print -u2 'Unexpected mktemp path'; exit 1; }
cleanup() {
    local result=$?
    if [[ "${temporary_root:A}" == "${resolved_temporary_root}" && "${resolved_temporary_root:h}" == "${temp_parent}" && "${resolved_temporary_root:t}" == sayroute-app-package.* ]]; then
        /bin/rm -rf -- "${resolved_temporary_root}"
    else
        print -u2 'Temporary path changed; refusing cleanup.'
        result=1
    fi
    return "${result}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
xcodegen generate
DEVELOPER_DIR="${developer_dir}" xcodebuild \
    -project SayRoute.xcodeproj -scheme SayRoute \
    -configuration Release -derivedDataPath "${temporary_root}/DerivedData" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build
app="${temporary_root}/DerivedData/Build/Products/Release/SayRoute.app"
plist="${app}/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}")" == com.devonkong.sayroute ]]
for field in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :${field}" "${plist}")" == 'SayRoute' ]]
done
if [[ -n "${RELEASE_TAG:-}" ]]; then
    [[ "${RELEASE_TAG}" == "v${version}" || "${RELEASE_TAG}" == "v${version}-rc."<-> ]] || { print -u2 "Tag and project version differ"; exit 1; }
fi
for binary in "${app}/Contents/MacOS/SayRoute" "${app}/Contents/Helpers/sayroute-updater"; do
    archs="$(/usr/bin/lipo -archs "${binary}")"
    [[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]]
done
/usr/bin/codesign --verify --strict --deep "${app}"
mkdir -p dist
archive="${repo_root}/dist/SayRoute-${RELEASE_TAG:-v${version}}${package_suffix}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
/usr/bin/ditto -x -k "${archive}" "${temporary_root}/verify"
/usr/bin/codesign --verify --strict --deep "${temporary_root}/verify/SayRoute.app"
diff -qr "${app}" "${temporary_root}/verify/SayRoute.app"
# Keep ZIP unchanged for the existing in-app updater; DMG is for manual installs.
dmg="${archive%.zip}.dmg"
scripts/create-dmg.sh "${app}" "${dmg}"
(cd dist && /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
(cd dist && /usr/bin/shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
{
    print "source_state=${source_state}"
    print "source_commit=$(git rev-parse HEAD)"
    print "version=${version}"
    print "build=${build}"
    print "bundle_id=com.devonkong.sayroute"
    print "architectures=arm64 x86_64"
    print "signature=ad-hoc"
    print "notarized=no"
    print "formats=zip dmg"
    print "zip=${archive:t}"
    print "dmg=${dmg:t}"
    print "dmg_filesystem=HFS+"
    print "dmg_format=UDZO"
    print "dmg_layout=640x420 icons=165,196;475,196 size=96"
    print "macos_version=$(/usr/bin/sw_vers -productVersion)"
    print "macos_build=$(/usr/bin/sw_vers -buildVersion)"
} > "${archive%.zip}.build-info.txt"
write_source_manifest "${archive%.zip}.sources.sha256"
print "Created ${archive} and ${dmg} (build ${build})"
