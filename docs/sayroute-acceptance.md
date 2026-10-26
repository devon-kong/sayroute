# SayRoute 1.4.0 acceptance / 验收状态

Candidate: controller build21, bridge build20. This document records the rebrand's evidence separately from earlier Doubao Murmur acceptance.

| Gate | Status | Evidence / next action |
| --- | --- | --- |
| Baseline | PASS | 124 hostless tests at d7b32c7 |
| Migrated Swift tests | PASS | 128 tests, including validated one-time preferences, 0 failures |
| Bridge installer transactions | PASS (simulated OS boundaries) | 6 isolated scenarios: handover, startup failure, wrong health, explicit rollback, stale failed-backup rejection, ordered generation rollback |
| Universal app/bridge + signatures/archives | PASS | arm64 + x86_64 builds; app deep/strict signature, extracted app diff, extracted bridge strict signature; candidate archives in dist/ |
| Bridge health and invalid request | PASS | Isolated loopback port: expected service/build/PID; 404 unknown endpoint, 400 malformed paste/clipboard, 415 invalid content type; no clipboard writes/key injection |
| Local actual dictation | Deferred by user | Grant new app Accessibility; test short/long/continuous text and cancel |
| UU compatibility actual dictation | Deferred by user | Connected controlled Mac; check current text and latency |
| UU fast actual dictation | Deferred by user | Install new bridge, grant permission, test long/continuous text, Delete/Space/A and left/right Command |
| Disconnection/failure UI | Pending | Confirm recoverable text, unknown receipt warning and no automatic retry |
| Stable release | Not published | Source delivery and repository rename do not replace real-input acceptance; no 1.4.0 release tag yet |

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

Independent review identified a stale failed-install backup rollback defect. A failing regression reproduced it; transaction generation/consumption checks fixed it. Six installer scenarios passed, and read-only re-review closed the finding. Real dictation acceptance was explicitly deferred by the user until after receiving candidate packages.
