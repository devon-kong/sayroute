import AppKit
import CoreGraphics
import Foundation
import os

private let sessionLogger = Logger(
    subsystem: "com.doubao.murmur",
    category: "InputMethodSession"
)
private let functionKeyDiagnosticsLogger = Logger(
    subsystem: "com.doubao.murmur",
    category: "FunctionKeyDiagnostics"
)

struct RecordingReadinessGate {
    enum Action: Equatable {
        case none
        case postRightCommandStart
    }

    private var focusIsReady = false
    private var inputSourceIsReady = false
    private var hotkeyIsReleased = false
    private var didAuthorizeStart = false
    private var isCancelled = false

    mutating func markFocusReady() -> Action {
        focusIsReady = true
        return authorizationAction()
    }

    mutating func markInputSourceReady() -> Action {
        inputSourceIsReady = true
        return authorizationAction()
    }

    mutating func markHotkeyReleased() -> Action {
        hotkeyIsReleased = true
        return authorizationAction()
    }

    mutating func cancel() {
        isCancelled = true
    }

    private mutating func authorizationAction() -> Action {
        guard !isCancelled,
              focusIsReady,
              inputSourceIsReady,
              hotkeyIsReleased,
              !didAuthorizeStart else { return .none }
        didAuthorizeStart = true
        return .postRightCommandStart
    }
}

enum InputMethodSessionPhase: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case recoveryRequired
}

enum SessionToggleAction: Equatable {
    case start
    case ignoreWhileRecording
    case cancel
}

private enum RightCommandTapKind {
    case start

    var diagnosticPrefix: String {
        switch self {
        case .start: "right_command_start"
        }
    }
}

struct SessionTogglePolicy {
    static func action(for phase: InputMethodSessionPhase) -> SessionToggleAction {
        switch phase {
        case .idle:
            return .start
        case .preparing:
            return .cancel
        case .recording, .stopping, .recoveryRequired:
            return .ignoreWhileRecording
        }
    }
}

struct MarkedTextCommitGate {
    enum Action: Equatable {
        case none
        case markedTextStarted
        case markedTextCommitted
        case focusLost
        case timedOut
    }

    private var didObserveMarkedText = false
    private var isStopping = false
    private var didCommit = false
    private var isCancelled = false

    var hasObservedMarkedText: Bool { didObserveMarkedText }
    var hasCommitted: Bool { didCommit && !isCancelled }

    mutating func observe(hasMarkedText: Bool) -> Action {
        guard !isCancelled else { return .none }
        if hasMarkedText {
            if didCommit {
                didCommit = false
                return .markedTextStarted
            }
            guard !didObserveMarkedText else { return .none }
            didObserveMarkedText = true
            return .markedTextStarted
        }
        guard isStopping, didObserveMarkedText, !didCommit else { return .none }
        didCommit = true
        return .markedTextCommitted
    }

    mutating func beginStopping(currentlyHasMarkedText: Bool) -> Action {
        guard !isCancelled else { return .none }
        isStopping = true
        return observe(hasMarkedText: currentlyHasMarkedText)
    }

    /// The panel must remain the active text client until the input method has
    /// committed its marked text. A lost focus is never recovered by assuming
    /// that the marked text was committed.
    mutating func observeFocus(isConfirmed: Bool) -> Action {
        guard !isCancelled, isStopping else { return .none }
        guard !isConfirmed else { return .none }
        isCancelled = true
        return .focusLost
    }

    /// This is an escape hatch only. It must not authorize a final-text lock,
    /// because an input method that never unmarks may still hold a partial
    /// composition.
    mutating func expireWaitingForCommit() -> Action {
        guard !isCancelled, isStopping, !didCommit else { return .none }
        isCancelled = true
        return .timedOut
    }

    mutating func cancel() {
        isCancelled = true
    }
}

/// A physical, bare right Command press is the user's stop gesture. Never
/// close the text client until that physical key has returned up and Doubao
/// has committed marked text for this stopping session.
struct PhysicalRightCommandStopGate {
    enum Action: Equatable {
        case none
        case startedStopping
        case scheduleFinalTextLock
        case nonBareCommand
        case timedOut
    }

    private var markedTextCommitted = false
    private var physicalRightCommandIsDown = false
    private var physicalRightCommandUpObserved = false
    private var didAuthorizeFinalLock = false
    private var isCancelled = false

    var hasReleased: Bool { physicalRightCommandUpObserved && !physicalRightCommandIsDown }

