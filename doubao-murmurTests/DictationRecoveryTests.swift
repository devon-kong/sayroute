import AppKit
import XCTest
@testable import Doubao_Murmur

final class MarkedTextReentryTests: XCTestCase {
    func testNewCompositionRevokesPreviousCommit() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: false), .markedTextCommitted)
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .markedTextCommitted)
    }
}

final class DictationCompletionTests: XCTestCase {
    private let id = UUID()
    private func snapshot(_ revision: UInt64, _ marked: Bool, _ text: String = "待恢复长文本") -> IMETextSnapshot {
        IMETextSnapshot(sessionID: id, revision: revision, text: text, hasMarkedText: marked)
    }
    private func stoppingGate() -> DictationCompletionGate {
        var gate = DictationCompletionGate(sessionID: id)
        _ = gate.observe(snapshot(1, true), now: 0)
        _ = gate.beginStopping(now: 10)
        _ = gate.physicalKeyUp(now: 10.01)
        return gate
    }
    func testSoftDeadlineDoesNotCancelAndFiveSecondCommitCanLock() {
        var gate = stoppingGate()
        XCTAssertEqual(gate.poll(now: 11.49, focusConfirmed: true), .none)
        XCTAssertEqual(gate.poll(now: 11.5, focusConfirmed: true), .waitingLonger)
        XCTAssertEqual(gate.poll(now: 11.51, focusConfirmed: true), .none)
        XCTAssertEqual(gate.observe(snapshot(2, false), now: 15), .lockReady(2))
        XCTAssertEqual(gate.lock(revision: 2, now: 15, focusConfirmed: true), .freeze("待恢复长文本"))
        XCTAssertEqual(gate.lock(revision: 2, now: 15, focusConfirmed: true), .none)
    }
    func testHardDeadlineRejectsLateCommitAndExplainsWhy() {
        var gate = stoppingGate()
        _ = gate.poll(now: 24.99, focusConfirmed: true)
        XCTAssertEqual(gate.poll(now: 25, focusConfirmed: true), .failed(.commitPending))
        XCTAssertEqual(gate.observe(snapshot(2, false), now: 25.01), .none)
        XCTAssertEqual(gate.lock(revision: 2, now: 25.02, focusConfirmed: true), .none)
    }
    func testDelayedLockCannotCrossDeadline() {
        var gate = stoppingGate()
        XCTAssertEqual(gate.observe(snapshot(2, false), now: 24.99), .lockReady(2))
        XCTAssertEqual(gate.lock(revision: 2, now: 25.01, focusConfirmed: true), .failed(.commitPending))
    }
    func testRemarkAndRevisionChangesInvalidateQueuedLock() {
        var gate = stoppingGate()
        XCTAssertEqual(gate.observe(snapshot(2, false), now: 11), .lockReady(2))
        XCTAssertEqual(gate.observe(snapshot(3, true), now: 11.01), .none)
        XCTAssertEqual(gate.lock(revision: 2, now: 11.02, focusConfirmed: true), .none)
        XCTAssertEqual(gate.observe(snapshot(4, false, "最终完整文本"), now: 12), .lockReady(4))
        XCTAssertEqual(gate.observe(snapshot(5, false, "最终完整文本。"), now: 12.01), .lockReady(5))
        XCTAssertEqual(gate.lock(revision: 4, now: 12.02, focusConfirmed: true), .none)
        XCTAssertEqual(gate.lock(revision: 5, now: 12.02, focusConfirmed: true), .freeze("最终完整文本。"))
    }
    func testCommitBeforeStopAndOrphanKeyUpStillComplete() {
        var gate = DictationCompletionGate(sessionID: id)
        _ = gate.observe(snapshot(1, true), now: 1)
        _ = gate.observe(snapshot(2, false), now: 2)
        XCTAssertEqual(gate.physicalKeyUp(now: 2.1), .lockReady(2))
        XCTAssertEqual(gate.lock(revision: 2, now: 2.2, focusConfirmed: true), .freeze("待恢复长文本"))
    }
    func testNoMarkedTextCannotAuthorizePasteAndHasDistinctReason() {
        var gate = DictationCompletionGate(sessionID: id)
        _ = gate.observe(snapshot(1, false), now: 1)
        XCTAssertEqual(gate.physicalKeyUp(now: 2), .none)
        XCTAssertEqual(gate.poll(now: 17, focusConfirmed: true), .failed(.missingMarkedText))
    }
    func testMissingKeyUpFocusLossAndOldSessionFailClosed() {
        var gate = DictationCompletionGate(sessionID: id)
        _ = gate.observe(snapshot(1, true), now: 0)
        _ = gate.beginStopping(now: 1)
        _ = gate.observe(snapshot(2, false), now: 2)
        XCTAssertEqual(gate.poll(now: 16, focusConfirmed: true), .failed(.missingKeyUp))
        var other = stoppingGate()
        XCTAssertEqual(other.observe(IMETextSnapshot(sessionID: UUID(), revision: 99, text: "OLD", hasMarkedText: false), now: 11), .none)
        XCTAssertEqual(other.poll(now: 11, focusConfirmed: false), .failed(.focusLost))
        XCTAssertEqual(other.observe(snapshot(2, false), now: 12), .none)
    }
    func testCancellationAndSecondPhysicalDownRevokeAuthorization() {
        var gate = stoppingGate()
        _ = gate.observe(snapshot(2, false), now: 11)
        XCTAssertEqual(gate.beginStopping(now: 11.1), .failed(.stopInterrupted))
        XCTAssertEqual(gate.lock(revision: 2, now: 11.2, focusConfirmed: true), .none)
        var cancelled = stoppingGate()
        cancelled.cancel()
        XCTAssertEqual(cancelled.observe(snapshot(2, false), now: 12), .none)
    }
}

