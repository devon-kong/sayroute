# SayRoute 1.4.0 — migration candidate

SayRoute renames the macOS dictation companion previously called Doubao Murmur. Controller: **1.4.0 (21)**. SayRoute Bridge: **1.4.0 (20)**. This is a candidate until [acceptance](sayroute-acceptance.md) is complete.

- New app, bundle, bridge/updater identities and selected monochrome brand mark.
- One-time validated import of three preferences; old data is retained for rollback.
- Prevent competing app hotkey listeners; explain that session-only encrypted drafts must be copied before quitting.
- Bridge installation backs up previous state, retires the legacy LaunchAgent, validates the new listener and rolls back failures. Explicit rollback is included.
- English-first README and Chinese counterpart, with preserved MIT attribution and an explicit installed-Doubao-IME requirement.

The dictation/commit/paste state machine remains the same. No new ASR provider, authentication, notarization or cross-session draft recovery is claimed. Packages are ad-hoc signed and need manual installation and fresh Accessibility grants.

Read the [migration guide](sayroute-migration.md) before replacing the old application or installing the bridge. Old releases remain historical and retain their original filenames. Candidate packages are not stable-release artifacts.

中文：本版是完整品牌迁移候选，不代表真实双机验收已完成。旧配置保留；新应用和 Bridge 需重新授权；退出前先复制需要保留的恢复文字。详见迁移与验收文档。