    mutating func invalidateCommit() {
        markedTextCommitted = false
        didAuthorizeFinalLock = false
    }

    mutating func observePhysicalRightCommandDown() -> Action {
        guard !isCancelled, !physicalRightCommandIsDown, !physicalRightCommandUpObserved else { return .none }
        physicalRightCommandIsDown = true
        return .startedStopping
    }

    mutating func observePhysicalRightCommandUp() -> Action {
        guard !isCancelled, physicalRightCommandIsDown else { return .none }
        physicalRightCommandIsDown = false
        physicalRightCommandUpObserved = true
        return authorizationAction()
    }

    mutating func observeOrdinaryKeyDown() -> Action {
        guard !isCancelled, physicalRightCommandIsDown else { return .none }
        isCancelled = true
        return .nonBareCommand
    }

    mutating func markMarkedTextCommitted() -> Action {
        guard !isCancelled else { return .none }
        markedTextCommitted = true
        return authorizationAction()
    }

    mutating func expireWaiting() -> Action {
        guard !isCancelled, !didAuthorizeFinalLock else { return .none }
        isCancelled = true
        return .timedOut
    }

    mutating func cancel() {
        isCancelled = true
    }

    private mutating func authorizationAction() -> Action {
        guard markedTextCommitted,
              physicalRightCommandUpObserved,
              !didAuthorizeFinalLock else { return .none }
        didAuthorizeFinalLock = true
        return .scheduleFinalTextLock
    }
}

/// Focus an NSTextView, select Doubao's input source, and toggle voice input
/// with a synthetic right Command click after the physical hotkey is released.
@MainActor
final class InputMethodSessionManager {
    /// Poll interval / budget for waiting until UU (or the previous app) is
    /// actually frontmost before publishing the clipboard.
    private static let frontmostPollInterval: TimeInterval = 0.05
    private static let frontmostWaitBudget: TimeInterval = 0.40
    /// This is not a completion delay. Marked text is still the only normal
    /// completion signal; the deadline merely prevents a broken IME session
    /// from leaving the UI in `stopping` forever.
    private static let stoppingFocusPollInterval: TimeInterval = 0.10
    private static let rightCommandPressDuration: TimeInterval = 0.03

    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let pasteOrderEventLogger: PasteOrderEventLogger
    private lazy var directPasteOrderCoordinator = DirectPasteOrderCoordinator(
        logger: pasteOrderEventLogger,
        onOutcome: { [weak self] id, outcome in self?.recordPasteOutcome(sessionID: id, outcome: outcome) }
    )
    private let now: () -> TimeInterval
    private var traceIdentities: [UUID: PasteOrderIdentity] = [:]
    private var sessionRoutes: [UUID: PasteRoute] = [:]
    private var sessionPlacements: [UUID: OverlayPlacementContext] = [:]
    private var currentOverlayPlacement: OverlayPlacementContext?
    private let traceProcessID = UUID()
    private var traceSequence: Int64 = 0
    private var pendingPasteSessionID: UUID?
    private let inputSourceManager = InputSourceManager()
    private var phase: InputMethodSessionPhase = .idle
    private var rightCommandIsDown = false
    private var rightCommandReleaseWorkItem: DispatchWorkItem?
    private var rightCommandTapKind: RightCommandTapKind?
    private var recordingReadinessGate = RecordingReadinessGate()
    private var completionGate = DictationCompletionGate(sessionID: UUID())
    private var sessionGeneration = UUID()
    private var stoppingFocusMonitorWorkItem: DispatchWorkItem?
    private var clipboardPublishWorkItem: DispatchWorkItem?
    private var currentDirectPasteIdentity: PasteOrderIdentity?
    private var currentPasteRoute: PasteRoute?
    private var pasteGeneration = UUID()
    private var previousFrontmostApp: NSRunningApplication?
    private var pasteTargetApp: NSRunningApplication?

    init(appState: AppState, overlayPanel: OverlayPanel, hotkeyManager: HotkeyManager,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.appState = appState
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
        let eventLogger = PasteOrderEventLogger(
            side: "controller",
            databaseURL: PasteOrderEventLogger.defaultDatabaseURL(side: "controller")
        )
        pasteOrderEventLogger = eventLogger

    }

