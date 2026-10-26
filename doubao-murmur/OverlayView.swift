import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    let textView: IMETrackingTextView
    let onCopyCurrentText: () -> Void
    let onTextViewReady: (IMETrackingTextView) -> Void

    var body: some View {
        HStack(spacing: 12) {
            RecordingDot(state: appState.recordingState)

            VStack(alignment: .leading, spacing: 3) {
                IMETextView(text: $appState.transcriptionText, client: textView, onTextViewReady: onTextViewReady)
                if let error = appState.errorMessage {
                    Text(error).font(.caption).foregroundColor(.orange)
                    Button("复制当前文字", action: onCopyCurrentText)
                }
                if appState.isWaitingForCommit {
                    Text("仍在等待输入法提交，超时会保留文字。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .circular)
                .fill(.ultraThinMaterial)
                .opacity(0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .circular)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

final class IMETrackingTextView: NSTextView {
    var onMarkedTextStateChanged: ((Bool) -> Void)?
    var onSnapshotChanged: ((IMETextSnapshot) -> Void)?
    private var suppressMarkedStateCallbacks = false
    private var lastReportedMarkedState: Bool?
    private var sessionID: UUID?
    private var boundSessionID: UUID?
    var isTracking: Bool { sessionID != nil }
    private var revision: UInt64 = 0
    private var lastSnapshot: IMETextSnapshot?
    private var inputMutationDepth = 0
    private var isRecoverySnapshot = false

    func beginTracking(sessionID: UUID) {
        // One text-input client belongs to exactly one IME session, forever.
        // A retained old client must never relabel late callbacks as a new session.
        guard boundSessionID == nil else { return }
        clearProgrammatically()
        boundSessionID = sessionID
        self.sessionID = sessionID
        isEditable = true
        revision = 0
        lastSnapshot = nil
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isTracking else { return }
        inputMutationDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputMutationDepth -= 1
        reportSnapshot()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isTracking else { return }
        inputMutationDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        inputMutationDepth -= 1
        reportSnapshot()
    }

    override func unmarkText() {
        guard isTracking else { return }
        inputMutationDepth += 1
        super.unmarkText()
        inputMutationDepth -= 1
        reportSnapshot()
    }

    override func didChangeText() {
        super.didChangeText()
        reportSnapshot()
    }

    func clearProgrammatically() {
        suppressMarkedStateCallbacks = true
        sessionID = nil
        super.unmarkText()
        string = ""
        setSelectedRange(NSRange(location: 0, length: 0))
        lastReportedMarkedState = false
        lastSnapshot = nil
        isRecoverySnapshot = false
        isEditable = false
        suppressMarkedStateCallbacks = false
    }

    /// This is the current failed input, not a second in-memory history cache.
    /// Keep it visible and stable until copied or explicitly discarded.
    func freezeForRecovery() {
        let text = string
        suppressMarkedStateCallbacks = true
        sessionID = nil
        super.unmarkText()
        string = text
        lastSnapshot = nil
        lastReportedMarkedState = false
        isRecoverySnapshot = true
        isEditable = false
        suppressMarkedStateCallbacks = false
    }

    func copyRecoveryText(using write: (String) -> Bool) -> Bool {
        guard isRecoverySnapshot else { return false }
        return write(string)
    }

    private func reportSnapshot() {
        guard !suppressMarkedStateCallbacks, inputMutationDepth == 0 else { return }
        let marked = hasMarkedText()
        if lastReportedMarkedState != marked {
            lastReportedMarkedState = marked
            onMarkedTextStateChanged?(marked)
        }
        guard let sessionID, lastSnapshot?.text != string || lastSnapshot?.hasMarkedText != marked else { return }
        revision += 1
        let value = IMETextSnapshot(sessionID: sessionID, revision: revision, text: string, hasMarkedText: marked)
        lastSnapshot = value
        onSnapshotChanged?(value)
    }
}

/// Owns the real ingress boundary, not just the IDs passed to the state machine.
final class IMETextClientSession {
    private(set) var current: IMETrackingTextView?

    func begin(sessionID: UUID) -> IMETrackingTextView {
        retire()
        let client = IMETrackingTextView(frame: .zero)
        client.beginTracking(sessionID: sessionID)
        current = client
        return client
    }

    func retire() {
        current?.onSnapshotChanged = nil
        current?.onMarkedTextStateChanged = nil
        current?.clearProgrammatically()
        current = nil
    }
}

/// Status indicator: a soft dot that breathes while recording and stays
/// quiet otherwise. Color carries the state, so no text label is needed.
private struct RecordingDot: View {
    let state: RecordingState
    @State private var breathing = false

    private var color: Color {
        switch state {
        case .recording: return .red
        case .starting, .stopping: return .orange
        case .idle: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
            .scaleEffect(breathing && state == .recording ? 1.35 : 1.0)
            .opacity(state == .recording ? (breathing ? 0.65 : 1.0) : 0.8)
            .animation(
                state == .recording
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: breathing
            )
            .onAppear { breathing = true }
    }
}

private struct IMETextView: NSViewRepresentable {
    @Binding var text: String
    let client: IMETrackingTextView
    let onTextViewReady: (IMETrackingTextView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = client
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = textView.isTracking
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        DispatchQueue.main.async {
            onTextViewReady(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // AppKit owns composition. A delayed SwiftUI binding must never
        // overwrite the final insertText result or create a synthetic commit.
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextView

        init(parent: IMETextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? IMETrackingTextView, textView.isTracking else { return }
            parent.text = textView.string
        }
    }
}
