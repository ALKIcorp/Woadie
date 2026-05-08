import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var appMode: AppMode = .quick
    @Published var logMode: LogMode = .auto
    @Published var engineStatus: EngineStatus = .off
    @Published var engineDiagnostics: [EngineDiagnostic] = []
    @Published var activeWorkspace: WorkspaceSession = WorkspaceSession()
    @Published var speechJobs: [SpeechJob] = []
    @Published var playback: PlaybackSnapshot = .idle
    @Published var dashboardTelemetry: DashboardTelemetry = .empty
    @Published var persistence: PersistenceSnapshot = .idle
    @Published var savedPackages: [SavedSpeechPackage] = []
    @Published var savedLogEntries: [SavedLogEntry] = []
    @Published var voiceOptions: [VoiceOption] = []
    @Published var composerText: String = ""
    @Published var userMessage: String = ""
    @Published var lastError: AlkiSpeakError?
    @Published var showPortInUseAlert: Bool = false
    @Published var portInUsePids: [Int32] = []

    var selectedVoiceID: String {
        get { activeWorkspace.selectedVoiceID }
        set {
            activeWorkspace.selectedVoiceID = newValue
            activeWorkspace.updatedAt = Date()
        }
    }

    func record(_ error: AlkiSpeakError) {
        lastError = error
        userMessage = error.message
        engineDiagnostics.insert(
            EngineDiagnostic(
                severity: .error,
                code: error.code,
                message: error.message,
                context: error.context
            ),
            at: 0
        )
    }

    func clearErrorMessage() {
        userMessage = ""
        lastError = nil
    }
}
