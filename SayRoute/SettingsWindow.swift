import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general = "通用"
    case devices = "设备与端口"
}

@MainActor
private final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let navigation = SettingsNavigation()
    private let manager: HotkeyManager
    private var window: NSWindow?

    init(manager: HotkeyManager) { self.manager = manager }

    func show(_ pane: SettingsPane) {
        navigation.pane = pane
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "SayRoute 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 580, height: 420)
            window.contentView = NSHostingView(rootView: SettingsContent(navigation: navigation, manager: manager))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

@MainActor
private struct SettingsContent: View {
    @ObservedObject var navigation: SettingsNavigation
    @StateObject private var devices = UUDeviceSettingsModel()
    let manager: HotkeyManager

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置页面", selection: $navigation.pane) {
                ForEach(SettingsPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .padding(.vertical, 14)
            Divider()
            switch navigation.pane {
            case .general:
                GeneralSettings(manager: manager)
            case .devices:
                UUDeviceSettingsView(model: devices)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct GeneralSettings: View {
    let manager: HotkeyManager
    @ObservedObject private var appState = AppState.shared
    @AppStorage(PasteRoutingSettings.uuPasteModeDefaultsKey) private var mode: UUPasteMode = .compatibility
    @AppStorage(OverlayPlacementSettings.defaultsKey) private var position: OverlayPositionMode = .followMouse
    @State private var delay = String(format: "%g", PasteHelper.remoteSyncQuietPeriod)
    @State private var delayError = false
    @FocusState private var editingDelay: Bool
    @State private var imeReady = false
    @State private var trusted = false
    @State private var ready = false

    var body: some View {
        Form {
            Section("本机状态") {
                LabeledContent("辅助功能") {
                    if trusted { status("已授权", ready: true) }
                    else {
                        Button("打开辅助功能设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                LabeledContent("全局快捷键") {
                    status(ready ? "监听中" : "未监听", ready: ready)
                    if !ready {
                        Button("重新启用监听") {
                            manager.retryListener()
                            refreshStatus()
                        }
                        .disabled(appState.recordingState != .idle)
                    }
                }
                LabeledContent("豆包输入法") {
                    status(imeReady ? "已启用" : "未检测到", ready: imeReady)
                    if !imeReady {
                        Button("重新检查") { imeReady = InputSourceManager().isDoubaoAvailable }
                    }
                }
            }
            Section("听写快捷键") {
                HotkeySettingsView(manager: manager)
                    .disabled(appState.recordingState != .idle)
            }
            Section("输入与粘贴") {
                Picker("输入框位置", selection: $position) {
                    ForEach(OverlayPositionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("UU 粘贴方式", selection: $mode) {
                    ForEach(UUPasteMode.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                }
                if mode == .compatibility {
                    LabeledContent("剪贴板稳定时间") {
                        TextField("秒", text: $delay)
                            .labelsHidden().accessibilityLabel("剪贴板稳定时间（秒）")
                            .multilineTextAlignment(.trailing).frame(width: 64)
                            .focused($editingDelay).onSubmit(commitDelay)
                            .onChange(of: editingDelay) { if !$0 { commitDelay() } }
                        Text("秒")
                    }
                    if delayError { Text("请输入 0.1 到 10 之间的秒数。").foregroundColor(.orange) }
                }
            }
            Text("SayRoute \(Self.version)").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXIsProcessTrusted()
            ready = manager.isListenerReady
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .onDisappear { commitDelay() }
    }

    private func refreshStatus() {
        trusted = AXIsProcessTrusted()
        ready = manager.isListenerReady
        imeReady = InputSourceManager().isDoubaoAvailable
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "–")（build \(info["CFBundleVersion"] as? String ?? "–")）"
    }

    private func commitDelay() {
        guard let value = Double(delay.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              (PasteHelper.minimumQuietPeriod...PasteHelper.maximumQuietPeriod).contains(value) else {
            delayError = true
            return
        }
        delayError = false
        PasteHelper.setQuietPeriod(value)
        delay = String(format: "%g", value)
    }

    private func status(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ready ? Color.secondary : Color.orange)
    }
}
