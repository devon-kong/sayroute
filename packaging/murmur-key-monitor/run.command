#!/bin/zsh

set -u

tool_dir="$(cd "${0:A:h}" && pwd)"
"${tool_dir}/murmur-key-monitor"
status=$?
print
print "murmur-key-monitor 已退出，状态码：${status}。日志不会自动删除。"
read -r "?按 Return 键关闭此 Terminal 窗口..."
exit "${status}"
