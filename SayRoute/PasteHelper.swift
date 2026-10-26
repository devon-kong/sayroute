import Foundation
import AppKit
import os

private let pasteHelperLogger = Logger(
    subsystem: "com.devonkong.sayroute",
    category: "PasteHelper"
)

struct PasteHelper {
    /// UserDefaults key for the user-configurable paste quiet period.
    static let quietPeriodDefaultsKey = "pasteQuietPeriodSeconds"
    /// Verified against UU remote on a normal network; 0.25s was observed to
    /// paste the previous session's text when the network got slower.
    static let defaultQuietPeriod: TimeInterval = 1.0
    static let minimumQuietPeriod: TimeInterval = 0.1
    static let maximumQuietPeriod: TimeInterval = 10.0

    /// How long the local clipboard must keep *this* session's text before ⌘V.
    /// UU's ⌘V uses the *remote* clipboard; this quiet window is the outbound
    /// sync from the local Mac to the controlled machine. User-configurable
    /// from the status-bar menu because UU's sync latency varies by network.
    static var remoteSyncQuietPeriod: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: quietPeriodDefaultsKey)
        guard stored > 0 else { return defaultQuietPeriod }
        return min(max(stored, minimumQuietPeriod), maximumQuietPeriod)
    }

    static func setQuietPeriod(_ value: TimeInterval) {
        UserDefaults.standard.set(
            min(max(value, minimumQuietPeriod), maximumQuietPeriod),
            forKey: quietPeriodDefaultsKey
        )
    }

    private static var pendingOperation: CompatibilityPasteOperation?
    private static var pendingID: UUID?

    enum ClipboardDefensePolicy {
        static let minimumMaximumWait: TimeInterval = 2.0

        enum Phase {
            case defendingClipboard
            case finalEventAuthorization
        }

        enum Decision: Equatable {
            case continueDefending
            case postPasteEvent
            case resetStableWindow
            case deadlineExpired
            case targetNotFrontmost
        }

        static func maximumWait(for stableWindow: TimeInterval) -> TimeInterval {
            max(minimumMaximumWait, stableWindow * 2)
        }

        static func canStillSucceed(
            stableElapsed: TimeInterval,
            remainingBudget: TimeInterval,
            stableWindow: TimeInterval
        ) -> Bool {
            let remainingStableTime = max(0, stableWindow - stableElapsed)
            return remainingBudget >= remainingStableTime
        }

        /// Used by the controller before entering the compatibility loop.
        static func initialTargetDecision(targetIsFrontmost: Bool) -> Decision {
            targetIsFrontmost ? .continueDefending : .targetNotFrontmost
        }

        /// The compatibility loop uses this decision at every polling tick and
        /// again immediately before the irreversible Command-V event.
        static func decision(
            phase: Phase,
            now: TimeInterval,
            deadline: TimeInterval,
            targetIsFrontmost: Bool,
            clipboardMatches: Bool
        ) -> Decision {
            guard now < deadline else { return .deadlineExpired }
            guard targetIsFrontmost else { return .targetNotFrontmost }
            switch phase {
            case .defendingClipboard:
                return .continueDefending
            case .finalEventAuthorization:
                return clipboardMatches ? .postPasteEvent : .resetStableWindow
            }
        }
    }

    static func cancelPendingPaste() {
        pendingOperation?.cancel()
        pendingOperation = nil
        pendingID = nil
    }

    static func copyAndPasteLocally(
        _ text: String,
        environment: PasteDeliveryEnvironment? = nil,
        completion: (PasteOutcome) -> Void = { _ in }
    ) {
        cancelPendingPaste()
        let effects = environment ?? liveEnvironment
        guard effects.write(text) else { completion(.notSent(.clipboardWriteFailed)); return }
        completion(effects.post())
    }

    static func copyAndPasteForUUCompatibility(
        _ text: String,
        isPasteTargetFrontmost: @escaping () -> Bool,
        completion: @escaping (PasteOutcome) -> Void
    ) {
        cancelPendingPaste()
        let id = UUID()
        pendingID = id
        let operation = CompatibilityPasteOperation(
            text: text, quietPeriod: remoteSyncQuietPeriod, environment: liveEnvironment,
            targetIsFrontmost: isPasteTargetFrontmost,
            completion: { outcome in
                if pendingID == id { pendingOperation = nil; pendingID = nil }
                completion(outcome)
            }
        )
        pendingOperation = operation
        operation.start()
    }

    @discardableResult
    static func copyOnly(_ text: String) -> Bool { writeClipboard(text) }

    private static var liveEnvironment: PasteDeliveryEnvironment {
        PasteDeliveryEnvironment(
            now: { ProcessInfo.processInfo.systemUptime },
            read: { NSPasteboard.general.string(forType: .string) },
            write: writeClipboard,
            post: simulatePaste,
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        )
    }

    private static func writeClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string) && pasteboard.string(forType: .string) == text
        pasteHelperLogger.notice("event=clipboard_write textLength=\(text.count) verified=\(written)")
        return written
    }

    private static func simulatePaste() -> PasteOutcome {
        switch BalancedPasteKeys.post() {
        case .posted:
            pasteHelperLogger.notice("event=command_v_posted strategy=preflight-snapshot-v2")
            return .eventPosted
        case .modifiersHeld: return .notSent(.modifiersHeld)
        case .eventCreationFailed: return .notSent(.eventCreationFailed)
        }
    }
}
