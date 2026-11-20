import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject var manager: HotkeyManager

    var body: some View {
        LabeledContent("开始听写") {
            Text(manager.shortcutTitle)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("当前快捷键，" + manager.shortcutTitle)
        }
        LabeledContent("停止听写", value: "右 Command")
        HStack {
            if manager.interaction == .idle {
                Button("录制快捷键…") { manager.beginShortcutInteraction(.record) }
                Button("测试快捷键") { manager.beginShortcutInteraction(.test) }
                    .disabled(!manager.isListenerReady)
                Spacer()
                Button("恢复默认") { manager.restoreDefaultShortcut() }
                    .disabled(manager.shortcut == .standard)
            } else {
                Text(manager.interaction == .record ? "请按下新的组合键…" : "请按 " + manager.shortcutTitle + " 测试…")
                Spacer()
                Button(manager.interaction == .test ? "结束测试" : "取消") { manager.cancelShortcutInteraction() }
            }
        }
        .disabled(manager.sessionActive)
        .onDisappear { manager.settingsDidClose() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            manager.settingsWindowResigned($0.object as? NSWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            manager.settingsDidClose()
        }
        if let feedback = manager.shortcutFeedback {
            Text(feedback).foregroundStyle(.secondary)
        } else if manager.sessionActive {
            Text("听写结束后可更改或测试快捷键。").foregroundStyle(.secondary)
        } else if manager.interaction == .record {
            Text("可使用 Control、Option 或 Command 搭配字母、数字或标点，也可加 Shift。按 Esc 取消。")
                .foregroundStyle(.secondary)
        } else if manager.interaction == .test {
            Text("测试只检查按键，按 Esc 取消。").foregroundStyle(.secondary)
        }
    }
}
