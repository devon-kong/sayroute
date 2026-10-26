import Foundation
import Combine

enum RecordingState {
    case idle
    case starting
    case recording
    case stopping
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    let drafts = SessionDraftStore()
    @Published var isWaitingForCommit = false
    @Published var recoveryNotice: RecoveryNotice?

    @Published var recordingState: RecordingState = .idle
    @Published var transcriptionText: String = ""
    @Published var errorMessage: String?

    func reset() {
        recordingState = .idle
        isWaitingForCommit = false
        transcriptionText = ""
        errorMessage = nil
    }
}
