import Combine
import Foundation

/// Closed vocabulary: never attach transcription or an arbitrary NSError string.
enum PasteFailureReason: String, Equatable {
    case missingMarkedText = "missing_marked_text"
    case missingKeyUp = "missing_key_up"
    case commitPending = "commit_pending"
    case focusLost = "focus_lost"
    case stopInterrupted = "stop_interrupted"
    case targetNotFrontmost = "target_not_frontmost"
    case clipboardWriteFailed = "clipboard_write_failed"
    case clipboardUnstable = "clipboard_unstable"
    case eventCreationFailed = "event_creation_failed"
    case superseded = "superseded_before_delivery"
    case connectionUnavailable = "connection_unavailable"
    case remotePermissionDenied = "remote_permission_denied"
    case remoteRejected = "remote_rejected"
    case transportUnknown = "transport_unknown"
    case acknowledgementInvalid = "acknowledgement_invalid"
    case modifiersHeld = "modifiers_held"

    var message: String {
        switch self {
        case .missingMarkedText: return "未观察到输入法提交过程"
        case .missingKeyUp: return "未确认停止键已抬起"
        case .commitPending: return "等待输入法提交超时"
        case .focusLost: return "输入框失去焦点"
        case .stopInterrupted: return "停止手势被其他按键打断"
        case .targetNotFrontmost: return "原目标应用未保持在前台"
        case .clipboardWriteFailed: return "剪贴板写入失败"
        case .clipboardUnstable: return "剪贴板未稳定"
        case .eventCreationFailed: return "无法创建粘贴按键"
        case .superseded: return "上一笔尚未粘贴，已开始新会话"
        case .connectionUnavailable: return "无法连接远端 helper"
        case .remotePermissionDenied: return "远端 helper 缺少辅助功能权限"
        case .remoteRejected: return "远端拒绝了此次请求"
        case .transportUnknown: return "网络中断或等待回执超时"
        case .acknowledgementInvalid: return "无法确认远端回执"
        case .modifiersHeld: return "检测到修饰键仍按下，请完整松开 Command、Control、Option 和 Shift 后手动恢复文字"
        }
    }
}

enum PasteOutcome: Equatable {
    case notSent(PasteFailureReason)
    case eventPosted
    case unknown(PasteFailureReason)

    var reason: PasteFailureReason? {
        switch self {
        case let .notSent(reason), let .unknown(reason): return reason
        case .eventPosted: return nil
        }
    }
}

enum DraftDelivery: Equatable {
    case recording, awaitingDelivery, eventPosted
    case notSent(PasteFailureReason), unknown(PasteFailureReason)

    var needsRecovery: Bool {
        switch self {
        case .notSent, .unknown: return true
        default: return false
        }
    }
    var label: String {
        switch self {
        case .recording: return "正在识别"
        case .awaitingDelivery: return "等待投递结果，请勿重复粘贴"
        case .eventPosted: return "已投递按键；请以目标输入框为准"
        case let .notSent(reason): return "未发送：\(reason.message)"
        case let .unknown(reason): return "结果未知：\(reason.message)。先检查目标，避免重复。"
        }
    }
}

struct RecoveryEntry: Identifiable, Equatable {
    let id: UUID
    let route: PasteRoute
    let createdAt: Date
    var textLength = 0
    var committed = false
    var delivery: DraftDelivery = .recording
    var isUnreadFailure = false
}

/// Only small metadata lives here. Original history text is read on demand.
@MainActor
final class SessionDraftStore: ObservableObject {
    static let retention: TimeInterval = 3 * 24 * 60 * 60
    @Published private(set) var entries: [RecoveryEntry] = []
    @Published private(set) var storageError: String?
    private let capacity: Int
    private var storage: RecoveryTextStorage?
    private let now: () -> Date
    private var expiryTimer: Timer?
    private var pendingCleanup: Set<UUID> = []

    init(capacity: Int = 20, storage: RecoveryTextStorage? = nil, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
        self.storage = storage ?? (try? RecoveryDiskCache())
        if self.storage == nil { storageError = "临时记录目录不可用，请检查磁盘空间或权限后重启。" }
    }

    var canBegin: Bool {
        storage != nil && (entries.count < capacity || entries.contains { $0.delivery == .eventPosted })
    }
    var startFailureMessage: String {
        storageError ?? "已有20条记录无法自动清理，请先在最近文字与恢复中复制或删除。"
    }
    var visibleEntries: [RecoveryEntry] { entries.filter { $0.delivery != .recording && !isExpired($0) } }
    var recoveryCount: Int { visibleEntries.filter { $0.delivery.needsRecovery }.count }
    var unreadFailureCount: Int { visibleEntries.filter { $0.isUnreadFailure }.count }

