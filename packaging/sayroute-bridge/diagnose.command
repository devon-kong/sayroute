#!/bin/zsh
set -euo pipefail
umask 077
helper_path="$HOME/Library/Application Support/SayRoute/sayroute-bridge"
log_dir="$HOME/Library/Logs/SayRoute"
[[ -x "$helper_path" ]] || { print -u2 "请先安装本包中的 SayRoute Bridge。"; exit 1; }
mkdir -p "$log_dir"
log_path="$log_dir/modifiers-$(date +%Y%m%d-%H%M%S).jsonl"
print "接下来60秒只观察修饰键、空格、Delete、V和测试键A的事件元数据，不记录输入文字。"
print "请切到空白测试输入框，完成一次快速输入，再测试空格、Delete和A。"
print "日志：$log_path"
"$helper_path" --diagnose-modifiers 60 | tee "$log_path"
print "诊断结束。请按回车关闭。"
read -r
