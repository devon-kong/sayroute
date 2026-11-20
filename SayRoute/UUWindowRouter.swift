import AppKit

/// All keys are live AX window identities. No device selection is persisted here.
@MainActor
final class UUWindowRouter {
    typealias Connections = () async throws -> [UUConnection]
    private struct Binding {
        let id = UUID()
        let session: Task<UUConnection, Error>
    }

    private let connections: Connections
    private var windows: [AXUIElement: Binding] = [:]

    init(connections: @escaping Connections = UUDevices.connections) {
        self.connections = connections
    }

    func knows(_ window: AXUIElement) -> Bool { windows[window] != nil }

    func forget(_ window: AXUIElement) {
        windows.removeValue(forKey: window)?.session.cancel()
    }

    func reset() {
        for binding in windows.values { binding.session.cancel() }
        windows.removeAll()
    }

    /// Reserve the window synchronously. A hotkey just after entering fullscreen
    /// can await the original name lookup, even when the name has already vanished.
    func learn(_ snapshot: UUWindowSnapshot) {
        guard snapshot.label != nil, !knows(snapshot.window) else { return }
        _ = bind(snapshot)
    }

    private func bind(_ snapshot: UUWindowSnapshot) -> Binding {
        let task = Task { [connections] () throws -> UUConnection in
            // The window may appear a moment before UU publishes its session.
            for delay in [0, 250, 650] {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                try Task.checkCancellation()
                let sessions: [UUConnection]
                do { sessions = try await connections() }
                catch PasteFailureReason.uuStatusUnavailable where delay != 650 { continue }
                let matches = sessions.filter { $0.isActive && $0.deviceName == snapshot.label }
                if matches.isEmpty { continue }
                guard matches.count == 1, let match = matches.first, match.platform == "mac",
                      let start = Self.startDate(match.connectionStartTime),
                      start <= snapshot.capturedAt else { throw PasteFailureReason.uuWindowUnidentified }
                try Task.checkCancellation()
                return match
            }
            throw PasteFailureReason.uuWindowUnidentified
        }
        let binding = Binding(session: task)
        // A missed destruction event must not retain an unbounded number of AX objects.
        if windows.count >= 64, windows[snapshot.window] == nil, let old = windows.keys.first { forget(old) }
        windows[snapshot.window] = binding
        Task { [weak self] in
            if case .failure = await task.result, self?.windows[snapshot.window]?.id == binding.id {
                self?.windows.removeValue(forKey: snapshot.window)
            }
        }
        return binding
    }

    /// Called before the IME takes focus. Nothing after this call reads focus
    /// again to decide where this particular recording should go.
    func destination(for snapshot: UUWindowSnapshot?, bindings: [UUBinding]) -> Task<UUTarget, Error> {
        guard let snapshot else { return Task { throw PasteFailureReason.uuWindowUnidentified } }
        let binding: Binding
        if snapshot.label != nil {
            binding = bind(snapshot)
        } else if snapshot.isFullscreen, let known = windows[snapshot.window] {
            binding = known
        } else {
            let reason: PasteFailureReason = snapshot.isFullscreen ? .uuFullscreenNeedsName : .uuWindowUnidentified
            return Task { throw reason }
        }

        return Task { [weak self, connections] in
            let session = try await binding.session.value
            try Task.checkCancellation()
            let target = try UUTarget.resolve(labels: [session.deviceName], connections: [session], bindings: bindings)
            if snapshot.isFullscreen {
                let live = try await connections()
                do {
                    try target.validate(connections: live, bindings: bindings)
                } catch {
                    if self?.windows[snapshot.window]?.id == binding.id { self?.forget(snapshot.window) }
                    throw error
                }
            }
            return target
        }
    }

    private static func startDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }
}
