import CoreGraphics

enum BalancedPasteKeys {
    enum Result: String { case posted, modifiersHeld, eventCreationFailed }
    struct PreparedFlags {
        let initialHID: CGEventFlags
        let initialSession: CGEventFlags
        let down: CGEventFlags
        let up: CGEventFlags
    }
    static let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    static func hasHeldModifiers() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).union(CGEventSource.flagsState(.combinedSessionState))
            .intersection(shortcutModifiers).isEmpty
    }

    static func post(
        hidFlags: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
        sessionFlags: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
        emit: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        onPrepared: (PreparedFlags) -> Void = { _ in }
    ) -> Result {
        let initialHID = hidFlags()
        let initialSession = sessionFlags()
        guard initialHID.union(initialSession).intersection(shortcutModifiers).isEmpty else { return .modifiersHeld }
        // Allocate the complete pair before posting, so allocation failure cannot
        // leave a half-posted shortcut behind.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .eventCreationFailed }
        // Even a private source posted at the HID tap can affect global HID
        // flags. Prepare BOTH events before posting; a later global read may
        // contain our own Command and cannot identify physical user input.
        down.flags = initialHID.union(.maskCommand)
        up.flags = initialHID
        onPrepared(PreparedFlags(initialHID: initialHID, initialSession: initialSession,
                                 down: down.flags, up: up.flags))
        emit(down)
        emit(up)
        return .posted
    }
}
