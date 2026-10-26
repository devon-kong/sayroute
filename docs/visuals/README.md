# Native README visuals

These PNGs render the application's existing SwiftUI/AppKit components with sample state. The controls, fonts, colors, materials and layouts are supplied by production code and macOS, not manually redrawn. README explanations sit outside the images.

## Regenerate

From the repository root on macOS with Xcode:

```bash
scripts/render-native-visuals.sh
```

The script compiles the current application sources without `SayRouteApp.swift`. A documentation-only entry point creates hidden native windows and uses `NSView.cacheDisplay` at 2× resolution. No screen capture, visible window, global hotkey listener, input-source switch, network request or paste delivery is involved. Recovery entries use an in-memory sample store. The overlay's unmodified AppState creates and closes its normal process-scoped empty recovery cache.

`RecoveryListView` is private in its source file. The build script copies that file into a temporary build directory and changes only the view's access declaration, leaving its body unchanged. Application source files are never edited by the renderer.

## Production components

- `OverlayPanel` creates the panel and its unmodified `OverlayView` / `IMETrackingTextView`; only the sample text and waiting state are supplied.
- `RecoveryListView` and `RecoveryTextPresentation` render the recovery records using `SessionDraftStore` and real `PasteOutcome` values.
- The recovery frame uses the same native NSWindow dimensions, style mask and title as `RecoveryWindowController`.

Both `.aqua` and `.darkAqua` appearances are rendered. HTML picture sources select the appropriate version in each README. Windows are unfocused because rendering is offscreen, so native titlebar buttons are inactive. System materials naturally depend on appearance, OS version and the backdrop; these files use a neutral offscreen environment. They document native UI styling, not a real dictation acceptance session.

Files:

- `sayroute-overlay-light.png` / `sayroute-overlay-dark.png`
- `sayroute-recovery-light.png` / `sayroute-recovery-dark.png`
