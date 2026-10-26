import Foundation
import Darwin
import AppKit
import XCTest
@testable import Doubao_Murmur

final class RecoveryDiskCacheTests: XCTestCase {
    private func base() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-disk-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCiphertextRoundTripPermissionsAndCloseDeletesOwnFiles() throws {
        let cache = try RecoveryDiskCache(baseDirectory: base())
        let id = UUID(), text = "不得以明文落盘的测试内容-中文-123"
        try cache.write(text, id: id)
        XCTAssertEqual(try cache.read(id: id), text)
        let file = cache.directory.appendingPathComponent(id.uuidString + ".sealed")
        XCTAssertNil(try Data(contentsOf: file).range(of: Data(text.utf8)))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cache.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let directory = cache.directory
        cache.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try cache.read(id: id))
    }
    func testSecondInstanceCannotDeleteLiveOwnerAndDoesNotRestoreItsHistory() throws {
        let root = try base()
        let first = try RecoveryDiskCache(baseDirectory: root), id = UUID()
        try first.write("live owner", id: id)
        let second = try RecoveryDiskCache(baseDirectory: root)
        XCTAssertEqual(try first.read(id: id), "live owner")
        XCTAssertThrowsError(try second.read(id: id))
        first.close(); second.close()
    }
    func testCorruptedOrSwappedCiphertextIsRejected() throws {
        let cache = try RecoveryDiskCache(baseDirectory: base())
        defer { cache.close() }
        let a = UUID(), b = UUID()
        try cache.write("A", id: a); try cache.write("B", id: b)
        let fileA = cache.directory.appendingPathComponent(a.uuidString + ".sealed")
        let fileB = cache.directory.appendingPathComponent(b.uuidString + ".sealed")
        try Data(contentsOf: fileA).write(to: fileB)
        XCTAssertThrowsError(try cache.read(id: b))
        try Data([0, 1, 2]).write(to: fileA)
        XCTAssertThrowsError(try cache.read(id: a))
    }
    func testStartupLeasePreventsCleanupWhileAnotherInstanceIsCreatingSession() throws {
        let root = try base()
        let fd = Darwin.open(root.appendingPathComponent(".startup-lock").path,
                             O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        XCTAssertThrowsError(try RecoveryDiskCache(baseDirectory: root))
    }
    func testAbandonedAndIncompleteSessionsCleanedButSymlinksAndUnownedFoldersPreserved() throws {
        let root = try base(), fm = FileManager.default
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        let incomplete = root.appendingPathComponent(UUID().uuidString)
        let unowned = root.appendingPathComponent("unowned")
        let unsafeLease = root.appendingPathComponent(UUID().uuidString)
        for dir in [abandoned, incomplete, unowned, unsafeLease] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        }
        try Data().write(to: abandoned.appendingPathComponent(".lease"))
        let target = unowned.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: unsafeLease.appendingPathComponent(".lease"), withDestinationURL: target)
        let symlink = root.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: unowned)
        let cache = try RecoveryDiskCache(baseDirectory: root)
        defer { cache.close() }
        XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
        XCTAssertFalse(fm.fileExists(atPath: incomplete.path))
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: unsafeLease.path))
        XCTAssertTrue(fm.fileExists(atPath: symlink.path))
    }
}

