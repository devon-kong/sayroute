# SayRoute migration and rollback / 迁移与回退

This migration changes product identity. It does not bypass macOS permissions or rewrite the old installation in place.

| Component | Legacy | SayRoute |
| --- | --- | --- |
| App / executable | Doubao Murmur | SayRoute |
| Bundle ID | com.doubao.murmur | com.devonkong.sayroute |
| Remote executable | murmur-mirror | sayroute-bridge |
| LaunchAgent | com.doubao.murmur.mirror | com.devonkong.sayroute.bridge |
| Updater | murmur-updater | sayroute-updater |
| Support directory | ~/Library/Application Support/Doubao Murmur | ~/Library/Application Support/SayRoute |
| Bridge logs | ~/Library/Logs/Doubao Murmur | ~/Library/Logs/SayRoute |

## Controller

1. While the old app is still running, copy any needed entries from “最近文字与恢复”. Its encryption key never persists, so quitting makes those drafts unrecoverable.
2. Quit the old app, including any test copy. Keep its app bundle for rollback. SayRoute refuses startup if it detects a running old app or another SayRoute instance, rather than killing it and losing drafts.
3. Install `SayRoute.app` in Applications and grant it Accessibility in System Settings → Privacy & Security. If an existing permission entry is stale, remove that specific entry and re-add the installed app. No TCC database edits are performed.
4. The first successful startup imports only valid `uuRemotePasteMode`, `overlayPositionMode`, and `pasteQuietPeriodSeconds` from `com.doubao.murmur`. Existing SayRoute values win. Other domains, including test builds, are not imported. The migration marker prevents replay even if a setting is later reset.
5. Verify all three menu settings and a short local dictation before enabling remote use.

Legacy preferences and support/log files remain untouched. New logs use a separate directory. Copying a live SQLite/WAL database would risk inconsistent history and is unnecessary for operating the new app, so this migration intentionally keeps old diagnostics as an archive rather than copying them. Old encrypted drafts are not migrated.

For controller rollback: quit SayRoute, then reopen the retained Doubao Murmur app. Its own preferences and support files are still present. Do not run both apps together.

## Controlled Mac / bridge

Run the new package's `install.command` **on the controlled Mac**. It validates the package first, acquires an installation lock, snapshots existing helper/plists and active-service state, stops both known services, retires the legacy LaunchAgent, and installs the new bridge. The old helper binary and logs stay in their old directory.

The new listener must report the expected service ID, build, protocol and the PID belonging to the new LaunchAgent. A reply from an old listener cannot count as success. Installation failures trigger restoration of previous files and originally active services; backups remain under `~/Library/Application Support/SayRoute/backups/`.

The installer prints the exact rollback command:

```bash
/path/to/unpacked-package/rollback.command '/exact/backup/directory/from-installer'
```

Do not substitute a guessed backup path. Rollback refuses already-restored or superseded transactions, even if the later binary is identical, and refuses to replace files changed since that successful installation. Roll back multiple installations in reverse order. If power loss interrupted installation, keep the printed backup, inspect service state, and remove a stale `.install-lock` directory only after confirming no installer is running; then run rollback with that backup. Backups and previous binaries are never automatically purged.

Grant Accessibility to the **new remote executable path**, then run `verify.command`. Old permissions do not transfer. A successful health check without Accessibility is an installed service, not a passing fast-paste acceptance test. The old and new protocol remain version 2 on port 17771; no UU mapping change is required.

## Updating and GitHub

The new update checker targets `devon-kong/sayroute` and assets named `SayRoute-v<version>.zip`. Automatic updates require the same bundle ID and trusted publisher; they do not migrate an old identity to a new one. Current ad-hoc builds require manual installation. Old releases remain historical, with their original names and checksums.

The repository is now named `devon-kong/sayroute`. Source delivery and release publication are separate steps: the default branch contains the migration, while release publication remains a separate action. The operator confirmed the normal local, UU compatibility and UU fast flows on 2026-10-27; detailed coverage is recorded in [acceptance status](sayroute-acceptance.md). GitHub About: **Native macOS dictation companion for local and remote Macs via NetEase UU. Requires the installed Doubao Input Method.**

## 中文要点

- 退出旧应用前先取回恢复文字；加密密钥不落盘，不能跨重启迁移。
- 只迁移三项有效设置，新设置优先，旧偏好和目录不删不覆盖；测试版偏好不自动导入。
- 新旧应用不能同时监听热键。回退时退出 SayRoute，再打开保留的旧 App。
- Bridge 安装器先核验再备份、停服务和切换；失败自动恢复。手动回退使用安装器打印的准确备份目录，拒绝覆盖之后的新安装。
- 控制端 App 和被控端 Bridge 均须重新授予辅助功能权限；不修改系统权限数据库。
- 新版构建、真实输入验收、GitHub 仓库更名与发布分别记录，不能互相替代。

## Legacy naming policy

Active targets, binaries, test fixtures and diagnostic messages use SayRoute / Bridge. The bridge's developer-only fault-injection variables use the `SAYROUTE_BRIDGE_TEST_` prefix. Old names remain only where they identify the original project or an actual legacy installation: MIT attribution, historical documentation/releases, the one-time preference import, the competing-app guard, and installer handover/rollback fixtures. Do not replace those identity strings: doing so would break legacy detection or migration.

Local legacy release packages and validation evidence may be archived outside the active checkout. Generated build caches can be regenerated; preserve installation/rollback records before retiring a worktree. The existing default branch is `master`.
