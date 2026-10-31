import Combine
import Foundation
import Observation

/// Playback progress, which changes up to 30 times a second while audio
/// plays. It is observed field by field instead of through
/// `AppStore.objectWillChange`, so a tick re-renders only the views that read
/// the field that changed, not the whole window.
@MainActor
@Observable
final class PlaybackState {
    private(set) var state: PlaybackSnapshot.State = .idle
    private(set) var activeJobID: UUID?
    private(set) var activeLogEntryID: UUID?
    private(set) var currentSegmentID: UUID?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var bufferedDuration: TimeInterval = 0
    private(set) var statusMessage: String?

    var snapshot: PlaybackSnapshot {
        get {
            PlaybackSnapshot(
                state: state,
                activeJobID: activeJobID,
                activeLogEntryID: activeLogEntryID,
                currentSegmentID: currentSegmentID,
                elapsedTime: elapsedTime,
                duration: duration,
                bufferedDuration: bufferedDuration,
                statusMessage: statusMessage
            )
        }
        set {
            // Assign only what changed, so readers of unchanged fields stay put.
            if state != newValue.state { state = newValue.state }
            if activeJobID != newValue.activeJobID { activeJobID = newValue.activeJobID }
            if activeLogEntryID != newValue.activeLogEntryID { activeLogEntryID = newValue.activeLogEntryID }
            if currentSegmentID != newValue.currentSegmentID { currentSegmentID = newValue.currentSegmentID }
            if elapsedTime != newValue.elapsedTime { elapsedTime = newValue.elapsedTime }
            if duration != newValue.duration { duration = newValue.duration }
            if bufferedDuration != newValue.bufferedDuration { bufferedDuration = newValue.bufferedDuration }
            if statusMessage != newValue.statusMessage { statusMessage = newValue.statusMessage }
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var appMode: AppMode = .quick
    @Published var logMode: LogMode = .auto
    @Published var appearance: AppAppearance = .system
    @Published var selectedLogEntryID: UUID?
    @Published var engineStatus: EngineStatus = .stopped
    @Published var engineHealth: EngineHealthSummary = .stopped
    @Published var engineDiagnostics: [EngineDiagnostic] = []
    @Published var activeWorkspace: WorkspaceSession = WorkspaceSession()
    @Published var speechJobs: [SpeechJob] = []
    let playbackState = PlaybackState()
    var playback: PlaybackSnapshot {
        get { playbackState.snapshot }
        set { playbackState.snapshot = newValue }
    }
    @Published var dashboardTelemetry: DashboardTelemetry = .empty
    @Published var persistence: PersistenceSnapshot = .idle
    @Published var savedPackages: [SavedSpeechPackage] = []
    @Published var savedLogEntries: [SavedLogEntry] = []
    @Published var speechEntries: [SpeechEntry] = []
    @Published var voiceOptions: [VoiceOption] = [] {
        didSet { rebuildVoiceIndex() }
    }
    @Published var voiceFavorites: Set<String> = [] {
        didSet { rebuildVoiceIndex() }
    }
    /// The picker's grouped voices and an id → label lookup, rebuilt when the
    /// voice list or favorites change instead of on every render.
    private(set) var voiceSections: [VoiceGrouping.Section] = []
    private(set) var voiceDropdownSections: [AlkiDropdownSection] = []
    private(set) var voiceLabelsByID: [String: String] = [:]
    @Published var cloudSettings = CloudSpeechSettings()
    @Published var playbackTuning: PlaybackTuning = .default
    @Published var lastQueryResourceUsage: QueryResourceUsage?
    @Published var composerText: String = ""
    @Published var userMessage: String = ""
    @Published var selectedTextPermissionRequired: Bool = false
    @Published var lastError: AlkiSpeakError?
    @Published var showPortInUseAlert: Bool = false
    @Published var portInUsePids: [Int32] = []

    private func rebuildVoiceIndex() {
        voiceSections = VoiceGrouping.sections(voices: voiceOptions, favorites: voiceFavorites)
        voiceDropdownSections = VoicePickerView.dropdownSections(voiceSections, favorites: voiceFavorites)
        voiceLabelsByID = Dictionary(voiceOptions.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

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
