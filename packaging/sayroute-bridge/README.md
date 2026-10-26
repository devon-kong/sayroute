# SayRoute Bridge

[简体中文](README.zh-CN.md) · Remote helper for SayRoute's UU fast route. Install on the **controlled Mac**; the main app runs on the controller. Current candidate: **1.4.0 (20)**, with controller **1.4.0 (21)**.

1. Copy the entire unzipped package to the controlled Mac. Keep the binary, checksum, scripts, shared script and BUILD-INFO.txt together.
2. Run `install.command`. It validates the package, backs up the existing installation, stops the old service, retires its LaunchAgent, installs SayRoute Bridge and verifies the new process's health. Failure triggers rollback.
3. Grant Accessibility to the installed executable below. A new path/signing identity does not inherit the old helper's permission.
4. Run `verify.command`. Exit 2 means the service is installed but Accessibility still needs attention.
5. In UU, map controller `127.0.0.1:17771` to controlled Mac `127.0.0.1:17771`. Select fast mode in SayRoute and perform real-input acceptance in a blank editor.

```text
Executable:  ~/Library/Application Support/SayRoute/sayroute-bridge
LaunchAgent: ~/Library/LaunchAgents/com.devonkong.sayroute.bridge.plist
Logs:        ~/Library/Logs/SayRoute/
Event DB:    ~/Library/Application Support/SayRoute/paste-orders-helper.sqlite3
Backups:     ~/Library/Application Support/SayRoute/backups/
```

The installer prints the exact backup directory and rollback command. Run `rollback.command '/printed/backup/path'` from Terminal to restore prior files and active-service state. It refuses to overwrite an installation changed after the backup. Legacy helper binaries/logs remain in the Doubao Murmur directory. Do not run old and new services together.

The package is ad-hoc signed, not notarized. The installer does not automatically strip quarantine attributes. If macOS blocks it, verify the checksum/source and follow the system's explicit approval flow before retrying. No administrator access is required for the per-user LaunchAgent.

`diagnose.command` is a bounded, listen-only modifier diagnostic: it records modifier state and selected key classes, not Unicode text or clipboard contents. Use it on the controlled Mac while checking Delete, Space, A and both Command keys. A successful paste event ACK does not prove the editor inserted the text.

The HTTP protocol remains version 2, listening only on loopback. There is no authentication or remote target binding. Never expose it to a LAN/public interface. A mapped connection must be trusted. If installation health fails, inspect logs; do not start a second helper on the same port.

See the repository's migration and acceptance documents before release. This package's automated checks do not replace two-machine input testing.
