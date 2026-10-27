# SayRoute 1.4.0 acceptance / 验收状态

Candidate: controller build21, bridge build20. This document records the rebrand's evidence separately from earlier Doubao Murmur acceptance.

| Gate | Status | Evidence / next action |
| --- | --- | --- |
| Baseline | PASS | 124 hostless tests at d7b32c7 |
| Migrated Swift tests | PASS | 128 tests, including validated one-time preferences, 0 failures |
| Bridge installer transactions | PASS (simulated OS boundaries) | 6 isolated scenarios: handover, startup failure, wrong health, explicit rollback, stale failed-backup rejection, ordered generation rollback |
| Universal app/bridge + signatures/archives | PASS | arm64 + x86_64 builds; app deep/strict signature, extracted app diff, extracted bridge strict signature; candidate archives in dist/ |
| Bridge health and invalid request | PASS | Isolated loopback port: expected service/build/PID; 404 unknown endpoint, 400 malformed paste/clipboard, 415 invalid content type; no clipboard writes/key injection |
| Local actual dictation | PASS (operator-reported, 2026-10-27) | User confirmed actual speech testing with no issues; detailed text samples and session counts were not recorded |
| UU compatibility actual dictation | PASS (operator-reported, 2026-10-27) | User confirmed no issues in response to the three-route acceptance question |
| UU fast actual dictation | PASS (operator-reported, 2026-10-27) | User confirmed no issues in response to the question covering fast dictation and Delete/Space/A plus both Command keys |
| Disconnection/failure UI | Pending | Confirm recoverable text, unknown receipt warning and no automatic retry |
| Source acceptance | PASS (operator-reported, 2026-10-27) | User reconfirmed testing with no issues and authorized primary-branch delivery and remote push |
| Stable release | Not published | The published download is v1.4.0-rc.1; stable release publication is separate from this source cleanup |

## Real-input acceptance checklist

Use a disposable blank editor on each machine, with no unsaved user material. Record machine/OS versions, bundle paths/builds, permission status, target editor, expected text, actual text and result for each route. Verify:

- Short phrase, long paragraph, three consecutive sessions: exact complete text, once each.
- Repeated start hotkey is ignored while recording; physical right Command stops; Escape cancels without paste.
- After fast paste: Delete removes one character, Space inserts a space, A inserts a character; left and right Command shortcuts work normally with no stuck modifiers.
- Clipboard delay variation in compatibility mode never gets represented as a guaranteed synchronization ACK.
- Bridge or mapping unavailable: show actionable failure/recovery. On uncertain ACK, inspect target and do not retry blindly.
- New-user installation, legacy preference import, new preference preservation, app conflict guard, bridge rollback and both new Accessibility grants.

Do not mark a route passed based on construction tests, HTTP ACK, `eventPosted`, or a prior product version's results. The operator must speak and press the physical stop key for the real dictation path; synthetic protocol tests cannot substitute for that gesture.

## Automated evidence location

Local build logs: `/tmp/sayroute-app-build.log`, `/tmp/sayroute-bridge-build.log`; Swift tests `/tmp/sayroute-tests.log`; installer transactions `/tmp/sayroute-installer-tests.log`. Durable copies will accompany the local handoff under `dist/validation/`. `bridge-health-result.json` records the isolated health check. Its Accessibility result belongs to that temporary local process and does not establish permission on the controlled Mac.

Independent review identified a stale failed-install backup rollback defect. A failing regression reproduced it; transaction generation/consumption checks fixed it. Six installer scenarios passed, and read-only re-review closed the finding. Real dictation acceptance was initially deferred until after receiving candidate packages; the operator subsequently confirmed the normal flows on 2026-10-27, as recorded below.

## Installed two-Mac acceptance — 2026-10-27

- Controller: macOS 15.5 (24F74), arm64; installed `/Applications/SayRoute.app`, version 1.4.0 build21. Signature verified and Accessibility shown enabled. Legacy preferences imported as compatibility mode and 0.25 seconds; the current setting at acceptance was fast mode (`direct`).
- Controlled Mac: macOS 27.0 (26A425), arm64; published bridge build20 installed after checksum/signature verification. Health through the existing UU mapping confirmed service `com.devonkong.sayroute.bridge`, protocol 2, `ok=true`, and `accessibilityTrusted=true`.
- Legacy `murmur-mirror`: no running process or loaded legacy service; installed executable archived into the installation backup and legacy LaunchAgent absent. Historical logs/backups retained. The old Accessibility entry was not inspected or removed.
- Operator evidence: after reporting actual speech tests already performed, the user answered “测试了，没问题” to a question explicitly covering local / UU compatibility / UU fast and the post-paste Delete, Space, A, left/right Command checks. These normal-flow results are operator-reported, not independently observed end-to-end by the agent.
- Remaining coverage: short/long text and three-session counts, repeated-start handling, Escape cancellation, disconnected/uncertain-ACK recovery, and real-machine rollback were not individually confirmed in this session. Do not infer exhaustive regression coverage or publish a stable release from this report alone.
- Local installation and rollback details: `dist/validation/two-mac-acceptance-20261027.md`. After the requested legacy uninstall, restore the archived legacy executable to its original location before using the package rollback command.
