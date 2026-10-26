# SayRoute 1.4.0 RC 1

**Preview release / 预发布版本** — controller **1.4.0 (21)**, bridge **1.4.0 (20)**.

SayRoute is the new product identity of the macOS dictation companion previously called Doubao Murmur. It delivers text from the installed Doubao Input Method to local apps or a remote Mac through NetEase UU.

## Downloads

- `SayRoute-v1.4.0-rc.1.zip`: controller app; unzip and place **SayRoute.app** in Applications.
- `sayroute-bridge-macos-v1.4.0-build20.zip`: companion for the **controlled Mac**; unzip the complete directory and run `install.command`.
- SHA-256 files and build/source manifests accompany the packages. Both executables include arm64 and x86_64.

## Changes

- New SayRoute app, icon, bundle ID, bridge/updater names and release filenames.
- One-time validated import of three preferences, with existing SayRoute values taking priority.
- Keeps old data and app files available for rollback; blocks competing old/new hotkey listeners.
- Bridge installation verifies its service/build/PID, backs up existing state and supports generation-safe rollback.
- English-first README, Chinese counterpart and preserved upstream MIT attribution, included in the packages.

## Before installing

Copy any recovery text you need **before quitting the old app**; its encryption key does not survive exit. Grant Accessibility to the new app and the new remote bridge path. These ad-hoc signed packages are not notarized and require manual installation.

Read the [migration and rollback guide](https://github.com/devon-kong/sayroute/blob/master/docs/sayroute-migration.md) and [bridge installation guide](https://github.com/devon-kong/sayroute/blob/master/packaging/sayroute-bridge/README.md).

## Validation boundary

128 hostless Swift tests, six isolated installer transaction tests, universal builds, signature/archive checks and isolated health/invalid-request checks passed during migration. CI for this tag validates the packaged source again. **Real dictation through local, UU compatibility and UU fast routes is still pending**, so this remains a prerelease. See [acceptance status](https://github.com/devon-kong/sayroute/blob/master/docs/sayroute-acceptance.md).

The bridge remains unauthenticated and loopback-only. Do not expose it to a LAN or public internet. A posted paste event does not prove that an editor inserted the text.

---

## 中文说明

这是 **SayRoute 1.4.0 RC 1 预发布版**，包含新名称、新图标及新的安装包。控制端为 build21，远端 Bridge 为 build20。原豆包输入法依赖不变。

- 控制端下载 `SayRoute-v1.4.0-rc.1.zip`；远端下载 `sayroute-bridge-macos-v1.4.0-build20.zip`。
- 退出旧版前先复制需要保留的恢复文字；新 App 和 Bridge 均需重新授予辅助功能权限。
- 安装器提供备份和回退；原 MIT 版权与署名随包保留。
- 自动测试和双架构构建已通过，真实三条语音输入流程尚待验收，因此没有标为正式版。
- [中文安装说明](https://github.com/devon-kong/sayroute/blob/master/packaging/sayroute-bridge/README.zh-CN.md) · [迁移与回退](https://github.com/devon-kong/sayroute/blob/master/docs/sayroute-migration.md)
