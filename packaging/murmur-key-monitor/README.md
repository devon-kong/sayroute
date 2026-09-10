# Doubao Murmur 键盘状态临时诊断工具

此工具只用于一次 5–10 分钟的受控复现：确认快速粘贴后，后续 Backspace／Return 事件的 Command 标志是否仍存在。它使用 macOS 的只监听键盘 event tap，不拦截、修改、合成或重发任何键盘事件。

## 使用

1. 解压整个 ZIP，双击 `run.command`。
2. 若系统提示，请在“系统设置 > 隐私与安全性 > 输入监控”允许正在运行它的 Terminal；返回后重新运行。
3. 工具前台运行 600 秒后自动停止。按正常方式复现一次快速粘贴，再按 Backspace 或 Return。
4. Terminal 会打印 JSONL 日志的准确路径；日志不会自动删除。

可在 Terminal 手动运行 `./murmur-key-monitor --duration-seconds 300`（60–600 秒）或 `--output /完整/路径.jsonl`。`verify.command` 可离线验证校验和、签名、通用架构和无权限自检。

## 隐私与边界

仅记录 keyDown、keyUp、flagsChanged 中的 Command（54/55）、V（9）、Delete（51/117）、Return/Enter（36/76）元数据：时间、键码、flags、Command 布尔值、来源 PID/状态、键盘类型和前台 bundle identifier。不会记录输入文字、剪贴板、窗口标题、辅助功能文本或内容哈希。日志最大 1 MiB，达到上限即停止。

这是临时前台诊断工具：不安装、不创建 LaunchAgent／登录项、不持久化运行；ZIP 为 ad-hoc 签名且未公证。
