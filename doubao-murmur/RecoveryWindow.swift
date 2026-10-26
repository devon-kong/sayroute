import AppKit
import SwiftUI

/// Transient display text belongs to the open window, never the history index.
@MainActor
final class RecoveryTextPresentation: ObservableObject {
    @Published private(set) var textByID: [UUID: String] = [:]
    @Published private(set) var failedIDs: Set<UUID> = []
    private var isOpen = true

    func load(id: UUID, from store: SessionDraftStore, retry: Bool = false) {
        guard isOpen, retry || (textByID[id] == nil && !failedIDs.contains(id)) else { return }
        if let text = store.readText(id: id) {
            textByID[id] = text
            failedIDs.remove(id)
        } else {
            textByID.removeValue(forKey: id)
            failedIDs.insert(id)
        }
    }
    func unload(id: UUID) {
        textByID.removeValue(forKey: id)
        failedIDs.remove(id)
    }
    func close() {
        isOpen = false
        textByID.removeAll()
        failedIDs.removeAll()
    }
}

@MainActor
final class RecoveryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var presentation: RecoveryTextPresentation?
    private let store: SessionDraftStore
    init(store: SessionDraftStore) { self.store = store; super.init() }

    func show() {
        store.markFailuresViewed()
        if window == nil {
            let text = RecoveryTextPresentation()
            presentation = text
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "最近文字与恢复"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 460, height: 300)
            window.contentView = NSHostingView(rootView: RecoveryListView(store: store, presentation: text))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        presentation?.close()
        window?.contentView = nil
        window = nil
        presentation = nil
    }
}

private struct RecoveryListView: View {
    @ObservedObject var store: SessionDraftStore
    @ObservedObject var presentation: RecoveryTextPresentation
    @State private var copyMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文字按需从加密临时文件读取，退出或重启后不恢复。")
                .font(.callout).foregroundColor(.secondary)
            Text("最多20条、最长3天。打开窗口清除已有提醒，失败状态和记录仍保留。")
                .font(.caption).foregroundColor(.secondary)
            if store.visibleEntries.isEmpty {
                Spacer()
                Text("暂无可恢复的文字").frame(maxWidth: .infinity).foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(store.visibleEntries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(entry.createdAt, style: .time).font(.caption)
                                    Text(routeLabel(entry.route)).font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Button("复制") {
                                        copyMessage = store.copy(id: entry.id, using: PasteHelper.copyOnly)
                                            ? "已复制，记录仍保留。" : "复制失败，请重试读取或检查剪贴板。"
                                    }.disabled(entry.textLength == 0)
                                    Button("删除", role: .destructive) { store.discard(id: entry.id) }
                                }
                                Text(entry.delivery.label).font(.callout)
                                    .foregroundColor(entry.delivery.needsRecovery ? .orange : .secondary)
                                if !entry.committed {
                                    Text("尚未确认完成，请核对后使用。")
                                        .font(.caption).foregroundColor(.orange)
                                }
                                if let text = presentation.textByID[entry.id] {
                                    Text(text).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else if presentation.failedIDs.contains(entry.id) {
                                    Button("无法读取文字，点击重试") {
                                        presentation.load(id: entry.id, from: store, retry: true)
                                    }
                                } else {
                                    Text("正在读取…").foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)
                            .onAppear { presentation.load(id: entry.id, from: store) }
                            .onDisappear { presentation.unload(id: entry.id) }
                        }
                    }
                }
            }
            if let storageError = store.storageError {
                Text(storageError).font(.caption).foregroundColor(.orange)
            }
            Text(copyMessage).font(.caption).foregroundColor(.secondary)
                .accessibilityLabel(copyMessage)
        }
        .padding(18)
    }

    private func routeLabel(_ route: PasteRoute) -> String {
        switch route {
        case .local: return "本机"
        case .uuCompatibility: return "UU 兼容模式"
        case .uuDirect: return "UU 快速模式"
        }
    }
}

/// A recording owns the shared session anchor. Keep only the newest notice
/// while it is busy; viewing/dismissing never changes a record's failure status.
struct RecoveryNoticeState {
    private var notice: RecoveryNotice?
    private var busy = false
    var visibleNotice: RecoveryNotice? { busy ? nil : notice }
    mutating func receive(_ value: RecoveryNotice) { notice = value }
    mutating func setBusy(_ value: Bool) { busy = value }
    mutating func dismiss() { notice = nil }
}

struct RecoveryNoticeView: View {
    let message: String
    var width: CGFloat = 420
    let onViewRecords: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange).font(.system(size: 20))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近文字与恢复").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                    .help("关闭提示").accessibilityLabel("关闭提示")
                }
                Text(message).font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button("查看记录", action: onViewRecords)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 16, style: .circular)
            .fill(.ultraThinMaterial).opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .circular)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Does not activate the app or take key focus. Only the explicit records action
/// opens a normal window; the notice itself never reads or copies dictation text.
@MainActor
final class RecoveryNoticePanel: NSPanel {
    private var dismissal: DispatchWorkItem?
    private var state = RecoveryNoticeState()
    var onViewRecords: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    @objc private func displayConfigurationChanged() {
        guard isVisible else { return }
        layoutNotice()
    }
    func present(_ notice: RecoveryNotice) {
        state.receive(notice)
        refresh()
    }
    func setRecordingBusy(_ busy: Bool) {
        state.setBusy(busy)
        refresh()
    }
    func dismissNotice() {
        state.dismiss()
        dismissal?.cancel()
        dismissal = nil
        orderOut(nil)
    }
    private func refresh() {
        dismissal?.cancel()
        guard let notice = state.visibleNotice else { orderOut(nil); return }
        layoutNotice(notice)
        orderFrontRegardless()
        let item = DispatchWorkItem { [weak self] in self?.dismissNotice() }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }
    private func layoutNotice(_ value: RecoveryNotice? = nil) {
        guard let notice = value ?? state.visibleNotice else { return }
        let displays = OverlayDisplay.current
        let width = notice.placement.frame(height: 140, displays: displays).width
        let host = NSHostingView(rootView: RecoveryNoticeView(message: notice.message, width: width,
            onViewRecords: { [weak self] in
                self?.dismissNotice()
                self?.onViewRecords?()
            }, onDismiss: { [weak self] in self?.dismissNotice() }))
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        contentView = host
        setFrame(notice.placement.frame(height: host.fittingSize.height, displays: displays), display: true)
    }
}
