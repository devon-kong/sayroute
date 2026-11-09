# macOS application packaging

## Final app build

Requires macOS, Xcode 15+, XcodeGen and a logged-in Finder session. The DMG helper uses only native tools (`hdiutil`, Swift/AppKit, `osascript`, `ditto`, `codesign`). No download, Python package, or third-party DMG utility is required. If macOS requests Automation access, allow the terminal/runner to control Finder. Headless runners without Finder/Automation access fail explicitly; they do not silently emit an unstyled DMG.

After finishing any icon changes, run from the repository root:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/package-app.sh --candidate
```

This builds a universal **Release** app (`arm64 x86_64`), verifies its bundle identity, both executable architectures and ad-hoc signature, then produces these files in `dist/` (example version):

```text
SayRoute-v1.4.0-candidate.zip
SayRoute-v1.4.0-candidate.zip.sha256
SayRoute-v1.4.0-candidate.dmg
SayRoute-v1.4.0-candidate.dmg.sha256
SayRoute-v1.4.0-candidate.build-info.txt
SayRoute-v1.4.0-candidate.sources.sha256
```

The build-info and source manifest describe **both** artifacts with the same basename. The source manifest hashes tracked and non-ignored untracked working-tree source files; ignored `dist/` products are excluded. Candidate names and provenance remain governed by `scripts/package-policy.sh`. For official release packaging, omit `--candidate` and use a clean committed tree. `RELEASE_TAG`, when present, must match the app version (including the existing `-rc.N` policy). Candidate mode is local-only, not a release bypass.

**Keep the ZIP:** the existing in-app updater consumes the ZIP format. The DMG is an additional manual-install artifact, not an updater replacement. The packaging code does not modify the app, generate icons, install the app, sign with a Developer ID, or notarize. Ad-hoc signing does not bypass Gatekeeper; use macOS's normal user-approved Open flow for an unnotarized application. Do not suggest disabling Gatekeeper system-wide.

Verify transport checksums:

```bash
cd dist
shasum -a 256 -c SayRoute-v1.4.0-candidate.zip.sha256
shasum -a 256 -c SayRoute-v1.4.0-candidate.dmg.sha256
```

## Independent DMG build (no application compilation)

Use an already built, validly signed `SayRoute.app`. The output directory must exist. Paths with spaces are supported. The output may be overwritten if it is a regular file; symlink outputs are rejected.

```bash
scripts/create-dmg.sh /absolute/path/to/SayRoute.app "$PWD/dist/SayRoute-preview.dmg"
```

The helper copies the app without changing its icon or bundle contents, creates an HFS+ read-write staging image, asks Finder to persist `.DS_Store`, then converts it to compressed read-only **UDZO**. It verifies the image checksum, remounts the final image read-only, verifies the signature and byte-compares the copied bundle, and checks the `/Applications` symlink and hidden artwork/layout files before copying the result to the requested output. `scripts/verify-dmg-layout.swift` parses the persisted Finder icon-view plist and uses CoreFoundation to resolve the background's Carbon alias to the PNG inside the final mounted image; it also decodes the PNG and verifies 1280×840 pixels. This avoids Finder's unreliable `background picture` getter, which can return `missing value` even when its saved background and alias are valid. The native alias-to-bookmark conversion API emits a deprecation warning on recent macOS, but is intentionally used only to convert Finder's existing Carbon AliasRecord, not to create new aliases. It never launches the app or follows the Applications link to install anything.

The background is generated at 2× resolution by `scripts/render-dmg-background.swift`: neutral light gray, a subtle dashed right arrow, no embedded app icons or text. Finder displays the actual `SayRoute.app` icon on the left and the real Applications symlink on the right. The 640×420 content region uses 96-point icons at `{165,196}` and `{475,196}`. Including labels, the installation group is centered horizontally and vertically rather than sitting in the lower part of the window. Toolbar, sidebar, status bar and path bar are hidden. Nothing changes the user's global Finder defaults. The helper briefly opens only its own staging volume window and closes it before unmounting.

This is a reproducible **build procedure and layout**, not a bit-for-bit reproducible disk image: HFS+/Finder timestamps, volume identifiers, `.DS_Store` metadata, OS rendering and compressed bytes can vary across builds and macOS versions. Every resulting ZIP/DMG has its own SHA-256. Build-info records the packaging macOS version/build; the source manifest includes the artwork renderer and helper.

### Temporary directories and failure handling

Each script creates an exclusive `mktemp` directory, canonicalizes its absolute path and checks both its parent and its script-specific basename before recursive cleanup. Only that exact temporary directory is recursively deleted. Disk images are detached on success and failure; detach failure is reported and the directory is retained for recovery rather than deleting a mounted volume. The helper does not force-detach unrelated disks, remove old artifacts, or clean arbitrary caller-supplied directories. A Finder failure is fatal, and an existing output is not touched until image validation has succeeded.

## Native regression tests

```bash
# Signed, isolated minimal fixture; no full Xcode app build:
scripts/test-dmg.sh

# Optional: verify the same procedure against a real existing app:
scripts/test-dmg.sh /absolute/path/to/SayRoute.app
```

The smoke test builds a real image and checks UDZO format, final read-only remount, app signature and identical contents, the Applications symlink, hidden background/`.DS_Store`, and persisted Finder icon/window/background settings after remount. It covers input/output paths with spaces and rejection of missing apps and symlink output paths. It uses a temporary signed fixture by default and never invokes the app. Run Finder-based tests serially in a logged-in GUI session; do not concurrently drive Finder windows with other automation.

For visual acceptance, mount the final DMG, confirm the gray background and dashed arrow are visible at normal window size with both labels fully visible, drag the app onto Applications if installing, and eject the disk afterward. Package checks do not replace real dictation acceptance. CI's universal app packaging produces both ZIP and DMG and therefore requires a Finder-capable macOS runner; no new publishing behavior is added.
