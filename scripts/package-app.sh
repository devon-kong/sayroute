#!/bin/zsh
set -euo pipefail

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "${repo_root}"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
    print -u2 "Refusing to package an uncommitted working tree."
    exit 1
}
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
[[ -x "${developer_dir}/usr/bin/xcodebuild" ]] || {
    print -u2 "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory."
    exit 1
}
temporary_root="$(/usr/bin/mktemp -d -t murmur-app-package)"
trap '/bin/rm -rf "${temporary_root}"' EXIT
xcodegen generate
DEVELOPER_DIR="${developer_dir}" xcodebuild \
    -project doubao-murmur.xcodeproj -scheme doubao-murmur \
    -configuration Release -derivedDataPath "${temporary_root}/DerivedData" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build
app="${temporary_root}/DerivedData/Build/Products/Release/Doubao Murmur.app"
plist="${app}/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}")" == com.doubao.murmur ]]
for field in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :${field}" "${plist}")" == 'Doubao Murmur' ]]
done
if [[ -n "${RELEASE_TAG:-}" ]]; then
    [[ "${RELEASE_TAG}" == "v${version}" ]] || { print -u2 "Tag and project version differ"; exit 1; }
fi
for binary in "${app}/Contents/MacOS/Doubao Murmur" "${app}/Contents/Helpers/murmur-updater"; do
    archs="$(/usr/bin/lipo -archs "${binary}")"
    [[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]]
done
/usr/bin/codesign --verify --strict --deep "${app}"
mkdir -p dist
archive="${repo_root}/dist/Doubao-Murmur-v${version}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
/usr/bin/ditto -x -k "${archive}" "${temporary_root}/verify"
/usr/bin/codesign --verify --strict --deep "${temporary_root}/verify/Doubao Murmur.app"
diff -qr "${app}" "${temporary_root}/verify/Doubao Murmur.app"
(cd dist && /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
{
    print "source_commit=$(git rev-parse HEAD)"
    print "version=${version}"
    print "build=${build}"
    print "bundle_id=com.doubao.murmur"
    print "architectures=arm64 x86_64"
    print "signature=ad-hoc"
    print "notarized=no"
} > "${archive%.zip}.build-info.txt"
print "Created ${archive} (build ${build})"
