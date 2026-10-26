import Foundation
import Combine

enum LoginStatus: String {
    case checking = "检查中..."
    case loggedIn = "已登录"
    case notLoggedIn = "未登录"
}

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

    @Published var loginStatus: LoginStatus = .checking
    @Published var recordingState: RecordingState = .idle
    @Published var transcriptionText: String = ""
    @Published var showOverlay: Bool = false
    @Published var errorMessage: String?

    var isRecording: Bool {
        recordingState == .recording || recordingState == .starting
    }

    func reset() {
        recordingState = .idle
        isWaitingForCommit = false
        transcriptionText = ""
        showOverlay = false
        errorMessage = nil
    }
}
