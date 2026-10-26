<p align="center"><img src="docs/brand/sayroute-reference.png" width="126" alt="SayRoute logo"></p>

# SayRoute

**Speak here. Type there.**

A native macOS dictation companion that delivers confirmed text to your local app or a remote Mac through NetEase UU Remote. SayRoute currently drives the **installed Doubao Input Method**; it is not a standalone speech-recognition engine or an official Doubao integration.

**English** · [简体中文](README.zh-CN.md)

> **1.4.0 RC 1:** controller build21 and SayRoute Bridge build20. [Download the SayRoute preview](https://github.com/devon-kong/sayroute/releases/tag/v1.4.0-rc.1). Real-input acceptance is pending; this is a prerelease. See [acceptance status](docs/sayroute-acceptance.md). The previous release was Doubao Murmur 1.3.1.

<p align="center"><img src="docs/visuals/sayroute-interface.png" width="1000" alt="SayRoute interface illustration showing dictation, recovery records and three delivery routes"></p>
<p align="center"><em>Code-rendered illustration of the current dictation and recovery UI, with sample text. The app interface currently uses Chinese.</em></p>

## What it does

- Captures your target app, waits for the input method to commit its text, then restores the target and delivers it.
- Routes each session through local paste, UU clipboard synchronization, or a bridge on the controlled Mac.
- Keeps recoverable text when a session times out or delivery fails; an uncertain delivery is never automatically retried.
- Places the dictation panel near the pointer or at the top of the screen.

| Route | Best for | Delivery |
| --- | --- | --- |
| Local | Apps on this Mac | Restore target, copy text, post `⌘V` |
| UU compatibility | Remote Mac, without a helper | UU clipboard synchronization plus paste; adjustable settling delay |
| UU fast | Remote Mac with SayRoute Bridge | Send text through a UU port mapping; the remote bridge writes its clipboard and posts `⌘V` |

## Requirements and installation

- macOS 13 or later; Doubao Input Method installed and enabled on the **controller**.
- Accessibility permission for `SayRoute.app`. Fast mode additionally needs a remote Mac, NetEase UU Remote, its port mapping, and Accessibility for `sayroute-bridge` on that Mac.
- Universal builds include Apple Silicon and Intel slices. Runtime acceptance on Intel is not established by compilation.
- Packages use ad-hoc signing and are **not Apple-notarized**. Automatic installation stays disabled for these signatures; update manually using a verified package.

Download [SayRoute 1.4.0 RC 1](https://github.com/devon-kong/sayroute/releases/tag/v1.4.0-rc.1): `SayRoute-v1.4.0-rc.1.zip` for the controller, and `sayroute-bridge-macos-v1.4.0-build20.zip` for the controlled Mac. The preceding v1.3.1 release is a legacy Doubao Murmur build.

Unzip the controller package and place `SayRoute.app` in Applications. If upgrading from Doubao Murmur, **copy any needed recovery text before quitting the old app**, then follow the [migration and rollback guide](docs/sayroute-migration.md). The new bundle identity needs its own Accessibility grant.

For fast mode, install the companion package on the **controlled Mac** using the [bridge guide](packaging/sayroute-bridge/README.md). Keep the service on loopback; configure UU to map controller `127.0.0.1:17771` to controlled Mac `127.0.0.1:17771`.

## Dictate

1. Put the caret in the destination field. For a pointer-following panel, position the pointer nearby.
2. Press `Control + /` once. SayRoute waits for the shortcut to be released, the panel to focus and Doubao IME to become ready, then sends right Command to start dictation.
3. Speak, then **physically press right Command once** to stop Doubao dictation.
4. SayRoute waits for the IME's underlined composition to finish before freezing and delivering the text.

| Key | Action |
| --- | --- |
| `Control + /` while idle | Start |
| `Control + /` while recording | Ignored |
| Physical right Command while recording | Stop gesture |
| `Esc` | Cancel without copying or pasting; restore the previous input source |

The menu offers panel position, UU paste route and clipboard settling time. These three preferences migrate once from the old official app when valid; existing SayRoute preferences win.

## Recovery, privacy and limits

- After a stop gesture, 1.5 seconds triggers a waiting notice. If commitment is still unconfirmed after 15 seconds, or focus/stop handling is interrupted, automatic paste stops and a recoverable draft is retained.
- **Recent text & recovery** (`最近文字与恢复`) holds up to 20 entries for up to three days **within the running session**. Text is encrypted in temporary local files; the key is never persisted. Quitting/restarting loses access to these drafts. Copying does not delete an entry.
- SayRoute does not send text to an ASR API. Doubao Input Method performs recognition and may use its own network services; its privacy terms apply. Fast mode sends text to the configured remote bridge.
- `eventPosted=true` means that a key event was posted. It does **not** prove that the target editor inserted text. For “unknown” results, inspect the destination before trying again to avoid duplicates.
- The bridge has **no authentication or remote target binding**. It is for trusted loopback and UU mappings only. Do not expose it to a LAN or the public internet.
- Diagnostic event databases live under `~/Library/Application Support/SayRoute/`; controller/helper databases record event metadata, not dictated text. Recovery ciphertext is under `~/Library/Caches/SayRoute/RecoverySessions/`. Legacy data stays in its original directories for rollback.

## Build and verify

Use Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
python3 scripts/test-bridge-installer.py
scripts/package-app.sh --candidate
scripts/package-sayroute-bridge.sh --candidate
```

The Python test runner is a development dependency, not an app/installer dependency. Tests use isolated settings and service fixtures; they do not invoke global hotkeys or paste into real apps. Candidate archives include `-candidate` in their names and working-tree provenance. To build release archives from a clean committed tree, omit `--candidate`. CI runs tests and universal packaging; `v*` tags publish only after those jobs succeed. Real dictation acceptance is a separate release gate documented in [acceptance status](docs/sayroute-acceptance.md).

## Origin and license

SayRoute evolved from [lilong7676/doubao-murmur](https://github.com/lilong7676/doubao-murmur). The original copyright and [MIT license](LICENSE) remain. Devon Kong developed the installed-IME session flow, UU routing/bridge, recovery and delivery reliability work; some application, hotkey and update scaffolding derives from the original project. See [attribution and implementation history](ATTRIBUTION.md).

MIT permits commercial use subject to its conditions. Third-party input methods and remote-control software have their own terms. SayRoute is independent of, and not endorsed by, Doubao or NetEase.
