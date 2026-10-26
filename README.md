# Doubao Murmur

macOS 菜单栏语音输入工具：使用本机[豆包输入法](https://www.doubao.com/)完成识别，再把已确认的文字粘贴到原目标输入框。支持本机、网易 UU **兼容模式**与 UU **快速模式**。

当前正式版为 **v1.3.1**：控制端 **build20**，Mirror **build19**。控制端应用名为 **Doubao Murmur**。本版包含长文提交与失败恢复、修饰键状态修复，以及可跟随鼠标定位的输入框。

详细行为见[当前使用说明](docs/current-usage-and-system-flow.md)，版本变化与验证边界见[发布说明](docs/release-notes.md)。

<p align="center">
  <img src="docs/screenshots/overlay_pannel.png" width="500" alt="语音识别悬浮窗">
</p>

## 要求与安装

- macOS 13.0+；已安装并启用豆包输入法。
- 在「系统设置 → 隐私与安全性 → 辅助功能」授予 Doubao Murmur 权限。
- 从 [最新正式版](https://github.com/devon-kong/doubao-murmur/releases/latest) 下载 `Doubao-Murmur-v1.3.1.zip`，解压后将 `Doubao Murmur.app` 放入“应用程序”。
- 从测试版迁移时，先退出测试版，再启动正式版，避免两个进程同时监听快捷键。正式版使用独立应用身份，需检查自己的辅助功能授权及菜单偏好。
- 当前包为 ad-hoc 签名、未做 Apple 公证；内置自动安装会提示手动更新。辅助功能开关已开但快捷键无响应时，移除旧项后重新添加当前“应用程序”路径。
- 快速模式被控端使用同一发布页的 `murmur-mirror-mac-mini-v1.3.1-build19.zip`；已安装 build19 的机器无需重复安装。

## 免责声明

- 本项目仅供个人学习和研究使用，不得用于商业用途。
- 本项目通过系统输入源切换和合成按键驱动已安装的豆包输入法，不是豆包官方 API 或 SDK。
- 使用前需自行安装并启用豆包输入法；识别由该输入法在本机完成。
- 本工具不上传识别原文；文字恢复功能会在本机加密暂存识别结果，最多3天，退出后不恢复。快速模式会通过你配置的UU映射把文字发送至被控端。豆包输入法自身的数据处理规则以其说明为准。
- 使用本项目产生的后果由使用者自行承担；如认为本项目侵犯相关权益，请联系作者处理。

## 正确操作

1. 先把光标放到目标输入框。
2. 按一次 `⌃ Control + /` 开始。应用等待该热键完全释放、输入框聚焦和豆包输入法就绪后，合成一次右 `Command` 启动豆包。
3. 说完后，**手动按一次物理右 `Command`** 停止豆包。该键不会被应用吞掉。
4. 看到输入法的下划线消失后，应用在下一主循环冻结文字，恢复原目标，再按所选模式粘贴。

| 操作 | 行为 |
| --- | --- |
| `⌃ Control + /`（空闲） | 开始录音 |
| `⌃ Control + /`（录音中） | 忽略；不会停止或粘贴 |
| 物理右 `Command`（录音中） | 用户的停止手势 |
| `ESC` | 安全取消：不复制、不粘贴，恢复原输入法 |

## 输入框位置

菜单“输入框位置”提供“跟随鼠标坐标”（默认）和“屏幕上方”。鼠标模式下，先把鼠标移到目标输入框附近，再按快捷键；浮窗底边左起1/3对齐鼠标，屏幕边缘自动避让，同一轮输入期间位置固定。设置自动保存，下次录音生效。

## 粘贴模式

| 模式 | 适用场景 | 方式 |
| --- | --- | --- |
| 本机 | 普通本地应用 | 恢复原目标后复制并模拟 `⌘V` |
| 兼容模式 | UU 远控的默认选择 | 使用 UU 正常剪贴板同步；菜单可调整剪贴板稳定时间 |
| 快速模式 | 已配置 Mac mini helper 与 UU 端口映射 | 控制端请求 helper 直写远端剪贴板，再由 helper 投递 `⌘V` |

快速模式需要 Mac mini 安装 `murmur-mirror`，将 MacBook `127.0.0.1:17771` 映射到 Mac mini `127.0.0.1:17771`，并授予 helper 辅助功能权限。安装细节见[helper 安装说明](packaging/murmur-mirror/README.md)。

```text
Control + / (start only)
  -> capture original target and PasteRouter route for this session
  -> focus + Doubao input source ready + hotkey released
  -> synthetic right Command starts Doubao
  -> user presses physical right Command to stop
  -> marked text true -> false
  -> freeze text -> execute route captured at session start
  -> local / compatibility / fast paste route
```

## 故障与日志

- 停止后1.5秒只提示等待；15秒仍未确认提交、失焦或停止手势被打断时，保留草稿并停止自动粘贴。菜单“最近文字与恢复”可取回原文；原文加密暂存磁盘，最多20条、最长3天，退出/重启不恢复。打开窗口清除已有失败提醒，记录及失败状态保留。
- 快速模式单笔显示“状态未知”仅表示控制端未确认回执；先检查目标输入框，**不要重试该笔**。`eventPosted=true` 只说明 helper 投递了按键事件，不证明目标应用已消费文字。
- 控制端日志：`~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3`。
- helper 日志与验收请见[helper 安装说明](packaging/murmur-mirror/README.md)。

## 开发与测试

需要 Xcode 15+；正式App构建还需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

该测试入口不启动真实App、快捷键监听或helper。在干净且已提交的源码上生成正式包：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/package-app.sh
scripts/package-murmur-mirror.sh
```

产物、SHA-256与来源信息位于 `dist/`。主分支和标签CI执行相同测试与打包检查；`v*` 标签通过后发布。构建号取自源码，不使用CI运行次数。

## License

[MIT](LICENSE)
