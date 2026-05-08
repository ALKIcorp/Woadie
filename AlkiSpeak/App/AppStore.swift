import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var appMode: AppMode = .quick
    @Published var logMode: LogMode = .auto
    @Published var engineStatus: EngineStatus = .stopped
    @Published var engineHealth: EngineHealthSummary = .stopped
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
        if engineDiagnostics.count > AppConfig.maxBufferedDiagnostics {
            engineDiagnostics.removeLast(engineDiagnostics.count - AppConfig.maxBufferedDiagnostics)
        }
    }

    func record(_ issue: EngineIssue, severity: EngineDiagnostic.Severity = .error) {
        let error = AlkiSpeakError.engine(
            code: issue.code,
            title: issue.title,
            message: issue.description,
            recoverySuggestion: issue.probableCause,
            context: issue.context.merging([
                "subsystem": issue.subsystem,
                "retryCount": "\(issue.retryCount)",
                "rawError": issue.rawError ?? ""
            ]) { current, _ in current }
        )
        lastError = error
        userMessage = issue.description
        engineDiagnostics.insert(
            EngineDiagnostic(
                timestamp: issue.timestamp,
                severity: severity,
                code: issue.code,
                message: "\(issue.title): \(issue.description)",
                context: error.context
            ),
            at: 0
        )
        if engineDiagnostics.count > AppConfig.maxBufferedDiagnostics {
            engineDiagnostics.removeLast(engineDiagnostics.count - AppConfig.maxBufferedDiagnostics)
        }
    }

    func clearErrorMessage() {
        userMessage = ""
        lastError = nil
    }
}
