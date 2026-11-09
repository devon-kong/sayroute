# SayRoute app icon

- `sayroute-icon-master.png`: original brand mark; preserved unchanged.
- `sayroute-icon-native.png`: generated 1024×1024 transparent macOS icon.
- `../../SayRoute/Resources/AppIcon.icns`: all ten standard 16–1024 px representations.

The native icon keeps the original mark's shape, size, and placement. A near-white vertical gradient, thin lower rim, inset highlight, and two neutral soft shadows give the white tile definition in Finder's white Applications view. Outer margins are transparent, not painted white. The tile and shadow are rendered deterministically rather than using generative-image alpha edges.

## Regenerate and validate

On macOS with Python 3 and Pillow:

```sh
python3 scripts/generate-app-icon.py
python3 scripts/test-app-icon.py
```

Run from the repository root. The renderer does not change the original master. The tests validate canonical image equality, clean transparent borders, shading, shadow alpha, and all ten ICNS representations.

The app's `CFBundleIconFile` remains `AppIcon`; the same icon is packaged for Finder, Dock, and the DMG. Rebuild and reinstall the app after regenerating. If Finder retains the old icon, quit the app and refresh its bundle timestamp / Launch Services registration; no system-wide icon-cache purge is necessary.
