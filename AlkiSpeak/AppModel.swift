import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let store: AppStore
    private let dependencies: AppDependencies
    private let requestPolicy = EngineRequestPolicy.live
    private var cancellables: Set<AnyCancellable> = []

    var status: EngineStatus { store.engineStatus }
    var voiceOptions: [VoiceOption] { store.voiceOptions }
    var inputText: String {
        get { store.composerText }
        set { store.composerText = newValue }
    }
    var selectedVoice: String {
        get { store.selectedVoiceID }
        set { store.selectedVoiceID = newValue }
    }
    var message: String { store.userMessage }
    var engineCheckMessage: String? {
        guard let issue = store.engineHealth.latestIssue else { return nil }
        return "\(issue.title): \(issue.description) Probable cause: \(issue.probableCause)"
    }
    var chatItems: [SavedLogEntry] { store.savedLogEntries }
    var playingId: UUID? { store.playback.activeLogEntryID }
    var showPortInUseAlert: Bool {
        get { store.showPortInUseAlert }
        set { store.showPortInUseAlert = newValue }
    }
    var portInUsePids: [Int32] { store.portInUsePids }

    var canSpeak: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && (status.isAvailableForRemoteSpeech || isSelectedVoiceLocal)
    }

    var canEditText: Bool {
        status.isAvailableForRemoteSpeech || isSelectedVoiceLocal
    }

    var isEngineRunning: Bool {
        dependencies.engineSupervisor.isRunning
    }

    var startStopLabel: String {
        status.isProcessExpectedAlive ? "Stop Engine" : "Start Engine"
    }

    var startStopSystemImage: String {
        status.isProcessExpectedAlive ? "stop.fill" : "power"
    }

    var lastLatencyMsText: String {
        if let lastLatencyMs = store.dashboardTelemetry.lastLatencyMs {
            return "\(lastLatencyMs) ms"
        }
        return "-"
    }

    var lastCharCountText: String {
        if let lastCharCount = store.dashboardTelemetry.lastCharCount {
            return "\(lastCharCount)"
        }
        return "-"
    }

    var selectedVoiceLabel: String {
        voiceOptions.first(where: { $0.id == selectedVoice })?.label ?? "Select Voice"
    }

    var voiceCategories: [(title: String, voices: [VoiceOption])] {
        let local = voiceOptions.filter { $0.isLocal }
        let remote = voiceOptions.filter { !$0.isLocal }
        var categories: [(title: String, voices: [VoiceOption])] = []
        if !local.isEmpty {
            categories.append((title: "Apple", voices: local))
        }
        if !remote.isEmpty {
            categories.append((title: "Kokoro", voices: remote))
        }
        return categories
    }

    private var isSelectedVoiceLocal: Bool {
        selectedVoice.hasPrefix("apple:")
    }

    init(store: AppStore, dependencies: AppDependencies) {
        self.store = store
        self.dependencies = dependencies

        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        wireServiceCallbacks()
        loadWorkspace()
        refreshLocalVoices()
        if !AppConfig.isRunningUnitTests {
            Task { await bootstrapEngine() }
        }
    }

    func startEngine() {
        guard !dependencies.engineSupervisor.isRunning else { return }
        store.clearErrorMessage()
        store.engineStatus = .starting

        let pids = dependencies.engineSupervisor.findListeningPidsOnEnginePort()
        if !pids.isEmpty {
            store.engineStatus = .stopped
            store.userMessage = "Port \(AppConfig.enginePort) is already in use."
            store.portInUsePids = pids
            store.showPortInUseAlert = true
            return
        }

        do {
            try dependencies.engineSupervisor.start()
            refreshTelemetry()
        } catch {
            record(
                .engine(
                    code: "start-failed",
                    title: "Engine Start Failed",
                    message: "Failed to start the speech engine.",
                    recoverySuggestion: "Verify the Kokoro checkout and virtual environment path, then try again.",
                    underlyingError: error
                )
            )
            store.engineStatus = .failed
        }
    }

    func stopEngine() {
        store.clearErrorMessage()
        stopPlayback()
        dependencies.engineSupervisor.stop()
        store.engineStatus = .stopped
        refreshTelemetry()
    }

    func toggleEngine() {
        if status.isProcessExpectedAlive || dependencies.engineSupervisor.isRunning {
            stopEngine()
        } else {
            startEngine()
        }
    }

    func refreshVoices() {
        Task {
            refreshLocalVoices()
            await fetchVoices()
        }
    }

    func speak() {
        speak(text: inputText, addToHistory: true, targetLogEntryID: nil)
    }

    func replay(item: SavedLogEntry) {
        speak(text: item.text, addToHistory: false, targetLogEntryID: item.id)
    }

    func stopPlayback() {
        dependencies.playbackCoordinator.stop()
        dependencies.localSpeechService.stop()
        store.playback = .idle
        markActiveJobsCompleted()
    }

    func confirmPortSwitchAndStart() {
        Task {
            await dependencies.engineSupervisor.terminatePortUsers(store.portInUsePids)
            store.portInUsePids = []
            store.showPortInUseAlert = false
            startEngine()
        }
    }

    private func speak(text: String, addToHistory: Bool, targetLogEntryID: UUID?) {
        guard canSpeak else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.clearErrorMessage()

        let segments = requestPolicy.segments(for: trimmed)
        if segments.count > 1 {
            store.userMessage = "Large text split into \(segments.count) segments. Sending smaller engine requests to avoid request timeouts."
        }
        let logEntryID: UUID
        let jobID = UUID()

        if addToHistory {
            let entry = SavedLogEntry(id: UUID(), text: trimmed, isUser: true, jobID: jobID, segments: segments)
            store.savedLogEntries.insert(entry, at: 0)
            try? dependencies.logStore.saveLog(entry, workspaceID: store.activeWorkspace.id)
            logEntryID = entry.id
        } else if let targetLogEntryID {
            logEntryID = targetLogEntryID
        } else {
            logEntryID = UUID()
        }

        let job = SpeechJob(
            id: jobID,
            text: trimmed,
            voiceID: selectedVoice,
            segments: segments,
            status: .generating,
            logEntryID: logEntryID
        )
        store.speechJobs.insert(job, at: 0)
        store.playback = PlaybackSnapshot(
            state: .preparing,
            activeJobID: job.id,
            activeLogEntryID: logEntryID,
            currentSegmentID: segments.first?.id,
            elapsedTime: 0,
            duration: nil
        )

        Task {
            if isSelectedVoiceLocal {
                speakLocal(text: trimmed, jobID: job.id, logEntryID: logEntryID)
                return
            }
            await speakRemote(segments: segments, voice: selectedVoice, jobID: job.id, logEntryID: logEntryID)
        }
    }

    private func speakRemote(segments: [SpeechSegment], voice: String, jobID: UUID, logEntryID: UUID) async {
        dependencies.engineSupervisor.noteRequestStarted(jobID: jobID)
        defer { dependencies.engineSupervisor.noteRequestFinished(jobID: jobID) }

        do {
            guard let firstSegment = segments.first else { return }
            if segments.count > 1 {
                updateJob(jobID, status: .queued, error: nil)
                store.playback.currentSegmentID = firstSegment.id
            }

            let result = try await dependencies.generationService.synthesize(
                text: firstSegment.text,
                voice: voice,
                jobID: jobID
            )
            store.dashboardTelemetry.lastLatencyMs = result.latencyMs
            store.dashboardTelemetry.lastCharCount = result.charCount
            updateJob(jobID, status: .playing, error: nil)
            store.playback.state = .playing
            if segments.count > 1 {
                store.userMessage = "Large text is safely segmented. Playing segment 1 of \(segments.count); remaining segments are preserved for the batching pipeline."
            }
            try dependencies.playbackCoordinator.play(audioData: result.audioData)
        } catch {
            let appError = normalizeGenerationError(error)
            failPlayback(jobID: jobID, logEntryID: logEntryID, error: appError)
        }
    }

    private func speakLocal(text: String, jobID: UUID, logEntryID: UUID) {
        do {
            updateJob(jobID, status: .playing, error: nil)
            store.playback.state = .playing
            try dependencies.localSpeechService.speak(text: text, voiceID: selectedVoice)
        } catch {
            failPlayback(jobID: jobID, logEntryID: logEntryID, error: normalizePlaybackError(error))
        }
    }

    private func bootstrapEngine() async {
        startEngine()
        if await dependencies.generationService.checkHealth() {
            await fetchVoices()
        }
        refreshTelemetry()
    }

    private func fetchVoices() async {
        do {
            let remote = try await dependencies.generationService.fetchVoices()
            if remote.isEmpty {
                store.userMessage = "Voice list empty. Using last voice."
            }
            mergeVoiceOptions(remote: remote)
        } catch {
            record(normalizeEngineError(error))
        }
    }

    private func refreshLocalVoices() {
        dependencies.localSpeechService.refreshVoices()
        mergeVoiceOptions(remote: store.voiceOptions.filter { !$0.isLocal }.map(\.id))
    }

    private func mergeVoiceOptions(remote: [String]) {
        let remoteOptions = remote.map { name in
            VoiceOption(id: name, label: "Kokoro - \(name)", isLocal: false)
        }
        store.voiceOptions = dependencies.localSpeechService.voiceOptions + remoteOptions
        if !store.voiceOptions.contains(where: { $0.id == selectedVoice }) {
            selectedVoice = store.voiceOptions.first?.id ?? AppConfig.defaultVoice
        }
        saveWorkspace()
    }

    private func wireServiceCallbacks() {
        dependencies.engineSupervisor.onHealthChanged = { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                self.store.engineHealth = summary
                self.store.engineStatus = summary.status
                self.refreshTelemetry()
                if summary.status == .idle || summary.status == .running {
                    await self.fetchVoices()
                }
            }
        }

        dependencies.engineSupervisor.onIssue = { [weak self] issue in
            Task { @MainActor in
                guard let self else { return }
                self.store.playback = .idle
                self.store.record(issue)
            }
        }

        if let playback = dependencies.playbackCoordinator as? AVAudioPlaybackCoordinator {
            playback.onFinished = { [weak self] in
                self?.finishPlayback()
            }
        }

        if let localSpeech = dependencies.localSpeechService as? AppleSpeechService {
            localSpeech.onFinished = { [weak self] in
                self?.finishPlayback()
            }
        }
    }

    private func finishPlayback() {
        markActiveJobsCompleted()
        store.playback = .idle
        store.dashboardTelemetry.generatedJobCount += 1
    }

    private func failPlayback(jobID: UUID, logEntryID: UUID, error: AlkiSpeakError) {
        updateJob(jobID, status: .failed, error: error)
        store.playback = PlaybackSnapshot(
            state: .failed,
            activeJobID: jobID,
            activeLogEntryID: logEntryID,
            currentSegmentID: nil,
            elapsedTime: 0,
            duration: nil
        )
        store.dashboardTelemetry.failedJobCount += 1
        record(error)
    }

    private func markActiveJobsCompleted() {
        guard let jobID = store.playback.activeJobID else { return }
        updateJob(jobID, status: .completed, error: nil)
    }

    private func updateJob(_ jobID: UUID, status: SpeechJob.Status, error: AlkiSpeakError?) {
        guard let index = store.speechJobs.firstIndex(where: { $0.id == jobID }) else { return }
        store.speechJobs[index].status = status
        store.speechJobs[index].updatedAt = Date()
        store.speechJobs[index].error = error
    }

    private func record(_ error: AlkiSpeakError) {
        store.record(error)
    }

    private func normalizeEngineError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .engine(
            code: "unknown",
            title: "Engine Error",
            message: error.localizedDescription,
            recoverySuggestion: "Retry the operation or restart the engine.",
            underlyingError: error
        )
    }

    private func normalizeGenerationError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .generation(
            code: "unknown",
            title: "Speech Failed",
            message: "Speak failed: \(error.localizedDescription)",
            recoverySuggestion: "Check the selected voice and try again.",
            underlyingError: error
        )
    }

    private func normalizePlaybackError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .playback(
            code: "unknown",
            title: "Playback Failed",
            message: error.localizedDescription,
            recoverySuggestion: "Try generating the speech again.",
            underlyingError: error
        )
    }

    private func refreshTelemetry() {
        store.dashboardTelemetry.resourceSnapshot = dependencies.telemetryService.capture(
            engineProcessID: dependencies.engineSupervisor.processIdentifier
        )
    }

    private func loadWorkspace() {
        do {
            if let workspace = try dependencies.workspaceStore.loadActiveWorkspace() {
                store.activeWorkspace = workspace
            }
            store.savedLogEntries = try dependencies.logStore.loadLogs(for: store.activeWorkspace.id)
        } catch {
            record(
                AlkiSpeakError(
                    code: "persistence.workspace.load",
                    title: "Workspace Load Failed",
                    message: "The active workspace could not be loaded.",
                    recoverySuggestion: "Continue with the default workspace or restart the app.",
                    underlyingError: error
                )
            )
        }
    }

    private func saveWorkspace() {
        do {
            try dependencies.workspaceStore.saveActiveWorkspace(store.activeWorkspace)
            store.persistence.lastSavedAt = Date()
        } catch {
            let appError = AlkiSpeakError(
                code: "persistence.workspace.save",
                title: "Workspace Save Failed",
                message: "The active workspace could not be saved.",
                recoverySuggestion: "Check local app storage permissions and try again.",
                underlyingError: error
            )
            store.persistence = PersistenceSnapshot(
                state: .failed,
                lastSavedAt: store.persistence.lastSavedAt,
                lastExportURL: store.persistence.lastExportURL,
                error: appError
            )
            record(appError)
        }
    }
}
