#!/bin/zsh

set -euo pipefail

tool_dir="$(cd "${0:A:h}" && pwd)"
cd "${tool_dir}"
/usr/bin/shasum -a 256 -c murmur-key-monitor.sha256
/usr/bin/codesign --verify --strict murmur-key-monitor
/usr/bin/lipo -archs murmur-key-monitor
./murmur-key-monitor --self-test
print "验证通过：文件校验、签名、架构与无权限自检均成功。"
read -r "?按 Return 键关闭此 Terminal 窗口..."
