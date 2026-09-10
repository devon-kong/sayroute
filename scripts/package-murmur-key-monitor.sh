#!/bin/zsh

set -euo pipefail

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "${repo_root}"

xcode_app="${XCODE_APP:-/Applications/Xcode.app}"
developer_dir="${xcode_app}/Contents/Developer"
[[ -x "${developer_dir}/usr/bin/xcodebuild" ]] || {
    print -u2 "未找到 Xcode：${xcode_app}"
    exit 1
}
command -v xcodegen >/dev/null || {
    print -u2 "构建此诊断包需要 xcodegen。"
    exit 1
}
command -v zip >/dev/null || {
    print -u2 "打包此诊断包需要 zip。"
    exit 1
}

full_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"
source_branch="$(git branch --show-current)"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    dirty_flag="true"
else
    dirty_flag="false"
fi
timestamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
package_name="murmur-key-monitor-${short_sha}-${timestamp}"
dist_dir="${repo_root}/dist"
archive_path="${dist_dir}/${package_name}.zip"
temporary_root="$(/usr/bin/mktemp -d -t murmur-key-monitor-package)"
derived_data="${temporary_root}/DerivedData"
package_root="${temporary_root}/${package_name}"

cleanup() {
    /bin/rm -rf "${temporary_root}"
}
trap cleanup EXIT

print "Generating Xcode project..."
xcodegen generate >/dev/null

print "Building universal murmur-key-monitor..."
DEVELOPER_DIR="${developer_dir}" /usr/bin/xcodebuild \
    -project doubao-murmur.xcodeproj \
    -scheme murmur-key-monitor \
    -configuration Release \
    -derivedDataPath "${derived_data}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

built_tool="${derived_data}/Build/Products/Release/murmur-key-monitor"
[[ -x "${built_tool}" ]] || {
    print -u2 "未找到构建出的 murmur-key-monitor。"
    exit 1
}

/bin/mkdir -p "${package_root}"
/bin/cp "${built_tool}" "${package_root}/murmur-key-monitor"
/usr/bin/codesign --force --sign - --identifier com.doubao.murmur.key-monitor "${package_root}/murmur-key-monitor"
/usr/bin/codesign --verify --strict "${package_root}/murmur-key-monitor"

archs="$(/usr/bin/lipo -archs "${package_root}/murmur-key-monitor")"
[[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]] || {
    print -u2 "通用架构检查失败：${archs}"
    exit 1
}

for package_file in run.command verify.command README.md; do
    /bin/cp "packaging/murmur-key-monitor/${package_file}" "${package_root}/${package_file}"
done
/bin/chmod 0755 "${package_root}/murmur-key-monitor" "${package_root}/run.command" "${package_root}/verify.command"

(
    cd "${package_root}"
    /usr/bin/shasum -a 256 murmur-key-monitor > murmur-key-monitor.sha256
)

{
    print "source_commit=${full_sha}"
    print "source_branch=${source_branch}"
    print "source_dirty=${dirty_flag}"
    print "architectures=${archs}"
    print "minimum_macos=13.0"
    print "diagnostic_only=yes"
    print "signature=ad-hoc"
    print "notarized=no"
    print "built_at_utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${package_root}/BUILD-INFO.txt"

/bin/zsh -n "${package_root}/run.command" "${package_root}/verify.command"

/bin/mkdir -p "${dist_dir}"
(
    cd "${temporary_root}"
    /usr/bin/zip -qryX "${archive_path}" "${package_name}"
)

print "Created ${archive_path}"
print "Archive SHA-256: $(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
print "Source dirty: ${dirty_flag}"
