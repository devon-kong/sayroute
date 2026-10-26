# SayRoute identity migration implementation plan

> Execute inline using superpowers:executing-plans. User authorized direct implementation and selected the attached black route mark. Do not commit or push before explicit confirmation under the workspace CLAUDE.md.

**Goal:** Deliver a reversible SayRoute rebrand, preserving the existing three dictation routes and upstream MIT attribution.

**Architecture:** Rename the application, helper and updater identities together. Copy only validated legacy preferences once; retain legacy support data in place instead of moving live SQLite files or unrecoverable encrypted drafts. The bridge installer backs up and retires the legacy LaunchAgent, with explicit rollback.

**Tech stack:** Swift/AppKit, SwiftPM tests, XcodeGen, zsh packaging, macOS 13+.

**Spec:** User request, supplied migration checklist, and selected mark at `docs/brand/sayroute-reference.png`.

## Constraints and decisions

- SayRoute.app / com.devonkong.sayroute; sayroute-bridge / com.devonkong.sayroute.bridge; sayroute-updater.
- Keep Doubao IME input-source identifiers and UU protocol version/port unchanged.
- Version 1.4.0, controller build21, bridge build20. These are candidates until acceptance and publication.
- New identity requires new Accessibility grants. Never change the TCC database.
- Keep old preferences, log databases and application files for rollback. Encrypted draft keys do not survive exit: instruct users to copy needed drafts before switching.
- README.md English first, README.zh-CN.md Chinese, shared actual UI screenshot with honest captions. Preserve LICENSE and add attribution based on Git history.
- Supplied logo is authoritative; monochrome mark for small app/menu icons, full supplied wordmark for documentation.
- Existing clean release packaging stays strict; an explicit local candidate mode may package a dirty tree with manifest provenance, separate names, and no release eligibility.

## Review focus

1. Existing SayRoute preferences must win; malformed legacy values must not migrate.
2. Legacy app running must prevent competing global hotkeys; old drafts must not be erased.
3. Bridge migration must not leave two LaunchAgents on port 17771; failures must restore prior files/service.
4. A health reply from an unrelated/old listener is not proof that the new bridge started.
5. Old app identity must never be accepted as an in-place SayRoute update.

## Tasks

- [x] Identity and preferences: write failing migration tests; implement one-time validated settings import and startup conflict guard; rename build targets, source folders, updater paths and release assets. Run Swift tests.
- [x] Bridge installation: implement reversible legacy-service handover, identity-aware verification and rollback command; test installer in an isolated fixture environment with simulated OS boundaries.
- [x] Branding/docs: create high-resolution faithful icon assets; embed app/menu icons; write English/Chinese README, attribution, migration and acceptance docs; prepare exact GitHub About text.
- [x] Verification: run full hostless suite, universal app/bridge builds, signature/archive checks, isolated health/invalid-request checks; review full diff independently. Record real dictation and permission gates as pending unless actually observed.
- [ ] Delivery: present local artifacts and outstanding real-input acceptance; request commit/push/repository metadata changes only after concrete reviewable results exist.

## Progress

- Baseline at d7b32c7: 124 hostless tests passed, 0 failures; current official version 1.3.1 controller20/bridge19.
- Ruling: use an isolated worktree and leave commits unpublished; existing workspace rules override skill auto-commit instructions.

- Implementation: 128 Swift tests passed; six installer fixture scenarios passed. Universal candidate archives built and extracted signature checks passed. New bridge identity/health and malformed requests verified without clipboard/key effects.
- Ruling: archive old diagnostics in place rather than copy SQLite/WAL files; encrypted drafts are not restorable after exit. README labels the retained screenshot as preceding-release evidence.
- Ruling: release packaging keeps clean-tree enforcement; explicit local-only --candidate creates separately named artifacts and source manifests without committing.
- Review: independent read-only review completed; stale failed-backup replay defect reproduced, fixed and re-reviewed. Six installer scenarios pass. User explicitly deferred real-input acceptance until after candidate handoff. User explicitly authorized commit, push, repository rename and About update. Stable release remains gated by deferred real-input acceptance.

- Packaging includes original LICENSE and ATTRIBUTION.md in both application resources and bridge archive. No copyright notice removed.

- Delivery authorization: user approved commit/push and GitHub rename/About update. Default branch is master; the migration is delivered by a fast-forward push without rewriting history. Real-input acceptance remains deferred, and no release tag is created.
