import AppKit
import SwiftUI

enum TextInputFocusStatus: Equatable {
    case confirmed
    case textViewUnavailable
    case panelNotKey
    case textViewNotFirstResponder

    static func evaluate(
        panelIsKeyWindow: Bool,
        textViewIsAvailable: Bool,
        textViewIsFirstResponder: Bool
    ) -> TextInputFocusStatus {
        guard textViewIsAvailable else { return .textViewUnavailable }
        guard panelIsKeyWindow else { return .panelNotKey }
        guard textViewIsFirstResponder else { return .textViewNotFirstResponder }
        return .confirmed
    }

    var isConfirmed: Bool {
        self == .confirmed
    }
}

class OverlayPanel: NSPanel {
    private let appState: AppState
    private let textClients = IMETextClientSession()
    private weak var textView: IMETrackingTextView?
    private var focusRequestID: UUID?
    private var focusCompletion: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onCopyCurrentText: (() -> Void)?
    var onMarkedTextStateChanged: ((Bool) -> Void)?
    var onSnapshotChanged: ((IMETextSnapshot) -> Void)?
    private var trackingSessionID: UUID?
    private var placement: OverlayPlacementContext?
    private var requestedHeight: CGFloat = 76

    override var canBecomeKey: Bool { true }

    init(appState: AppState) {
        self.appState = appState

        // Initial hidden frame; each session supplies its own placement.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(
            contentRect: OverlayGeometry.frame(in: screenFrame, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        // The SwiftUI material is backed by an NSVisualEffectView whose blur
        // bleeds past the rounded card as faint square corners in a
        // transparent borderless window. Clip the window's content layer to
        // the card's corners; the window shadow then follows the rounded
        // opaque region on its own.
        self.hasShadow = true
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 16
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displayConfigurationChanged() {
        guard isVisible, let placement else { return }
        setFrame(placement.frame(height: requestedHeight, displays: OverlayDisplay.current), display: true)
    }

    func showOverlay(placement: OverlayPlacementContext, onFocusReady: @escaping (Bool) -> Void) {
        self.placement = placement
        requestedHeight = 76
        setFrame(placement.frame(height: 76, displays: OverlayDisplay.current), display: true)
        orderFrontRegardless()
        requestTextInputFocus(onReady: onFocusReady)
        print("[OverlayPanel] ✅ Overlay is now visible (isVisible=\(isVisible), isKeyWindow=\(isKeyWindow))")
    }

    /// Make this panel's text view the client before the user presses physical
    /// right Command to stop, then return the
    /// actual AppKit focus state. Callers must treat any non-confirmed state as
    /// a cancellation, never as proof that an IME commit occurred.
    @discardableResult
    func ensureTextInputFocus() -> TextInputFocusStatus {
        guard let textView else { return .textViewUnavailable }
        makeKey()
        let accepted = makeFirstResponder(textView)
        let status = textInputFocusStatus
        // Treat a refusal as failure even if an AppKit transition happened to
        // leave the old responder in place. We need both an accepted request
        // and the observable responder identity before accepting marked-text
        // commit as the session's final text.
        guard accepted else {
            return status.isConfirmed ? .textViewNotFirstResponder : status
        }
        return status
    }

    var textInputFocusStatus: TextInputFocusStatus {
        TextInputFocusStatus.evaluate(
            panelIsKeyWindow: isKeyWindow,
            textViewIsAvailable: textView != nil,
            textViewIsFirstResponder: textView.map { firstResponder === $0 } ?? false
        )
    }

    func cancelTextInputFocusRequest() {
        focusRequestID = nil
        focusCompletion = nil
    }

    var hasMarkedText: Bool {
        textView?.hasMarkedText() ?? false
    }

    func hideOverlay() {
        print("[OverlayPanel] hideOverlay called")
        resignKey()
        orderOut(nil)
    }

    /// Read directly from the AppKit text client before the panel is dismissed.
    /// This remains reliable even if SwiftUI's binding has not caught up with an
    /// input method's final committed text.
    func currentText() -> String {
        textView?.string ?? appState.transcriptionText
    }

    /// Clear the AppKit text client synchronously so a previous session's text
    /// cannot be drawn during the next panel presentation.
    func beginTracking(sessionID: UUID) {
        trackingSessionID = sessionID
        textView = nil
        let client = textClients.begin(sessionID: sessionID)
        let hostingView = NSHostingView(rootView: OverlayView(appState: appState, textView: client, onCopyCurrentText: { [weak self] in self?.onCopyCurrentText?() }) { [weak self] view in
            guard let self, self.trackingSessionID == sessionID, self.textClients.current === view else { return }
            self.installTextView(view)
        })
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    func showStorageFailure() {
        textClients.current?.freezeForRecovery()
        guard let placement else { return }
        requestedHeight = 180
        setFrame(placement.frame(height: 180, displays: OverlayDisplay.current), display: true)
        if textInputFocusStatus.isConfirmed {
            OverlayZoomSupport.reveal(frame: frame, mode: placement.mode)
        }
    }

    func copyRetainedText(using write: (String) -> Bool) -> Bool {
        textClients.current?.copyRecoveryText(using: write) ?? false
    }

    func clearText() {
        trackingSessionID = nil
        textClients.retire()
        textView = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            print("[OverlayPanel] ESC key received via keyDown")
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func installTextView(_ textView: IMETrackingTextView) {
        self.textView = textView
        textView.onSnapshotChanged = { [weak self] in self?.onSnapshotChanged?($0) }
        textView.onMarkedTextStateChanged = { [weak self] hasMarkedText in
            self?.onMarkedTextStateChanged?(hasMarkedText)
        }
        attemptPendingTextInputFocus()
    }

    private func requestTextInputFocus(onReady: @escaping (Bool) -> Void) {
        let requestID = UUID()
        focusRequestID = requestID
        focusCompletion = onReady
        attemptPendingTextInputFocus()
    }

    private func attemptPendingTextInputFocus() {
        guard let requestID = focusRequestID,
              let textView else { return }
        makeKey()
        let accepted = makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self,
                  let textView,
                  self.focusRequestID == requestID else { return }
            let confirmed = accepted
                && self.isKeyWindow
                && self.firstResponder === textView
            let completion = self.focusCompletion
            self.focusRequestID = nil
            self.focusCompletion = nil
            if confirmed, let placement = self.placement {
                OverlayZoomSupport.reveal(frame: self.frame, mode: placement.mode)
            }
            completion?(confirmed)
        }
    }
}
