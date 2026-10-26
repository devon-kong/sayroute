import Foundation

struct IMETextSnapshot: Equatable {
    let sessionID: UUID
    let revision: UInt64
    let text: String
    let hasMarkedText: Bool
}

/// Pure state machine. The caller supplies monotonic time and executes effects.
/// A queued lock is a revocable revision token, never a success in itself.
struct DictationCompletionGate {
    enum Action: Equatable {
        case none, waitingLonger
        case lockReady(UInt64)
        case freeze(String)
        case failed(PasteFailureReason)
    }
    static let softWait: TimeInterval = 1.5
    static let hardWait: TimeInterval = 15
    let sessionID: UUID
    private(set) var snapshot: IMETextSnapshot?
    private var marked = MarkedTextCommitGate()
    private var physical = PhysicalRightCommandStopGate()
    private var startedAt: TimeInterval?
    private var didShowWaiting = false
    private var closed = false
    private var pendingRevision: UInt64?

    init(sessionID: UUID) { self.sessionID = sessionID }

    mutating func observe(_ value: IMETextSnapshot, now: TimeInterval) -> Action {
        guard !closed, value.sessionID == sessionID,
              snapshot.map({ value.revision > $0.revision }) ?? true else { return .none }
        if let expired = expireIfNeeded(now: now) { return expired }
        snapshot = value
        pendingRevision = nil
        physical.invalidateCommit()
        _ = marked.observe(hasMarkedText: value.hasMarkedText)
        return authorizeLock()
    }

    mutating func beginStopping(now: TimeInterval) -> Action {
        guard !closed else { return .none }
        guard startedAt == nil else { return fail(.stopInterrupted) }
        startedAt = now
        _ = physical.observePhysicalRightCommandDown()
        _ = marked.beginStopping(currentlyHasMarkedText: snapshot?.hasMarkedText ?? false)
        return authorizeLock()
    }

    mutating func physicalKeyUp(now: TimeInterval) -> Action {
        guard !closed else { return .none }
        if startedAt == nil { _ = beginStopping(now: now) }
        if let expired = expireIfNeeded(now: now) { return expired }
        let action = physical.observePhysicalRightCommandUp()
        if action == .scheduleFinalTextLock, let snapshot, !snapshot.hasMarkedText {
            pendingRevision = snapshot.revision
            return .lockReady(snapshot.revision)
        }
        return authorizeLock()
    }

    mutating func poll(now: TimeInterval, focusConfirmed: Bool) -> Action {
        guard !closed, let startedAt else { return .none }
        guard focusConfirmed else { return fail(.focusLost) }
        if let expired = expireIfNeeded(now: now) { return expired }
        if !didShowWaiting, now - startedAt >= Self.softWait {
            didShowWaiting = true
            return .waitingLonger
        }
        return .none
    }

    mutating func lock(revision: UInt64, now: TimeInterval, focusConfirmed: Bool,
                       liveText: String, liveHasMarkedText: Bool) -> Action {
        guard !closed else { return .none }
        if let expired = expireIfNeeded(now: now) { return expired }
        guard focusConfirmed else { return fail(.focusLost) }
        guard let snapshot, pendingRevision == revision, snapshot.revision == revision,
              !snapshot.hasMarkedText, !liveHasMarkedText, liveText == snapshot.text,
              marked.hasCommitted, physical.hasReleased else { return .none }
        closed = true
        return .freeze(snapshot.text)
    }

    mutating func cancel() {
        closed = true
        pendingRevision = nil
        marked.cancel()
        physical.cancel()
    }

    private mutating func authorizeLock() -> Action {
        guard startedAt != nil, let snapshot, !snapshot.hasMarkedText, marked.hasCommitted else { return .none }
        if physical.markMarkedTextCommitted() == .scheduleFinalTextLock {
            pendingRevision = snapshot.revision
            return .lockReady(snapshot.revision)
        }
        return .none
    }

    private mutating func expireIfNeeded(now: TimeInterval) -> Action? {
        guard let startedAt, now - startedAt >= Self.hardWait else { return nil }
        return fail(!physical.hasReleased ? .missingKeyUp : !marked.hasObservedMarkedText ? .missingMarkedText : .commitPending)
    }
    private mutating func fail(_ reason: PasteFailureReason) -> Action {
        cancel()
        return .failed(reason)
    }
}