@MainActor
final class SessionDraftStoreTests: XCTestCase {
    func testFailureSurvivesNewRecordingCopyFailureAndLateDeletedOutcome() {
        let store = SessionDraftStore()
        let first = UUID(), second = UUID()
        XCTAssertTrue(store.begin(id: first, route: .uuDirect))
        store.capture(id: first, text: "第一段未完成", committed: false)
        store.finish(id: first, outcome: .notSent(.commitPending))
        XCTAssertTrue(store.begin(id: second, route: .local))
        store.capture(id: second, text: "第二段", committed: false)
        XCTAssertFalse(store.copy(id: first, using: { _ in false }))
        XCTAssertTrue(store.copy(id: first, using: { $0 == "第一段未完成" }))
        XCTAssertEqual(store.readText(id: first), "第一段未完成")
        store.discard(id: second)
        XCTAssertEqual(store.recoveryCount, 1)
        store.discard(id: first)
        store.finish(id: first, outcome: .eventPosted)
        XCTAssertTrue(store.entries.isEmpty)
    }
    func testCapacityEvictsOnlyOldestPostedResultAndProtectsPendingOrders() {
        let store = SessionDraftStore(capacity: 2)
        let failed = UUID(), posted = UUID(), next = UUID()
        XCTAssertTrue(store.begin(id: failed, route: .uuDirect))
        store.capture(id: failed, text: "未知", committed: true)
        store.markAwaitingDelivery(id: failed, text: "未知")
        store.finish(id: failed, outcome: .unknown(.transportUnknown))
        XCTAssertTrue(store.begin(id: posted, route: .uuDirect))
        store.markAwaitingDelivery(id: posted, text: "已投递")
        XCTAssertFalse(store.canBegin)
        store.finish(id: posted, outcome: .eventPosted)
        XCTAssertTrue(store.begin(id: next, route: .local))
        XCTAssertNotNil(store.entries.first { $0.id == failed })
        XCTAssertNil(store.entries.first { $0.id == posted })
        XCTAssertFalse(store.canBegin)
    }
    func testTerminalResultIsNotDowngradedAndOriginalTextIsRetained() {
        let store = SessionDraftStore()
        let id = UUID()
        _ = store.begin(id: id, route: .local)
        store.markAwaitingDelivery(id: id, text: "完整文字")
        store.finish(id: id, outcome: .eventPosted)
        store.capture(id: id, text: "late", committed: false)
        store.finish(id: id, outcome: .unknown(.transportUnknown))
        XCTAssertEqual(store.readText(id: id), "完整文字")
        XCTAssertEqual(store.entries.first?.delivery, .eventPosted)
        store.clearForShutdown()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

@MainActor
final class IMESnapshotTests: XCTestCase {
    func testCommittedSnapshotsFollowAppKitTextAndCleanupIsSilent() {
        let view = IMETrackingTextView(frame: .zero)
        let id = UUID()
        var snapshots: [IMETextSnapshot] = []
        view.onSnapshotChanged = { snapshots.append($0) }
        view.beginTracking(sessionID: id)
        view.setMarkedText("尚未完成", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(snapshots.last?.hasMarkedText, true)
        view.insertText("完整内容", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(snapshots.last?.text, "完整内容")
        XCTAssertEqual(snapshots.last?.hasMarkedText, false)
        XCTAssertTrue(snapshots.allSatisfy { $0.sessionID == id })
        XCTAssertEqual(Set(snapshots.map(\.revision)).count, snapshots.count)
        let before = snapshots.count
        view.clearProgrammatically()
        XCTAssertEqual(snapshots.count, before)
        XCTAssertEqual(view.string, "")
    }
}

final class PasteDeliveryTests: XCTestCase {
    func testHeldModifierRejectionSurvivesLocalAndCompatibilityDelivery() {
        var now = 0.0, posts = 0
        var next: (() -> Void)?, local: [PasteOutcome] = [], compatibility: [PasteOutcome] = []
        let environment = PasteDeliveryEnvironment(now: { now }, read: { "fixture" }, write: { _ in true },
            post: { posts += 1; return .notSent(.modifiersHeld) }, schedule: { _, work in next = work })
        PasteHelper.copyAndPasteLocally("fixture", environment: environment) { local.append($0) }
        let operation = CompatibilityPasteOperation(text: "fixture", quietPeriod: 1, environment: environment,
            targetIsFrontmost: { true }, completion: { compatibility.append($0) })
        operation.start()
        now = 1.01
        next?(); next?()
        XCTAssertEqual(local, [.notSent(.modifiersHeld)])
        XCTAssertEqual(compatibility, [.notSent(.modifiersHeld)])
        XCTAssertEqual(posts, 2)
    }

    func testCancelledCompatibilityOperationNeverPostsAndReportsOnce() {
        var now = 0.0, clipboard = "文字", posted = 0
        var callbacks: [() -> Void] = [], outcomes: [PasteOutcome] = []
        let operation = CompatibilityPasteOperation(text: "文字", quietPeriod: 1,
            environment: PasteDeliveryEnvironment(now: { now }, read: { clipboard },
                write: { clipboard = $0; return true }, post: { posted += 1; return .eventPosted },
                schedule: { _, work in callbacks.append(work) }),
            targetIsFrontmost: { true }, completion: { outcomes.append($0) })
        operation.start()
        operation.cancel()
        now = 5
        callbacks.forEach { $0() }
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(outcomes, [.notSent(.superseded)])
    }
    func testClipboardFailureAndTargetLossReturnRecoverableOutcomes() {
        var outcomes: [PasteOutcome] = [], posts = 0
        let environment = PasteDeliveryEnvironment(now: { 0 }, read: { "old" }, write: { _ in false },
            post: { posts += 1; return .eventPosted }, schedule: { _, _ in XCTFail("Should fail immediately") })
        CompatibilityPasteOperation(text: "new", quietPeriod: 1, environment: environment,
            targetIsFrontmost: { true }, completion: { outcomes.append($0) }).start()
        CompatibilityPasteOperation(text: "new", quietPeriod: 1, environment: environment,
            targetIsFrontmost: { false }, completion: { outcomes.append($0) }).start()
        XCTAssertEqual(outcomes, [.notSent(.clipboardWriteFailed), .notSent(.targetNotFrontmost)])
        XCTAssertEqual(posts, 0)
    }
    func testHealthyWindowPostsOnceAndLateTickDoesNotPost() {
        for late in [false, true] {
            var now = 0.0, posts = 0
            var next: (() -> Void)?, outcomes: [PasteOutcome] = []
            let operation = CompatibilityPasteOperation(text: "文字", quietPeriod: 1,
                environment: PasteDeliveryEnvironment(now: { now }, read: { "文字" }, write: { _ in true },
                    post: { posts += 1; return .eventPosted }, schedule: { _, work in next = work }),
                targetIsFrontmost: { true }, completion: { outcomes.append($0) })
            operation.start()
            now = late ? 2.01 : 1.01
            next?(); next?()
            XCTAssertEqual(posts, late ? 0 : 1)
            XCTAssertEqual(outcomes, late ? [.notSent(.clipboardUnstable)] : [.eventPosted])
        }
    }
}

final class SessionDiagnosticsTests: XCTestCase {
    func testMetadataIncludesOnlyMeasurementsAndNeverTranscription() throws {
        let secret = "诊断不可保留的原文_7e641"
        let snapshot = IMETextSnapshot(sessionID: UUID(), revision: 17, text: secret, hasMarkedText: true)
        let json = SessionDiagnostics.details(snapshot: snapshot, route: .uuDirect, phase: .stopping,
                                              reason: "commit_pending", version: "1.3.1 (16)")
        XCTAssertFalse(json.contains(secret))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["revision", "has_marked_text", "text_length", "route", "phase", "reason", "app_version"])
        XCTAssertEqual(object["revision"] as? Int, 17)
        XCTAssertEqual(object["text_length"] as? Int, secret.count)
    }
}

// Convenience only in tests: real production callers must supply live AppKit state.
private extension DictationCompletionGate {
    mutating func lock(revision: UInt64, now: TimeInterval, focusConfirmed: Bool) -> Action {
        lock(revision: revision, now: now, focusConfirmed: focusConfirmed,
             liveText: snapshot?.text ?? "", liveHasMarkedText: snapshot?.hasMarkedText ?? false)
    }
}

final class FinalLockBoundaryTests: XCTestCase {
    func testLiveCompositionOrChangedTextBlocksQueuedSnapshot() {
        for liveMarked in [true, false] {
            let id = UUID()
            var gate = DictationCompletionGate(sessionID: id)
            _ = gate.observe(IMETextSnapshot(sessionID: id, revision: 1, text: "原文", hasMarkedText: true), now: 0)
            _ = gate.beginStopping(now: 1)
            _ = gate.physicalKeyUp(now: 1)
            _ = gate.observe(IMETextSnapshot(sessionID: id, revision: 2, text: "原文", hasMarkedText: false), now: 2)
            XCTAssertEqual(gate.lock(revision: 2, now: 2.1, focusConfirmed: true,
                                    liveText: liveMarked ? "原文" : "追加原文", liveHasMarkedText: liveMarked), .none)
        }
    }
    func testMissingOrDifferentLocalTargetCannotAuthorizePaste() {
        XCTAssertFalse(PasteRouter.targetIsReady(expectedPID: nil, frontmostPID: 1, isTerminated: false))
        XCTAssertFalse(PasteRouter.targetIsReady(expectedPID: 1, frontmostPID: 2, isTerminated: false))
        XCTAssertFalse(PasteRouter.targetIsReady(expectedPID: 1, frontmostPID: 1, isTerminated: true))
        XCTAssertTrue(PasteRouter.targetIsReady(expectedPID: 1, frontmostPID: 1, isTerminated: false))
    }
    func testLocalClipboardOrEventCreationFailureNeverReportsPosted() {
        var posts = 0, outcomes: [PasteOutcome] = []
        var environment = PasteDeliveryEnvironment(now: { 0 }, read: { nil }, write: { _ in false },
            post: { posts += 1; return .notSent(.eventCreationFailed) }, schedule: { _, _ in XCTFail("Local paste must not schedule") })
        PasteHelper.copyAndPasteLocally("text", environment: environment) { outcomes.append($0) }
        XCTAssertEqual(posts, 0)
        environment.write = { _ in true }
        PasteHelper.copyAndPasteLocally("text", environment: environment) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.notSent(.clipboardWriteFailed), .notSent(.eventCreationFailed)])
    }
}

final class StopGestureRecoveryTests: XCTestCase {
    func testRepeatedStartWhileWaitingForCommitCannotDiscardCurrentDraft() {
        XCTAssertEqual(SessionTogglePolicy.action(for: .stopping), .ignoreWhileRecording)
        XCTAssertEqual(SessionTogglePolicy.action(for: .recoveryRequired), .ignoreWhileRecording)
    }
}

@MainActor
final class TextClientEpochTests: XCTestCase {
    func testRetiredClientCannotBeRetaggedAsNewSession() {
        let view = IMETrackingTextView(frame: .zero)
        view.beginTracking(sessionID: UUID())
        view.clearProgrammatically()
        let second = UUID()
        var callbacks: [IMETextSnapshot] = []
        view.onSnapshotChanged = { callbacks.append($0) }
        view.beginTracking(sessionID: second)
        view.setMarkedText("旧识别", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("旧内容", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(callbacks.isEmpty, "Retired clients must never emit under a different session ID")
        XCTAssertEqual(view.string, "", "Retired clients must never reacquire old plaintext")
    }
}

@MainActor
final class TextClientOwnershipTests: XCTestCase {
    func testNewSessionGetsIndependentClientAndOldIngressCannotReachIt() {
        let sessions = IMETextClientSession()
        let old = sessions.begin(sessionID: UUID())
        let id = UUID()
        let current = sessions.begin(sessionID: id)
        XCTAssertFalse(old === current)
        var newSnapshots: [IMETextSnapshot] = []
        current.onSnapshotChanged = { newSnapshots.append($0) }
        old.setMarkedText("迟到旧文", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        old.insertText("迟到旧文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(newSnapshots.isEmpty)
        XCTAssertEqual(current.string, "")
        current.setMarkedText("新的完整文本", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        current.insertText("新的完整文本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(newSnapshots.last?.text, "新的完整文本")
        XCTAssertEqual(newSnapshots.last?.sessionID, id)
        XCTAssertEqual(newSnapshots.last?.hasMarkedText, false)
        sessions.retire()
        XCTAssertFalse(current.isTracking)
    }
}