@MainActor
final class DiskHistoryTests: XCTestCase {
    private func store(now: @escaping () -> Date = Date.init) throws -> SessionDraftStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-history-tests-\(UUID())")
        let cache = try RecoveryDiskCache(baseDirectory: root)
        addTeardownBlock { cache.close(); try? FileManager.default.removeItem(at: root) }
        return SessionDraftStore(storage: cache, now: now)
    }
    private func failed(_ store: SessionDraftStore, text: String = "需恢复的原文") -> UUID {
        let id = UUID()
        XCTAssertTrue(store.begin(id: id, route: .uuDirect))
        XCTAssertTrue(store.capture(id: id, text: text, committed: false))
        store.finish(id: id, outcome: .notSent(.connectionUnavailable))
        return id
    }
    func testOpeningClearsExistingBadgeButKeepsFailureAndNewFailureAlertsAgain() throws {
        let store = try store()
        let first = failed(store)
        XCTAssertEqual(store.unreadFailureCount, 1)
        store.markFailuresViewed()
        XCTAssertEqual(store.unreadFailureCount, 0)
        XCTAssertEqual(store.entries.first?.delivery, .notSent(.connectionUnavailable))
        XCTAssertEqual(store.readText(id: first), "需恢复的原文")
        XCTAssertTrue(store.copy(id: first, using: { $0 == "需恢复的原文" }))
        XCTAssertEqual(store.unreadFailureCount, 0)
        _ = failed(store, text: "新失败")
        XCTAssertEqual(store.unreadFailureCount, 1)
        XCTAssertEqual(store.entries.count, 2)
    }
    func testThreeDayExpiryDeletesFailedAndSuccessfulRecordsEvenIfUnread() throws {
        var now = Date()
        let store = try store(now: { now })
        let failure = failed(store), success = UUID()
        XCTAssertTrue(store.begin(id: success, route: .local))
        XCTAssertTrue(store.markAwaitingDelivery(id: success, text: "成功文本"))
        store.finish(id: success, outcome: .eventPosted)
        now = now.addingTimeInterval(3 * 24 * 3600 - 1)
        store.pruneExpired()
        XCTAssertEqual(store.entries.count, 2)
        now = now.addingTimeInterval(1)
        XCTAssertNil(store.readText(id: failure))
        XCTAssertNil(store.readText(id: success))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.unreadFailureCount, 0)
    }
    func testMetadataDoesNotCarryTranscriptionAndShutdownDoesNotRestore() throws {
        let store = try store()
        let id = failed(store, text: "只在磁盘中的原文")
        XCTAssertEqual(store.entries.first?.textLength, 8)
        XCTAssertFalse(Mirror(reflecting: try XCTUnwrap(store.entries.first)).children.contains { $0.label == "text" })
        store.clearForShutdown()
        XCTAssertNil(store.readText(id: id))
        XCTAssertFalse(store.begin(id: UUID(), route: .local))
    }
    func testWindowCloseReleasesTextAndLateLoadCannotRestoreIt() throws {
        let store = try store(), id = failed(store)
        let presentation = RecoveryTextPresentation()
        presentation.load(id: id, from: store)
        XCTAssertNotNil(presentation.textByID[id])
        presentation.close()
        presentation.load(id: id, from: store, retry: true)
        XCTAssertTrue(presentation.textByID.isEmpty)
        let reopened = RecoveryTextPresentation()
        reopened.load(id: id, from: store)
        XCTAssertNotNil(reopened.textByID[id])
        reopened.unload(id: id)
        XCTAssertTrue(reopened.textByID.isEmpty)
    }
}

