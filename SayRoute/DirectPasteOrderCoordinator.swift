import Foundation

enum DirectPasteOrderState: Equatable {
    case recording
    case created
    case sending
    case acknowledgedEventPosted
    case unconfirmed
    case cancelled
}

enum DirectPasteCancellationReason: String, Equatable {
    case recoveryStorageUnavailable = "recovery_storage_unavailable"
    case emptyTranscription = "empty_transcription"
    case sessionCancelled = "session_cancelled"
    case inputSourceSelectionFailed = "input_source_selection_failed"
    case routeUnavailableBeforeSubmit = "route_unavailable_before_submit"
    case focusReadinessFailed = "focus_readiness_failed"
    case functionKeyPostFailed = "function_key_post_failed"
    case stoppingFocusLost = "stopping_focus_lost"
    case markedTextCommitTimedOut = "marked_text_commit_timed_out"
}

enum DirectPasteLifecycleEvent: String, Equatable {
    case focusReady = "focus_ready"
    case inputSourceReady = "input_source_ready"
    case rightCommandStartTapCompleted = "right_command_start_tap_completed"
    case markedTextStarted = "marked_text_started"
    case markedTextCommitted = "marked_text_committed"
    case finalTextLocked = "final_text_locked"
}

enum RemoteClipboardTransportEvent: Equatable {
    case responseReceived(httpStatus: Int, durationMilliseconds: Double)
}

@MainActor
final class DirectPasteOrderCoordinator {
    typealias SendOperation = (
        _ text: String,
        _ identity: PasteOrderIdentity,
        _ target: UUTarget,
        _ transportEvent: @escaping (RemoteClipboardTransportEvent) -> Void
    ) async throws -> RemotePasteAcknowledgement

    private let logger: PasteOrderEventLogger
    private let verifyTarget: (UUTarget) async throws -> Void
    private var destinations: [UUID: Task<UUTarget, Error>] = [:]
    private let sendOperation: SendOperation
    private let onUnconfirmedCountChanged: (Int) -> Void
    private let onOutcome: (UUID, PasteOutcome) -> Void
    private var terminalOrder: [UUID] = []
    private(set) var controllerSessionId: UUID
    private var nextSequence: Int64 = 1
    private var states: [UUID: DirectPasteOrderState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeIdentities: [UUID: PasteOrderIdentity] = [:]

    init(
        logger: PasteOrderEventLogger,
        controllerSessionId: UUID = UUID(),
        verifyTarget: @escaping (UUTarget) async throws -> Void = { target in
            let connections = try await UUDevices.connections()
            try target.validate(connections: connections, bindings: UUBindingStore().bindings)
        },
        sendOperation: @escaping SendOperation = { text, identity, target, transportEvent in
            try await RemoteClipboardClient(baseURL: target.url).paste(
                text: text,
                identity: identity,
                onTransportEvent: transportEvent
            )
        },
        onUnconfirmedCountChanged: @escaping (Int) -> Void = { _ in },
        onOutcome: @escaping (UUID, PasteOutcome) -> Void = { _, _ in }
    ) {
        self.logger = logger
        self.controllerSessionId = controllerSessionId
        self.verifyTarget = verifyTarget
        self.sendOperation = sendOperation
        self.onUnconfirmedCountChanged = onUnconfirmedCountChanged
        self.onOutcome = onOutcome
    }

    func beginRecording(requestId: UUID = UUID(), destination: Task<UUTarget, Error>) -> PasteOrderIdentity {
        let identity = PasteOrderIdentity(
            requestId: requestId,
            controllerSessionId: controllerSessionId,
            sequence: nextSequence
        )
        destinations[requestId] = destination
        nextSequence += 1
        states[identity.requestId] = .recording
        logger.capture(
            identity: identity,
            event: "recording_started",
            protocolVersion: RemoteClipboardClient.protocolVersion
        )
        return identity
    }

    func transcriptionReady(identity: PasteOrderIdentity, textLength: Int) {
        guard states[identity.requestId] == .recording else { return }
        logger.capture(
            identity: identity,
            event: "transcription_ready",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: textLength
        )
    }

    func recordLifecycleEvent(
        identity: PasteOrderIdentity,
        event: DirectPasteLifecycleEvent,
        textLength: Int? = nil
    ) {
        guard states[identity.requestId] == .recording else { return }
        logger.capture(
            identity: identity,
            event: event.rawValue,
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: textLength
        )
    }

    func submit(
        identity: PasteOrderIdentity,
        text: String,
        targetProcessIdentifier: Int32?,
        targetBundleIdentifier: String?
    ) {
        guard states[identity.requestId] == .recording, !text.isEmpty,
              let destination = destinations.removeValue(forKey: identity.requestId) else { return }
        states[identity.requestId] = .created
        logger.capture(
            identity: identity,
            event: "request_created",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: text.count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier
        )
        states[identity.requestId] = .sending

        let requestId = identity.requestId
        activeIdentities[requestId] = identity
        tasks[requestId] = Task { [weak self, logger = self.logger, sendOperation = self.sendOperation, verifyTarget = self.verifyTarget] in
            do {
                let target = try await destination.value
                try Task.checkCancellation()
                try await verifyTarget(target)
                try Task.checkCancellation()
                logger.capture(
                    identity: identity,
                    event: "http_send_started",
                    protocolVersion: RemoteClipboardClient.protocolVersion,
                    textLength: text.count,
                    targetProcessIdentifier: targetProcessIdentifier,
                    targetBundleIdentifier: targetBundleIdentifier
                )
                let acknowledgement = try await sendOperation(text, identity, target) { transportEvent in
                    switch transportEvent {
                    case let .responseReceived(status, duration):
                        logger.capture(
                            identity: identity,
                            event: "response_received",
                            protocolVersion: RemoteClipboardClient.protocolVersion,
                            textLength: text.count,
                            httpStatus: status,
                            durationMilliseconds: duration
                        )
                    }
                }
                guard let self else { return }
                self.states[requestId] = .acknowledgedEventPosted
                self.logger.capture(
                    identity: identity,
                    event: "ack_validated",
                    protocolVersion: RemoteClipboardClient.protocolVersion,
                    textLength: text.count,
                    targetProcessIdentifier: acknowledgement.targetProcessIdentifier,
                    targetBundleIdentifier: acknowledgement.targetBundleIdentifier,
                    pasteboardChangeCount: acknowledgement.changeCount
                )
                self.tasks[requestId] = nil
                self.activeIdentities[requestId] = nil
                self.publishUnconfirmedCount()
                self.onOutcome(requestId, .eventPosted)
                self.pruneTerminal(requestId)
            } catch {
                guard let self else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self.states[requestId] = .cancelled
                    self.tasks[requestId] = nil
                    self.activeIdentities[requestId] = nil
                    self.publishUnconfirmedCount()
                    return
                }
                let isTimeout = (error as? URLError)?.code == .timedOut
                if isTimeout {
                    self.logger.capture(
                        identity: identity,
                        event: "timeout",
                        protocolVersion: RemoteClipboardClient.protocolVersion,
                        textLength: text.count,
                        errorCode: Int32(URLError.timedOut.rawValue)
                    )
                }
                let blocked = error is PasteFailureReason
                self.states[requestId] = blocked ? .cancelled : .unconfirmed
                let nsErrorCode = (error as NSError).code
                self.logger.capture(
                    identity: identity,
                    event: blocked ? "target_unavailable" : "unconfirmed",
                    protocolVersion: RemoteClipboardClient.protocolVersion,
                    textLength: text.count,
                    errorCode: (Int(Int32.min)...Int(Int32.max)).contains(nsErrorCode) ? Int32(nsErrorCode) : nil,
                    detailsJSON: Self.safeErrorDetails(error)
                )
                self.tasks[requestId] = nil
                self.activeIdentities[requestId] = nil
                self.publishUnconfirmedCount()
                self.onOutcome(requestId, Self.outcome(for: error))
                self.pruneTerminal(requestId)

            }
        }
    }

