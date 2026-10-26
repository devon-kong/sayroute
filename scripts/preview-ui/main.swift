// Documentation-only UI fixture. Uses production views, with sample text.
// No AppDelegate, global hotkeys, input-source switch, network, or paste delivery.
import AppKit
import SwiftUI

final class PreviewStorage: RecoveryTextStorage {
    var values: [UUID: String] = [:]
    func write(_ text: String, id: UUID) throws { values[id] = text }
    func read(id: UUID) throws -> String { values[id] ?? "" }
    func remove(id: UUID) throws { values.removeValue(forKey: id) }
    func close() { values.removeAll() }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    var recovery: RecoveryWindowController?
    var state: AppState?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show recovery", action: #selector(showRecovery), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: "Quit preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; NSApp.mainMenu = menu
        let state = AppState(); self.state = state
        state.recordingState = .stopping
        state.transcriptionText = "在这里说，在目标位置输入。\nSpeak here. Type there."
        state.isWaitingForCommit = true
        let client = IMETrackingTextView(frame: .zero)
        client.beginTracking(sessionID: UUID())
        client.string = state.transcriptionText
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 112),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = false; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: OverlayView(appState: state, textView: client,
            onCopyCurrentText: {}, onTextViewReady: { _ in }))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true
        panel.center(); panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showRecovery() {
        panel?.orderOut(nil)
        let store = SessionDraftStore(storage: PreviewStorage())
        let first = UUID(), second = UUID()
        store.begin(id: first, route: .local)
        store.markAwaitingDelivery(id: first, text: "SayRoute 把已经确认的文字送到目标输入框。\nSpeak here. Type there.")
        store.finish(id: first, outcome: .eventPosted)
        store.begin(id: second, route: .uuDirect)
        store.markAwaitingDelivery(id: second, text: "这是一段演示文字：远程连接暂时不可用时，可以从这里复制，避免重新听写。")
        store.finish(id: second, outcome: .notSent(.connectionUnavailable))
        let controller = RecoveryWindowController(store: store)
        recovery = controller; controller.show()
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PreviewDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