@MainActor
final class DiskFailureTests: XCTestCase {
    func testStorageFailureRetainsSnapshotThroughLateIMEAndCopyFailureUntilDiscard() {
        let disk = ControlledDisk(), store = SessionDraftStore(storage: disk), id = UUID()
        let clients = IMETextClientSession(), client = clients.begin(sessionID: id)
        _ = store.begin(id: id, route: .local)
        client.setMarkedText("保存失败时的完整原文", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        disk.failWrites = true
        XCTAssertFalse(store.capture(id: id, text: client.string, committed: false))
        client.freezeForRecovery()
        client.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: 0, length: client.string.utf16.count))
        client.insertText("迟到的替换", replacementRange: NSRange(location: 0, length: client.string.utf16.count))
        client.unmarkText()
        XCTAssertEqual(client.string, "保存失败时的完整原文")
        XCTAssertFalse(client.isTracking)
        XCTAssertFalse(client.isEditable)
        XCTAssertFalse(client.copyRecoveryText(using: { _ in false }))
        XCTAssertEqual(client.string, "保存失败时的完整原文")
        var copied = ""
        XCTAssertTrue(client.copyRecoveryText { copied = $0; return true })
        XCTAssertEqual(copied, "保存失败时的完整原文")
        clients.retire()
        client.insertText("退休后迟到", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(client.string, "")
    }
    func testWriteFailureCannotAdvanceToDeliveryOrLosePreviousSnapshot() {
        let disk = ControlledDisk(), store = SessionDraftStore(storage: disk), id = UUID()
        XCTAssertTrue(store.begin(id: id, route: .uuDirect))
        XCTAssertTrue(store.capture(id: id, text: "上次已保存", committed: false))
        disk.failWrites = true
        XCTAssertFalse(store.markAwaitingDelivery(id: id, text: "此次尚未保存，必须留在输入框"))
        XCTAssertEqual(store.entries.first?.delivery, .recording)
        XCTAssertEqual(store.readText(id: id), "上次已保存")
        XCTAssertNotNil(store.storageError)
    }
    func testFailedPreflightDoesNotEvictExistingHistory() {
        let disk = ControlledDisk(), store = SessionDraftStore(capacity: 1, storage: disk), first = UUID()
        XCTAssertTrue(store.begin(id: first, route: .local))
        XCTAssertTrue(store.markAwaitingDelivery(id: first, text: "旧历史"))
        store.finish(id: first, outcome: .eventPosted)
        disk.failWrites = true
        XCTAssertFalse(store.begin(id: UUID(), route: .local))
        XCTAssertEqual(store.readText(id: first), "旧历史")
    }
    func testReadFailureDoesNotPretendCopySucceededOrRemoveRecord() {
        let disk = ControlledDisk(), store = SessionDraftStore(storage: disk), id = UUID()
        _ = store.begin(id: id, route: .local)
        _ = store.capture(id: id, text: "待恢复", committed: false)
        store.finish(id: id, outcome: .notSent(.focusLost))
        disk.failReads = true
        var copied = false
        XCTAssertFalse(store.copy(id: id) { _ in copied = true; return true })
        XCTAssertFalse(copied)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.delivery, .notSent(.focusLost))
    }
    func testExpiryDeletionFailureClearsBadgeAndCapacityThenRetriesCleanup() {
        var now = Date()
        let disk = ControlledDisk(), store = SessionDraftStore(capacity: 1, storage: disk, now: { now })
        let id = UUID()
        _ = store.begin(id: id, route: .local)
        _ = store.capture(id: id, text: "expired", committed: false)
        store.finish(id: id, outcome: .notSent(.focusLost))
        disk.failDeletes = true
        now = now.addingTimeInterval(SessionDraftStore.retention)
        store.pruneExpired()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.canBegin)
        XCTAssertEqual(store.unreadFailureCount, 0)
        XCTAssertNil(store.readText(id: id))
        XCTAssertNotNil(disk.files[id])
        disk.failDeletes = false
        store.pruneExpired()
        XCTAssertNil(disk.files[id])
    }
    func testExplicitDiscardOfRecordingFreesCapacityEvenIfFileRemovalFails() {
        let disk = ControlledDisk(), store = SessionDraftStore(capacity: 1, storage: disk), id = UUID()
        _ = store.begin(id: id, route: .local)
        disk.failDeletes = true
        store.discard(id: id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.canBegin)
        disk.failDeletes = false
        store.pruneExpired()
        XCTAssertNil(disk.files[id])
    }
}

private final class ControlledDisk: RecoveryTextStorage {
    enum Failure: Error { case io }
    var failWrites = false, failReads = false, failDeletes = false
    var files: [UUID: String] = [:]
    func write(_ text: String, id: UUID) throws {
        if failWrites { throw Failure.io }; files[id] = text
    }
    func read(id: UUID) throws -> String {
        guard !failReads, let value = files[id] else { throw Failure.io }; return value
    }
    func remove(id: UUID) throws { if failDeletes { throw Failure.io }; files[id] = nil }
    func close() { files.removeAll() }
}