    func abandonRecording(
        identity: PasteOrderIdentity,
        reason: DirectPasteCancellationReason
    ) {
        guard states[identity.requestId] == .recording else { return }
        destinations.removeValue(forKey: identity.requestId)?.cancel()
        states[identity.requestId] = .cancelled
        logger.capture(
            identity: identity,
            event: "task_cancelled",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            detailsJSON: Self.cancellationDetails(reason)
        )
        pruneTerminal(identity.requestId)
    }

    /// Direct HTTP work is cancelled only during actual application shutdown.
    func cancelAllForShutdown() {
        for destination in destinations.values { destination.cancel() }
        destinations.removeAll()
        for (requestId, task) in tasks {
            guard let identity = identityForActiveRequest(requestId) else {
                task.cancel()
                continue
            }
            logger.capture(
                identity: identity,
                event: "task_cancelled",
                protocolVersion: RemoteClipboardClient.protocolVersion,
                detailsJSON: "{\"reason\":\"application_shutdown\"}"
            )
            task.cancel()
        }
    }

    func state(for requestId: UUID) -> DirectPasteOrderState? {
        states[requestId]
    }

    var activeRequestCount: Int { tasks.count }
    var unconfirmedRequestCount: Int { states.values.filter { $0 == .unconfirmed }.count }

    private func publishUnconfirmedCount() {
        onUnconfirmedCountChanged(unconfirmedRequestCount)
    }

    private func identityForActiveRequest(_ requestId: UUID) -> PasteOrderIdentity? {
        activeIdentities[requestId]
    }

    private func pruneTerminal(_ id: UUID) {
        terminalOrder.append(id)
        while terminalOrder.count > 256 {
            states.removeValue(forKey: terminalOrder.removeFirst())
        }
    }

    static func outcome(for error: Error) -> PasteOutcome {
        if let reason = error as? PasteFailureReason { return .notSent(reason) }
        if let url = error as? URLError {
            if url.code == .cannotConnectToHost { return .notSent(.connectionUnavailable) }
            return .unknown(.transportUnknown)
        }
        if case let RemoteClipboardClientError.unexpectedStatus(status) = error {
            if status == 423 { return .notSent(.modifiersHeld) }
            if status == 403 { return .notSent(.remotePermissionDenied) }
            if [400, 409, 411, 413, 415, 422].contains(status) { return .notSent(.remoteRejected) }
        }
        return .unknown(.acknowledgementInvalid)
    }

    private static func safeErrorDetails(_ error: Error) -> String? {
        let type = String(describing: Swift.type(of: error))
        guard let data = try? JSONSerialization.data(withJSONObject: ["error_type": type]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func cancellationDetails(_ reason: DirectPasteCancellationReason) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["reason": reason.rawValue]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
