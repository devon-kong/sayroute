# README interface illustration

`sayroute-interface.png` is a code-rendered illustration with sample text, not a captured desktop or evidence of live dictation. It shows the Chinese interface implemented for SayRoute 1.4.0, with English editorial labels for the default README.

## Regenerate

From the repository root on macOS with the Swift toolchain:

```bash
swift scripts/render-readme-visual.swift
```

The script draws an offscreen bitmap using AppKit. It does not open an application window, record the screen, switch input methods, access the clipboard or connect to the bridge. Output is 2480 × 1580 PNG. No additional packages are required.

## Source mapping

- `SayRoute/OverlayView.swift`: rounded overlay, state dot, 15pt editor text and waiting-for-commit notice.
- `SayRoute/RecoveryWindow.swift`: recovery window labels, route labels, record structure, Copy/Delete controls and retention explanations.
- `SayRoute/SessionDraftStore.swift`: unknown-delivery and posted-event status wording.
- `SayRoute/SayRouteMark.swift`: the selected two-endpoint route mark.
- `SayRoute/PasteRouter.swift`: local, UU compatibility and UU fast routes.

Window materials and page composition are adapted for clean documentation; this is not a pixel-exact screenshot. Check those owning sources when changing the UI, regenerate, and visually inspect the result before committing it. The generated image and captions are shared by both README languages.
