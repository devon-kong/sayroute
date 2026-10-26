// Documentation renderer: actual production views, sample state, no screen capture.
import AppKit
import SwiftUI

final class SampleStorage: RecoveryTextStorage {
    var values: [UUID: String] = [:]
    func write(_ text: String, id: UUID) throws { values[id] = text }
    func read(id: UUID) throws -> String { values[id] ?? "" }
    func remove(id: UUID) throws { values.removeValue(forKey: id) }
    func close() { values.removeAll() }
}

@MainActor
func settle(_ view: NSView) {
    for _ in 0..<6 {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

@MainActor
func save(_ view: NSView, to path: String) throws {
    settle(view)
    let bounds = view.bounds
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
        pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = bounds.size
    view.cacheDisplay(in: bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Saved \(path) (\(bitmap.pixelsWide) × \(bitmap.pixelsHigh))")
}

@MainActor
func textClient(in view: NSView) -> IMETrackingTextView? {
    if let client = view as? IMETrackingTextView { return client }
    return view.subviews.lazy.compactMap { textClient(in: $0) }.first
}

try MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/visuals"
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = NSAppearance(named: appearanceName)!
        app.appearance = appearance
        let state = AppState()
        state.recordingState = .stopping
        state.isWaitingForCommit = true
        let panel = OverlayPanel(appState: state)
        panel.appearance = appearance
        panel.beginTracking(sessionID: UUID())
        let overlay = panel.contentView!
        settle(overlay)
        guard let client = textClient(in: overlay) else { fatalError("Production IME view did not mount") }
        client.string = "在这里说，在目标位置输入。Speak here. Type there."
        state.transcriptionText = client.string
        try save(overlay, to: output + "/sayroute-overlay-\(suffix).png")
        panel.orderOut(nil)

        let fixedDate = Date(timeIntervalSince1970: 1_782_000_000)
        let store = SessionDraftStore(storage: SampleStorage(), now: { fixedDate })
        let first = UUID(), second = UUID()
        store.begin(id: first, route: .local)
        store.markAwaitingDelivery(id: first, text: "在这里说，在目标位置输入。\nSpeak here. Type there.")
        store.finish(id: first, outcome: .eventPosted)
        store.begin(id: second, route: .uuDirect)
        store.markAwaitingDelivery(id: second, text: "这是一段演示文字。连接中断时，先检查目标输入框，再决定是否手动复制。")
        store.finish(id: second, outcome: .unknown(.transportUnknown))
        let presentation = RecoveryTextPresentation()
        for entry in store.visibleEntries { presentation.load(id: entry.id, from: store) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "最近文字与恢复"
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecoveryListView(store: store, presentation: presentation))
        // Capture the native frame view, including the system titlebar. Never show the window.
        let frame = window.contentView!.superview!
        try save(frame, to: output + "/sayroute-recovery-\(suffix).png")
        window.orderOut(nil)
        presentation.close()
    }
}