    @discardableResult
    func begin(id: UUID, route: PasteRoute) -> Bool {
        pruneExpired()
        guard !entries.contains(where: { $0.id == id }), canBegin, let storage else { return false }
        do {
            // Preflight before dictation, preserving older history if this write fails.
            try storage.write("", id: id)
            if entries.count >= capacity, let oldest = entries.firstIndex(where: { $0.delivery == .eventPosted }) {
                try storage.remove(id: entries[oldest].id)
                entries.remove(at: oldest)
            }
            entries.append(RecoveryEntry(id: id, route: route, createdAt: now()))
            storageError = nil
            return true
        } catch {
            try? storage.remove(id: id)
            storageError = "无法准备临时记录，请检查磁盘空间或权限。"
            return false
        }
    }

    /// Called only when a session freezes or fails, not for every recognition update.
    @discardableResult
    func capture(id: UUID, text: String, committed: Bool) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].delivery == .recording, let storage else { return false }
        do {
            try storage.write(text, id: id)
            entries[index].textLength = text.count
            entries[index].committed = committed
            storageError = nil
            return true
        } catch {
            storageError = "无法保存临时记录，请先复制当前文字，再检查磁盘空间或权限。"
            return false
        }
    }

    @discardableResult
    func markAwaitingDelivery(id: UUID, text: String) -> Bool {
        guard capture(id: id, text: text, committed: true),
              let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].delivery = .awaitingDelivery
        scheduleExpiry()
        return true
    }

    func finish(id: UUID, outcome: PasteOutcome) {
        pruneExpired()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].delivery == .recording || entries[index].delivery == .awaitingDelivery else { return }
        guard entries[index].textLength > 0 else { discard(id: id); return }
        switch outcome {
        case let .notSent(reason): entries[index].delivery = .notSent(reason)
        case let .unknown(reason): entries[index].delivery = .unknown(reason)
        case .eventPosted: entries[index].delivery = .eventPosted
        }
        entries[index].isUnreadFailure = entries[index].delivery.needsRecovery
        scheduleExpiry()
    }

    func markFailuresViewed() {
        pruneExpired()
        entries = entries.map { entry in
            var viewed = entry
            if viewed.delivery.needsRecovery { viewed.isUnreadFailure = false }
            return viewed
        }
    }

    func readText(id: UUID) -> String? {
        pruneExpired()
        guard let entry = entries.first(where: { $0.id == id }), !isExpired(entry), entry.textLength > 0,
              let storage else { return nil }
        do { return try storage.read(id: id) }
        catch {
            storageError = "无法读取该临时记录，可重试读取或删除这条记录。"
            return nil
        }
    }

    @discardableResult
    func copy(id: UUID, using write: (String) -> Bool) -> Bool {
        guard let text = readText(id: id) else { return false }
        return write(text)
    }

    func discard(id: UUID) {
        entries.removeAll { $0.id == id }
        pendingCleanup.insert(id)
        do {
            try storage?.remove(id: id)
            pendingCleanup.remove(id)
            storageError = nil
        } catch {
            storageError = "记录已移除，临时文件清理失败，将自动重试；请检查磁盘权限。"
        }
        scheduleExpiry()
    }

    func pruneExpired() {
        let expiredIDs = Set(entries.filter { isExpired($0) }.map(\.id))
        if !expiredIDs.isEmpty { entries.removeAll { expiredIDs.contains($0.id) } }
        pendingCleanup.formUnion(expiredIDs)
        for id in pendingCleanup {
            do {
                try storage?.remove(id: id)
                pendingCleanup.remove(id)
            } catch {
                storageError = "过期文件清理失败；该记录已停止展示和读取，请检查磁盘权限。"
            }
        }
        scheduleExpiry()
    }

    private func isExpired(_ entry: RecoveryEntry) -> Bool {
        entry.delivery != .recording && now().timeIntervalSince(entry.createdAt) >= Self.retention
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let oldest = entries.filter({ $0.delivery != .recording }).map(\.createdAt).min()
        guard oldest != nil || !pendingCleanup.isEmpty else { return }
        let expiry = oldest?.addingTimeInterval(Self.retention).timeIntervalSince(now()) ?? .infinity
        let remaining = min(expiry, pendingCleanup.isEmpty ? .infinity : 60)
        let timer = Timer(timeInterval: remaining > 0 ? remaining : 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pruneExpired() }
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clearForShutdown() {
        expiryTimer?.invalidate(); expiryTimer = nil
        entries.removeAll()
        pendingCleanup.removeAll()
        storage?.close(); storage = nil
    }

    deinit {
        expiryTimer?.invalidate()
        storage?.close()
    }
}
