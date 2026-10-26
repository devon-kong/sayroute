import Foundation

/// Deliberately closed field set; the text itself and its hash are never encoded.
enum SessionDiagnostics {
    static func details(snapshot: IMETextSnapshot?, route: PasteRoute?, phase: InputMethodSessionPhase,
                        reason: String, version: String) -> String {
        let fields: [String: Any] = [
            "revision": snapshot.map { Int(clamping: $0.revision) } ?? 0,
            "has_marked_text": snapshot?.hasMarkedText ?? false,
            "text_length": snapshot?.text.count ?? 0,
            "route": route.map { String(describing: $0) } ?? "none",
            "phase": String(describing: phase), "reason": reason, "app_version": version
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
