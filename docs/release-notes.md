# SayRoute 1.4.0

SayRoute delivers dictation from the Doubao Input Method to local apps and to Macs controlled through NetEase UU. This release pairs controller build 26 with SayRoute Bridge build 20. Both run on Apple Silicon and Intel Macs with macOS 13 or later.

## What changed

- Set, test or reset the start shortcut in Settings → General. The default is Control + /.
- Assign each Mac a distinct local UU port under 设备与端口. Fast mode locks the destination when dictation starts, including when two remote sessions occupy different fullscreen Spaces on the same display.
- The overlay and recovery history show the selected device. If a connection changes or the window cannot be identified, the text remains available in recovery. If SayRoute first sees an already-fullscreen window, leave fullscreen until the UU device name appears and then return.

## Installation

Install the controller from `SayRoute-v1.4.0.dmg` or `SayRoute-v1.4.0.zip`. For fast mode, install `sayroute-bridge-macos-v1.4.0-build20.zip` on the controlled Mac. An existing compatible v2 Bridge can keep using its configured loopback mapping. Each download includes a separate SHA-256 checksum.

Copy any temporary recovery text you want to keep before quitting the previous controller. The recovery key lasts for the current process only. These packages use ad-hoc signatures and require manual installation. Apple notarization is unavailable for this build. Grant Accessibility to the installed controller and remote Bridge.

[Migration and rollback](https://github.com/devon-kong/sayroute/blob/v1.4.0/docs/sayroute-migration.md) · [Bridge installation](https://github.com/devon-kong/sayroute/blob/v1.4.0/packaging/sayroute-bridge/README.md)

## 中文说明

控制端 build 26 支持自定义快捷键。多台 Mac 同时远控时，每台使用独立的 UU 本地端口，在目标窗口按同一个快捷键即可。录音开始时锁定设备，切换桌面不会改变本句的去向。若启动 SayRoute 时窗口已经全屏，请暂时退出全屏，待 UU 显示设备名后再返回。

控制端下载 DMG 或 ZIP。快速模式使用 Bridge build 20，已有兼容的 v2 Bridge 可继续使用。替换应用前，请先复制需要保留的临时恢复文字。安装后若快捷键未就绪，请在系统设置的「隐私与安全性 → 辅助功能」中允许「应用程序」里的 SayRoute。

[中文安装说明](https://github.com/devon-kong/sayroute/blob/v1.4.0/packaging/sayroute-bridge/README.zh-CN.md)
