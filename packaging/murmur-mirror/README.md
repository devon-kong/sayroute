# Mac mini 安装说明（无需 Xcode）

本包是 **Mirror 1.3.1 build19 正式版**，配套 Doubao Murmur 控制端 v1.3.1 build20。它修正合成粘贴后Command状态残留问题；用户已确认基础Command/Delete交互恢复正常。只安装被控端所需的 `murmur-mirror`，主App运行在控制端。

## 1. 安装 helper

1. 将整个解压后的文件夹复制到 Mac mini；不要只复制 `murmur-mirror` 单文件。
2. 双击 `install.command`。若 macOS 不允许直接打开，请右键它并选择“打开”。
3. 安装器会校验 SHA-256、代码签名和本机架构，然后安装到当前用户目录并启动，不需要 Xcode、Homebrew、命令行工具、管理员密码或 `sudo`。
4. 安装器会把旧版 helper 和 LaunchAgent 备份到：

   ```text
   ~/Library/Application Support/Doubao Murmur/backups/<时间戳>/
   ```

安装位置：

```text
helper:      ~/Library/Application Support/Doubao Murmur/murmur-mirror
LaunchAgent: ~/Library/LaunchAgents/com.doubao.murmur.mirror.plist
日志:        ~/Library/Logs/Doubao Murmur/
订单事件库:  ~/Library/Application Support/Doubao Murmur/paste-orders-helper.sqlite3
```

本包使用 ad-hoc 签名，没有 Apple 公证。安装器不会自动移除 Gatekeeper 隔离属性。若 LaunchAgent 日志明确显示被 macOS 阻止，先核对本包 SHA-256，再只对已安装 helper 执行：

```bash
xattr -d com.apple.quarantine "$HOME/Library/Application Support/Doubao Murmur/murmur-mirror"
launchctl kickstart -k "gui/$(id -u)/com.doubao.murmur.mirror"
```

## 2. 授予辅助功能权限

这是快速模式真实投递 Command-V 的必要条件。

1. 在 Mac mini 打开“系统设置 → 隐私与安全性 → 辅助功能”。
2. 点“+”。在文件选择框按 `Command-Shift-G`。
3. 输入：

   ```text
   ~/Library/Application Support/Doubao Murmur/murmur-mirror
   ```

4. 添加后打开其开关。
5. 双击 `verify.command`。通过条件包括：

   ```json
   {"ok":true,"protocolVersion":2,"accessibilityTrusted":true}
   ```

如果更新 helper 后权限变回 `false`，请在辅助功能列表中移除旧项，再重新添加上述实际路径。ad-hoc 签名无法保证跨构建沿用 TCC 授权。

## 3. 在 MacBook 的 UU 中配置端口映射

先用 UU 从 MacBook 连接这台 Mac mini，再在 MacBook 控制端操作：

1. 打开 UU 的“端口映射”。
2. 当前设备选择这台 Mac mini，点击“添加”。
3. 填写并“保存后立即启用”：

   | 字段 | 值 |
   | --- | --- |
   | 名称 | `murmur-mirror` |
   | 本地端口 | `17771` |
   | 目标地址 | `127.0.0.1` |
   | 目标端口 | `17771` |

UU 当前界面没有独立协议字段；该映射使用 TCP。启用成功后，UU 会在 MacBook 本机 `127.0.0.1:17771` 监听，再转发到 Mac mini 的 `127.0.0.1:17771`。

若提示“本地端口已被占用”，先检查 MacBook 是否还运行了本地 `murmur-mirror` 或已有同端口规则；不要随意改端口，因为当前 Doubao Murmur 固定访问 `127.0.0.1:17771`。

## 4. 在 MacBook 验证映射

在 MacBook 的 Terminal 运行：

```bash
curl --fail --silent --show-error --max-time 3 \
  http://127.0.0.1:17771/health
```

通过条件：

```json
{"ok":true,"protocolVersion":2,"accessibilityTrusted":true}
```

JSON 字段顺序可能不同。若 `accessibilityTrusted` 为 `false`，回到第 2 步；连接失败则检查 Mac mini helper、UU 当前设备、规则启用状态和端口占用。

## 5. Mirror build19 两机验收

正式组合为控制端build20、Mirror build19。已安装build19的被控端无需重复安装；只更新控制端不会改变快速模式的远端合成按键。

1. `verify.command` 的健康响应应包含 `helperBuild: "1.3.1 (19)"`、`pasteKeyStrategy: "preflight-snapshot-v2"`，并确认辅助功能为 true。
2. 在被控端准备空白测试文本框，控制端按 `Control + /` 开始，说完按物理右 Command 停止并完全松开。
3. 先核对文字只插入一次，再从控制端经 UU 依次按 Delete、空格、A：分别只删除一个字符、插入空格、插入普通字符；不应删除整行、弹 Spotlight 或全选。
4. 左右 Command 各按下再松开后重测；短文字与100字以上长文字都测，并连续发送两笔。按住修饰键时 helper 会拒绝自动粘贴，放开后从记录复制恢复；不会额外发送全局Command松开事件或自动重发。
5. 断连测试预期为失败提示与记录保留；恢复连接后发起新会话应成功。遇到“结果未知”，先检查目标，避免手动重复粘贴。
6. 真实并发边界：在粘贴临界时按下/松开左右Command或Shift，检查是否误释放、漏按或残留。这一项未完成前，不宣称已覆盖全部物理按键场景；若有回归，停止验收、保留日志，暂用兼容模式。

`eventPosted=true` 只证明 helper 投递了按键，不等于目标应用已经消费文字。基础场景已由用户验收；上述矩阵用于新设备和不同目标编辑器的回归检查，并不声称所有组合均已验证。

## 6. 出现键盘异常时的60秒诊断

在**被控端**双击 `diagnose.command`，随后切回空白测试输入框，在60秒内完成快速输入和 Delete/空格/A 测试。可在终端按 Control-C 提前停止。它只监听，不修改或吞掉按键，不读取 Unicode 文字或剪贴板；只输出修饰键及上述测试键的类别、flags、来源PID、事件源、时间与版本。其他普通键忽略。日志权限受 umask 077 限制，文件位于 `~/Library/Logs/Doubao Murmur/modifiers-*.jsonl`。

若系统拒绝监听，按提示检查已安装 Mirror 的辅助功能/输入监控权限；不要把空日志当作没有异常。诊断命令支持1–120秒，不会常驻监听。

粘贴前后快照写入 `paste-orders-helper.sqlite3` 的 `modifiers_before_paste` / `modifiers_after_paste`，以 request_id 关联控制端订单。新增`paste_keys_prepared`记录发送前准备的down/up flags，`modifiers_after_dispatch`在投递后约50ms异步采样，不增加粘贴等待时间；这些快照不代表目标已消费文字，也不能仅凭50ms状态断定发生残留，因为用户可能已按其他修饰键。可结合诊断中的后续 Delete/空格事件判断 Command 是否仍存在；如果仍异常，分别对照远端物理键盘、UU键盘，以及断开UU后的helper本机粘贴，再定位 UU 与合成事件的影响。

订单事件库不保存识别文字、剪贴板内容、窗口标题或默认文字哈希。诊断元数据仍可能体现按键时间和前台进程，请只在空白测试场景运行。

认证/token 当前按项目决策暂缓。前提是 helper 只监听 Mac mini loopback，UU 也只在 MacBook loopback 建立本地监听。若任何一端暴露到 LAN、长期开放给其他用户或准备公开分发，认证立即升级为部署前必做。