    func start() {
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .toggleRecording:
                    self.handleToggle()
                case .toggleHotkeyFullyReleased:
                    self.handleToggleHotkeyFullyReleased()
                case .physicalRightCommandStopDown:
                    self.handlePhysicalRightCommandStopDown()
                case .physicalRightCommandStopUp:
                    self.handlePhysicalRightCommandStopUp()
                case .physicalRightCommandStopInterruptedByOrdinaryKey:
                    self.handlePhysicalRightCommandStopInterruptedByOrdinaryKey()
                case .cancel:
                    self.cancelSession()
                }
            }
        }
        overlayPanel.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelSession()
            }
        }
        overlayPanel.onCopyCurrentText = { [weak self] in self?.copyUnsavedCurrentText() }
        overlayPanel.onSnapshotChanged = { [weak self] snapshot in
            self?.handleTextSnapshot(snapshot)
        }
        hotkeyManager.setEscapeHandlingEnabled(false)
        hotkeyManager.start()
        print("[InputMethodSessionManager] ✅ IME bridge started")
    }

    func stop() {
        cancelSession()
        directPasteOrderCoordinator.cancelAllForShutdown()
        hotkeyManager.stop()
        appState.drafts.clearForShutdown()
    }

    private func handleToggle() {
        switch SessionTogglePolicy.action(for: phase) {
        case .start:
            startSession()
        case .ignoreWhileRecording:
            logSessionEvent("toggle_ignored_while_active")
            return
        case .cancel:
            cancelSession()
            print("[InputMethodSessionManager] Toggle cancelled the in-progress session")
        }
    }

    private func handleToggleHotkeyFullyReleased() {
        switch phase {
        case .preparing:
            applyReadinessAction(recordingReadinessGate.markHotkeyReleased())
        case .idle, .recording, .stopping, .recoveryRequired:
            return
        }
    }

    private func startSession() {
        // Capture before NSApp activation changes focus/zoom. This immutable
        // context also belongs to delayed outcomes from this particular session.
        let placement = OverlayPlacementContext.capture()
        currentOverlayPlacement = placement
        appState.drafts.pruneExpired()
        guard appState.drafts.canBegin else {
            showRecoveryNotice(appState.drafts.startFailureMessage)
            return
        }
        guard inputSourceManager.saveCurrentInputSource() else {
            showInputSourceError("无法保存当前输入法")
            return
        }

        invalidatePendingPaste()
        sessionGeneration = UUID()
        let generation = sessionGeneration
        recordingReadinessGate = RecordingReadinessGate()
        completionGate = DictationCompletionGate(sessionID: generation)
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Capture the destination at recording start. Do not infer it from a
        // window title or from whichever process is frontmost after dictation.
        pasteTargetApp = previousFrontmostApp
        NSApp.activate(ignoringOtherApps: true)
        let route = PasteRouter().route(for: pasteTargetApp)
        currentPasteRoute = route
        if route == .uuDirect {
            currentDirectPasteIdentity = directPasteOrderCoordinator.beginRecording(requestId: generation)
        } else {
            currentDirectPasteIdentity = nil
        }

        traceSequence += 1
        traceIdentities[generation] = currentDirectPasteIdentity ?? PasteOrderIdentity(
            requestId: generation, controllerSessionId: traceProcessID, sequence: traceSequence
        )
        sessionRoutes[generation] = route
        sessionPlacements[generation] = placement
        guard appState.drafts.begin(id: generation, route: route) else {
            if let identity = currentDirectPasteIdentity {
                directPasteOrderCoordinator.abandonRecording(identity: identity, reason: .recoveryStorageUnavailable)
            }
            traceIdentities.removeValue(forKey: generation)
            sessionRoutes.removeValue(forKey: generation)
            sessionPlacements.removeValue(forKey: generation)
            currentDirectPasteIdentity = nil
            currentPasteRoute = nil
            inputSourceManager.restorePreviousInputSource()
            activatePreviousFrontmostApp()
            showRecoveryNotice(appState.drafts.startFailureMessage)
            return
        }
        phase = .preparing
        logSessionEvent("session_started", route: route, target: pasteTargetApp)
        appState.transcriptionText = ""
        overlayPanel.beginTracking(sessionID: generation)
        appState.isWaitingForCommit = false
        appState.errorMessage = nil
        appState.recordingState = .starting
        hotkeyManager.setEscapeHandlingEnabled(true)
        hotkeyManager.setStopComboMonitoringEnabled(true)
        // Both readiness paths start immediately on the main actor. AppKit and
        // Text Input Services stay on their required thread; neither path waits
        // for a fixed delay or assumes the other has completed first.
        overlayPanel.showOverlay(placement: placement) { [weak self] focusIsReady in
            guard let self,
                  self.phase == .preparing,
                  self.sessionGeneration == generation else { return }
            guard focusIsReady else {
                self.cancelPreparingSession(
                    message: "无法聚焦临时输入框",
                    reason: .focusReadinessFailed
                )
                return
            }
            self.recordDirectLifecycleEvent(.focusReady)
            self.logSessionEvent("focus_ready", focusStatus: self.overlayPanel.textInputFocusStatus)
            self.applyReadinessAction(self.recordingReadinessGate.markFocusReady())
        }

        guard inputSourceManager.selectAndConfirmDoubaoInputSource() else {
            cancelPreparingSession(
                message: "未找到、未启用或无法确认豆包输入法",
                reason: .inputSourceSelectionFailed
            )
            return
        }
        guard phase == .preparing, sessionGeneration == generation else { return }
        recordDirectLifecycleEvent(.inputSourceReady)
        logSessionEvent("input_source_ready")
        applyReadinessAction(recordingReadinessGate.markInputSourceReady())
    }

    private func applyReadinessAction(_ action: RecordingReadinessGate.Action) {
        guard action == .postRightCommandStart, phase == .preparing else { return }
        postRightCommandTap(kind: .start) { [weak self] posted in
            guard let self, self.phase == .preparing else { return }
            guard posted else {
                self.cancelPreparingSession(
                    message: "无法发出右 Command 启动事件",
                    reason: .functionKeyPostFailed
                )
                return
            }
            self.recordDirectLifecycleEvent(.rightCommandStartTapCompleted)
            self.phase = .recording
            self.appState.recordingState = .recording
            self.logSessionEvent("right_command_start_completed", focusStatus: self.overlayPanel.textInputFocusStatus)
            print("[InputMethodSessionManager] ✅ Text client and Doubao input source ready; right Command tapped")
        }
    }

    private func handlePhysicalRightCommandStopDown() {
        guard phase == .recording || phase == .stopping else { return }
        logSessionEvent("physical_right_command_stop_down")
        if phase == .recording { beginStopping() }
        applyCompletionAction(completionGate.beginStopping(now: now()))
    }

    private func handlePhysicalRightCommandStopUp() {
        guard phase == .recording || phase == .stopping else { return }
        logSessionEvent(phase == .recording ? "physical_right_command_stop_up_without_down" : "physical_right_command_stop_up")
        if phase == .recording { beginStopping() }
        applyCompletionAction(completionGate.physicalKeyUp(now: now()))
    }

    private func beginStopping() {
        // Do not reacquire lost focus and mistake the resulting unmark for a commit.
        phase = .stopping
        appState.recordingState = .stopping
        scheduleStoppingFocusVerification(generation: sessionGeneration)
    }

    private func handlePhysicalRightCommandStopInterruptedByOrdinaryKey() {
        guard phase == .recording || phase == .stopping else { return }
        cancelSession(reason: .sessionCancelled, failure: .stopInterrupted)
    }

    private func handleTextSnapshot(_ snapshot: IMETextSnapshot) {
        guard phase == .preparing || phase == .recording || phase == .stopping,
              snapshot.sessionID == sessionGeneration else { return }
        let previous = completionGate.snapshot
        let action = completionGate.observe(snapshot, now: now())
        if previous?.hasMarkedText != snapshot.hasMarkedText {
            if snapshot.hasMarkedText { recordDirectLifecycleEvent(.markedTextStarted) }
            else if previous?.hasMarkedText == true { recordDirectLifecycleEvent(.markedTextCommitted) }
            logSessionEvent(snapshot.hasMarkedText ? "marked_text_started" : "marked_text_unmarked",
                            textLength: snapshot.text.count)
        }
        applyCompletionAction(action)
    }

    private func applyCompletionAction(_ action: DictationCompletionGate.Action) {
        switch action {
        case .none: break
        case .waitingLonger:
            appState.isWaitingForCommit = true
            logSessionEvent("commit_soft_deadline")
        case let .failed(reason):
            logSessionEvent("commit_wait_failed", reason: reason.rawValue)
            cancelSession(reason: reason == .focusLost ? .stoppingFocusLost : .markedTextCommitTimedOut,
                          failure: reason)
        case let .lockReady(revision):
            let generation = sessionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .stopping, self.sessionGeneration == generation else { return }
                let action = self.completionGate.lock(
                    revision: revision, now: self.now(),
                    focusConfirmed: self.overlayPanel.textInputFocusStatus.isConfirmed,
                    liveText: self.overlayPanel.currentText(), liveHasMarkedText: self.overlayPanel.hasMarkedText
                )
                self.applyCompletionAction(action)
            }
        case let .freeze(text):
            recordDirectLifecycleEvent(.finalTextLocked, textLength: text.count)
            logSessionEvent("final_text_locked", textLength: text.count)
            completeSession(withFrozenText: text)
        }
    }

    private func scheduleStoppingFocusVerification(generation: UUID) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .stopping, self.sessionGeneration == generation else { return }
            self.applyCompletionAction(self.completionGate.poll(
                now: self.now(), focusConfirmed: self.overlayPanel.textInputFocusStatus.isConfirmed
            ))
            if self.phase == .stopping, self.sessionGeneration == generation {
                self.scheduleStoppingFocusVerification(generation: generation)
            }
        }
        stoppingFocusMonitorWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stoppingFocusPollInterval, execute: workItem)
    }

    private func cancelStoppingSafetyMonitoring() {
        stoppingFocusMonitorWorkItem?.cancel()
        stoppingFocusMonitorWorkItem = nil
    }

    private func completeSession(withFrozenText frozenText: String) {
        guard phase == .stopping else { return }
        guard !rightCommandIsDown else {
            cancelSession(
                message: "右 Command 尚未释放；已安全取消，未复制或粘贴文字",
                reason: .functionKeyPostFailed, failure: .stopInterrupted
            )
            return
        }
        let text = frozenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            appState.drafts.discard(id: sessionGeneration)
            traceIdentities.removeValue(forKey: sessionGeneration)
            sessionRoutes.removeValue(forKey: sessionGeneration)
            sessionPlacements.removeValue(forKey: sessionGeneration)
            if let identity = currentDirectPasteIdentity {
                directPasteOrderCoordinator.abandonRecording(
                    identity: identity,
                    reason: .emptyTranscription
                )
            }
            closeSession(releasingRightCommand: false)
            print("[InputMethodSessionManager] ⚠️ Session completed with no text to copy")
            return
        }

        let target = pasteTargetApp
        // Freeze routing at recording start. A menu change applies to the next
        // recording and cannot create a late order without recording metadata.
        let route = currentPasteRoute ?? PasteRouter().route(for: target)
        let completedSessionID = sessionGeneration
        guard appState.drafts.markAwaitingDelivery(id: completedSessionID, text: text) else {
            retainUnsavedCurrentText()
            return
        }
        let generation = pasteGeneration
        let directIdentity = currentDirectPasteIdentity
        if route == .uuDirect, let directIdentity {
            directPasteOrderCoordinator.transcriptionReady(identity: directIdentity, textLength: text.count)
        } else if let directIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: directIdentity,
                reason: .routeUnavailableBeforeSubmit
            )
        }
        logPasteRoute(route, target: target, event: "session completion")
        logSessionEvent(
            "session_completion_authorized",
            sessionID: completedSessionID,
            route: route,
            target: target,
            textLength: text.count
        )
        if PasteRouter.shouldPrepublishLocalClipboard(for: route), !PasteHelper.copyOnly(text) {
            recordPasteOutcome(sessionID: completedSessionID, outcome: .notSent(.clipboardWriteFailed))
            closeSession(releasingRightCommand: false)
            return
        }
        closeSession(releasingRightCommand: false)
        schedulePaste(
            text,
            route: route,
            target: target,
            generation: generation,
            directIdentity: directIdentity,
            traceSessionID: completedSessionID
        )
        print("[InputMethodSessionManager] ✅ Session completed (text length: \(text.count))")
    }

    private func schedulePaste(
        _ text: String,
        route: PasteRoute,
        target: NSRunningApplication?,
        generation: UUID,
        directIdentity: PasteOrderIdentity?,
        traceSessionID: UUID
    ) {
        clipboardPublishWorkItem?.cancel()
        PasteHelper.cancelPendingPaste()
        if route != .uuDirect { pendingPasteSessionID = traceSessionID }
        let completion: (PasteOutcome) -> Void = { [weak self] outcome in
            self?.recordPasteOutcome(sessionID: traceSessionID, outcome: outcome)
        }
        switch route {
        case .local, .uuCompatibility:
            waitUntilPasteTargetIsFrontmost(target: target, generation: generation) { [weak self] isFrontmost in
                guard let self else { return }
                guard isFrontmost else { completion(.notSent(.targetNotFrontmost)); return }
                if route == .local {
                    PasteHelper.copyAndPasteLocally(text, completion: completion)
                } else {
                    PasteHelper.copyAndPasteForUUCompatibility(text, isPasteTargetFrontmost: { [weak self] in
                        guard let self, self.pasteGeneration == generation else { return false }
                        return self.isPasteTargetFrontmost(target)
                    }, completion: completion)
                }
            }
        case .uuDirect:
            guard let identity = directIdentity else { completion(.notSent(.remoteRejected)); return }
            directPasteOrderCoordinator.submit(identity: identity, text: text,
                targetProcessIdentifier: target?.processIdentifier, targetBundleIdentifier: target?.bundleIdentifier)
        }
    }

    private func recordPasteOutcome(sessionID: UUID, outcome: PasteOutcome) {
        defer {
            if pendingPasteSessionID == sessionID {
                pendingPasteSessionID = nil
                clipboardPublishWorkItem?.cancel()
                clipboardPublishWorkItem = nil
            }
            traceIdentities.removeValue(forKey: sessionID)
            sessionRoutes.removeValue(forKey: sessionID)
            sessionPlacements.removeValue(forKey: sessionID)
        }
        guard let entry = appState.drafts.entries.first(where: { $0.id == sessionID }),
              entry.delivery == .recording || entry.delivery == .awaitingDelivery else { return }
        let event: String
        switch outcome {
        case .eventPosted: event = "paste_event_posted"
        case .notSent: event = "paste_not_sent"
        case .unknown: event = "paste_result_unknown"
        }
        logSessionEvent(event, sessionID: sessionID, reason: outcome.reason?.rawValue ?? "none", textLength: entry.textLength)
        appState.drafts.finish(id: sessionID, outcome: outcome)
        if let reason = outcome.reason {
            let message = entry.textLength == 0
                ? reason.message
                : "\(reason.message)，文字已保留。请从菜单打开恢复列表。"
            showRecoveryNotice(message, placement: sessionPlacements[sessionID])
        }
    }

    private func waitUntilPasteTargetIsFrontmost(
        target: NSRunningApplication?,
        attemptsRemaining: Int? = nil,
        generation: UUID,
        then work: @escaping (Bool) -> Void
    ) {
        guard generation == pasteGeneration else { return }
        let remainingAttempts = attemptsRemaining ?? Int(Self.frontmostWaitBudget / Self.frontmostPollInterval)
        let isReady = isPasteTargetFrontmost(target)
        if isReady || remainingAttempts <= 0 {
            work(isReady)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.waitUntilPasteTargetIsFrontmost(
                target: target,
                attemptsRemaining: remainingAttempts - 1,
                generation: generation,
                then: work
            )
        }
        clipboardPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frontmostPollInterval, execute: workItem)
    }

    private func cancelSession(
        message: String = "Session cancelled and previous input source restored",
        reason: DirectPasteCancellationReason = .sessionCancelled,
        failure: PasteFailureReason? = nil
    ) {
        invalidatePendingPaste()
        guard phase != .idle else { return }
        logSessionEvent(
            "session_cancelled",
            reason: failure?.rawValue ?? reason.rawValue,
            focusStatus: overlayPanel.textInputFocusStatus
        )
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: identity,
                reason: reason
            )
        }
        if let failure {
            guard appState.drafts.capture(id: sessionGeneration, text: overlayPanel.currentText(), committed: false) else {
                retainUnsavedCurrentText()
                return
            }
            recordPasteOutcome(sessionID: sessionGeneration, outcome: .notSent(failure))
        } else {
            appState.drafts.discard(id: sessionGeneration)
            traceIdentities.removeValue(forKey: sessionGeneration)
            sessionRoutes.removeValue(forKey: sessionGeneration)
            sessionPlacements.removeValue(forKey: sessionGeneration)
        }
        closeSession()
        print("[InputMethodSessionManager] \(message)")
    }

    private func retainUnsavedCurrentText() {
        completionGate.cancel()
        cancelStoppingSafetyMonitoring()
        phase = .recoveryRequired
        appState.isWaitingForCommit = false
        appState.errorMessage = "无法保存临时记录。文字仍在此处，请复制后再退出；ESC会丢弃。"
        hotkeyManager.setStopComboMonitoringEnabled(false)
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(identity: identity, reason: .recoveryStorageUnavailable)
        }
        logSessionEvent("recovery_storage_failed", reason: "recovery_storage_unavailable", textLength: overlayPanel.currentText().count)
        overlayPanel.showStorageFailure()
    }

    private func copyUnsavedCurrentText() {
        guard phase == .recoveryRequired else { return }
        guard overlayPanel.copyRetainedText(using: PasteHelper.copyOnly) else {
            appState.errorMessage = "复制失败，文字仍保留在此处；请重试，ESC会丢弃。"
            return
        }
        cancelSession()
        showRecoveryNotice("当前文字已复制；此次未能保存历史记录，请手动粘贴。")
    }

    private func closeSession(releasingRightCommand: Bool = true) {
        logSessionEvent("session_closing", focusStatus: overlayPanel.textInputFocusStatus)
        hotkeyManager.cancelStopHotkeyReleaseTracking()
        recordingReadinessGate.cancel()
        completionGate.cancel()
        cancelStoppingSafetyMonitoring()
        sessionGeneration = UUID()
        // Do not retain the completed transcript in the old gate during idle.
        completionGate = DictationCompletionGate(sessionID: sessionGeneration)
        overlayPanel.cancelTextInputFocusRequest()
        if releasingRightCommand {
            releaseRightCommandIfNeeded()
        }
        phase = .idle
        hotkeyManager.setEscapeHandlingEnabled(false)
        hotkeyManager.setStopComboMonitoringEnabled(false)
        overlayPanel.hideOverlay()
        inputSourceManager.restorePreviousInputSource()
        overlayPanel.clearText()
        activatePreviousFrontmostApp()
        appState.reset()
        currentDirectPasteIdentity = nil
        currentPasteRoute = nil
    }

    private func activatePreviousFrontmostApp() {
        let app = previousFrontmostApp
        previousFrontmostApp = nil
        guard let app, !app.isTerminated else { return }
        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func invalidatePendingPaste() {
        if let pendingPasteSessionID {
            recordPasteOutcome(sessionID: pendingPasteSessionID, outcome: .notSent(.superseded))
        }
        pasteGeneration = UUID()
        clipboardPublishWorkItem?.cancel()
        clipboardPublishWorkItem = nil
        PasteHelper.cancelPendingPaste()
    }

    private func isPasteTargetFrontmost(_ target: NSRunningApplication?) -> Bool {
        PasteRouter.targetIsReady(expectedPID: target?.processIdentifier,
                                  frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                  isTerminated: target?.isTerminated ?? true)
    }

    private func logPasteRoute(_ route: PasteRoute, target: NSRunningApplication?, event: String) {
        let bundleIdentifier = target?.bundleIdentifier ?? "<none>"
        let processIdentifier = target.map(\.processIdentifier) ?? -1
        print("[InputMethodSessionManager] route=\(route) targetBundle=\(bundleIdentifier) targetPID=\(processIdentifier) event=\(event)")
    }

    private func logSessionEvent(
        _ event: String,
        sessionID: UUID? = nil,
        reason: String = "none",
        route: PasteRoute? = nil,
        target: NSRunningApplication? = nil,
        textLength: Int = -1,
        focusStatus: TextInputFocusStatus? = nil
    ) {
        let resolvedID = sessionID ?? sessionGeneration
        let resolvedSessionID = resolvedID.uuidString
        let resolvedRoute = route ?? sessionRoutes[resolvedID] ?? currentPasteRoute
        let snapshot = completionGate.snapshot.flatMap { $0.sessionID == resolvedID ? $0 : nil }
        if let identity = traceIdentities[resolvedID] {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            pasteOrderEventLogger.capture(
                identity: identity, event: "session." + event,
                protocolVersion: RemoteClipboardClient.protocolVersion,
                textLength: textLength >= 0 ? textLength : snapshot?.text.count,
                detailsJSON: SessionDiagnostics.details(snapshot: snapshot, route: resolvedRoute,
                    phase: phase, reason: reason, version: "\(version) (\(build))")
            )
        }
        let phaseName = String(describing: phase)
        let routeName = resolvedRoute.map { String(describing: $0) } ?? "none"
        let resolvedFocus = String(describing: focusStatus ?? overlayPanel.textInputFocusStatus)
        let targetApp = target ?? pasteTargetApp
        let targetPID = targetApp?.processIdentifier ?? -1
        let targetBundleIdentifier = targetApp?.bundleIdentifier ?? "none"
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmostApp?.processIdentifier ?? -1
        let frontmostBundleIdentifier = frontmostApp?.bundleIdentifier ?? "none"
        let hasMarkedText = overlayPanel.hasMarkedText
        sessionLogger.notice(
            "event=\(event, privacy: .public) session=\(resolvedSessionID, privacy: .public) phase=\(phaseName, privacy: .public) route=\(routeName, privacy: .public) focus=\(resolvedFocus, privacy: .public) marked=\(hasMarkedText, privacy: .public) rightCommandDown=\(self.rightCommandIsDown, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) frontmostPID=\(frontmostPID, privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public) textLength=\(textLength, privacy: .public) targetPID=\(targetPID, privacy: .public) targetBundle=\(targetBundleIdentifier, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func postRightCommandTap(kind: RightCommandTapKind, completion: @escaping (Bool) -> Void) {
        guard !rightCommandIsDown,
              RightCommandInjector.post(isPressed: true)
        else {
            completion(false)
            return
        }
        rightCommandIsDown = true
        rightCommandTapKind = kind
        logSessionEvent("\(kind.diagnosticPrefix)_down")
        let generation = sessionGeneration
        let releaseWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.rightCommandIsDown else { return }
            guard RightCommandInjector.post(isPressed: false) else {
                self.logSessionEvent("\(kind.diagnosticPrefix)_up_failed")
                completion(false)
                return
            }
            self.rightCommandIsDown = false
            self.rightCommandTapKind = nil
            self.logSessionEvent("\(kind.diagnosticPrefix)_up")
            completion(true)
        }
        rightCommandReleaseWorkItem = releaseWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rightCommandPressDuration, execute: releaseWorkItem)
    }

    private func releaseRightCommandIfNeeded() {
        rightCommandReleaseWorkItem?.cancel()
        rightCommandReleaseWorkItem = nil
        guard rightCommandIsDown else { return }
        let kind = rightCommandTapKind
        guard RightCommandInjector.post(isPressed: false) else {
            logSessionEvent("right_command_release_retry_failed")
            print("[InputMethodSessionManager] ⚠️ Failed to release synthetic right Command; retaining down state")
            return
        }
        rightCommandIsDown = false
        rightCommandTapKind = nil
        if let kind {
            logSessionEvent("\(kind.diagnosticPrefix)_up")
        }
    }

    private func recordDirectLifecycleEvent(
        _ event: DirectPasteLifecycleEvent,
        textLength: Int? = nil
    ) {
        guard let identity = currentDirectPasteIdentity else { return }
        directPasteOrderCoordinator.recordLifecycleEvent(
            identity: identity,
            event: event,
            textLength: textLength
        )
    }

    private func cancelPreparingSession(
        message: String,
        reason: DirectPasteCancellationReason
    ) {
        guard phase == .preparing else { return }
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(identity: identity, reason: reason)
        }
        appState.drafts.discard(id: sessionGeneration)
        traceIdentities.removeValue(forKey: sessionGeneration)
        sessionRoutes.removeValue(forKey: sessionGeneration)
        sessionPlacements.removeValue(forKey: sessionGeneration)
        showRecoveryNotice(message)
        closeSession()
        print("[InputMethodSessionManager] ❌ \(message)")
    }

    private func showRecoveryNotice(_ message: String, placement: OverlayPlacementContext? = nil) {
        appState.recoveryNotice = RecoveryNotice(message: message,
            placement: placement ?? currentOverlayPlacement ?? OverlayPlacementContext.capture())
    }

    private func showInputSourceError(_ message: String) {
        showRecoveryNotice(message)
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: identity,
                reason: .inputSourceSelectionFailed
            )
        }
        if phase != .idle {
            closeSession()
        }
        print("[InputMethodSessionManager] ❌ \(message)")
    }
}

/// Posts the public virtual-key equivalent of the physical right Command key.
private enum RightCommandInjector {
    @discardableResult
    static func post(isPressed: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 54, // kVK_RightCommand
                  keyDown: isPressed
              )
        else {
            return false
        }

        event.flags = isPressed ? [.maskCommand, .maskNonCoalesced] : .maskNonCoalesced
        event.type = .flagsChanged
        functionKeyDiagnosticsLogger.notice(
            "origin=injector isPressed=\(isPressed, privacy: .public) eventType=\(event.type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public)"
        )
        event.post(tap: .cghidEventTap)
        return true
    }
}
