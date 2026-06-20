import Combine
import AVFoundation
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let store: AppStore
    private let dependencies: AppDependencies
    private let requestPolicy = EngineRequestPolicy.live
    private let ttsQueue = TTSQueue()
    private var cancellables: Set<AnyCancellable> = []
    private var engineStartTask: Task<Void, Never>?
    private var engineStartGeneration: UInt64 = 0
    private var queryStartedAt: ContinuousClock.Instant?
    private var queryResourceBefore: SystemResourceSnapshot = .empty

    private func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        NSLog("[Woadie][AppModel][\(function):\(line)] \(message)")
    }

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
    var engineStatusLabel: String {
        dependencies.engineSupervisor.engineState.statusText
    }
    var chatItems: [SpeechEntry] { store.speechEntries }
    var playingId: UUID? { store.playback.activeLogEntryID }
    var showPortInUseAlert: Bool {
        get { store.showPortInUseAlert }
        set { store.showPortInUseAlert = newValue }
    }
    var portInUsePids: [Int32] { store.portInUsePids }
    var playback: PlaybackSnapshot { store.playback }
    var appMode: AppMode { store.appMode }
    var logMode: LogMode { store.logMode }
    var appearance: AppAppearance { store.appearance }
    var isProMode: Bool { appMode == .pro }
    var showAddToLog: Bool { isProMode && logMode == .manual }
    var fftMagnitudes: [Float] {
        (dependencies.playbackCoordinator as? AVAudioPlaybackCoordinator)?.fftMagnitudes ?? Array(repeating: 0, count: 128)
    }
    var selectedLogEntry: SpeechEntry? {
        guard let id = store.selectedLogEntryID else { return nil }
        return store.speechEntries.first(where: { $0.id == id })
    }

    var canSpeak: Bool {
        canSpeak(text: inputText)
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

    func cycleVoice(_ offset: Int) {
        let ids = voiceOptions.filter { !$0.isLocal }.map(\.id)
        if let next = VoiceCycler.next(current: selectedVoice, in: ids, offset: offset) {
            selectedVoice = next
            saveWorkspace()
        }
    }

    func seek(to time: TimeInterval) {
        guard dependencies.playbackCoordinator.seek(to: time) else {
            showNotLoaded()
            return
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: max(0, store.playback.elapsedTime + seconds))
    }

    func canSkip(by seconds: TimeInterval) -> Bool {
        let target = max(0, store.playback.elapsedTime + seconds)
        return target <= store.playback.bufferedDuration
    }

    private func showNotLoaded() {
        store.playback.statusMessage = "Not yet loaded"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if store.playback.statusMessage == "Not yet loaded" {
                store.playback.statusMessage = nil
            }
        }
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
        consoleTrace("init isRunningUnitTests=\(AppConfig.isRunningUnitTests) kokoroPath=\(AppConfig.kokoroPath) baseURL=\(AppConfig.serverBaseURL.absoluteString)")

        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        consoleTrace("wiring service callbacks")
        wireServiceCallbacks()
        loadPreferences()
        consoleTrace("loading workspace")
        loadWorkspace()
        loadSpeechEntries()
        consoleTrace("refreshing local voices")
        refreshLocalVoices()
        if !AppConfig.isRunningUnitTests {
            consoleTrace("auto-starting engine from AppModel.init")
            startEngine()
        } else {
            consoleTrace("unit test mode detected; skipping auto-start")
        }
    }

    func startEngine() {
        consoleTrace("startEngine requested currentStatus=\(status.rawValue) supervisorRunning=\(dependencies.engineSupervisor.isRunning) pid=\(dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil")")
        guard !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning else {
            consoleTrace("startEngine ignored because engine is already expected alive or supervisor reports running")
            return
        }
        engineStartTask?.cancel()
        engineStartGeneration &+= 1
        let startGeneration = engineStartGeneration
        store.clearErrorMessage()
        store.engineStatus = .starting
        consoleTrace("engineStatus set to starting")

        let supervisor = dependencies.engineSupervisor
        engineStartTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.engineStartGeneration == startGeneration {
                    self.engineStartTask = nil
                }
            }
            do {
                consoleTrace("detached supervisor.start beginning")
                try await Task.detached(priority: .userInitiated) {
                    try supervisor.start()
                }.value
                guard self.engineStartGeneration == startGeneration, !Task.isCancelled else {
                    consoleTrace("supervisor.start completed after cancellation; ignoring result")
                    return
                }
                consoleTrace("detached supervisor.start completed pid=\(supervisor.processIdentifier.map(String.init) ?? "nil") healthStatus=\(supervisor.healthSummary.status.rawValue)")
                refreshTelemetry()
            } catch {
                guard self.engineStartGeneration == startGeneration else {
                    consoleTrace("supervisor.start error belongs to an old start generation; ignoring error=\(String(describing: error))")
                    return
                }
                if error is CancellationError || Task.isCancelled {
                    consoleTrace("supervisor.start cancelled")
                    if store.engineStatus == .starting || store.engineStatus == .retrying {
                        store.engineStatus = .stopped
                    }
                    return
                }
                consoleTrace("supervisor.start failed error=\(String(describing: error))")
                if let appError = error as? AlkiSpeakError, appError.code == "engine.port-in-use" {
                    let pids = await Task.detached(priority: .userInitiated) {
                        supervisor.findListeningPidsOnEnginePort()
                    }.value
                    consoleTrace("port-in-use surfaced pids=\(pids.map(String.init).joined(separator: ","))")
                    store.portInUsePids = pids
                    store.showPortInUseAlert = true
                    record(appError)
                } else {
                    record(
                        .engine(
                            code: "start-failed",
                            title: "Engine Start Failed",
                            message: "Failed to start the speech engine.",
                            recoverySuggestion: "Verify the Kokoro checkout and virtual environment path, then try again.",
                            underlyingError: error
                        )
                    )
                }
                store.engineStatus = .failed
                consoleTrace("engineStatus set to failed after start error")
                return
            }
            // Poll health at 250 ms — mirrors the original waitForHealth() pattern from
            // 999d859 — so both auto-launch on init AND manual stop→start transitions
            // snap the UI out of "Starting..." as soon as the engine is reachable.
            await waitForEngineReady(startGeneration: startGeneration)
        }
    }

    func stopEngine() {
        consoleTrace("stopEngine requested currentStatus=\(status.rawValue) supervisorRunning=\(dependencies.engineSupervisor.isRunning) pid=\(dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil")")
        engineStartGeneration &+= 1
        engineStartTask?.cancel()
        engineStartTask = nil
        store.clearErrorMessage()
        stopPlayback()
        dependencies.engineSupervisor.stop()
        store.engineStatus = .stopped
        consoleTrace("engineStatus set to stopped")
        refreshTelemetry()
    }

    func restartEngine() {
        consoleTrace("restartEngine requested")
        engineStartGeneration &+= 1
        engineStartTask?.cancel()
        engineStartTask = nil
        stopPlayback()
        store.clearErrorMessage()
        store.engineStatus = .starting
        let restartGeneration = engineStartGeneration

        let supervisor = dependencies.engineSupervisor
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try supervisor.restart()
                }.value
                await waitForEngineReady(startGeneration: restartGeneration)
            } catch {
                store.engineStatus = .failed
                record(normalizeEngineError(error))
            }
        }
    }

    func toggleEngine() {
        consoleTrace("toggleEngine status=\(status.rawValue) processExpectedAlive=\(status.isProcessExpectedAlive) supervisorRunning=\(dependencies.engineSupervisor.isRunning)")
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

    func refreshResourceStats() {
        refreshTelemetry()
    }

    func speak() {
        if appMode == .quick {
            deleteActiveQuickClips()
            stopPlayback()
        }
        speak(text: inputText, addToHistory: isProMode && logMode == .auto, targetLogEntryID: nil)
        if appMode == .quick {
            inputText = ""
        }
    }

    func speakExternalText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appMode == .quick {
            deleteActiveQuickClips()
        }
        stopPlayback()
        inputText = trimmed
        if !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning && !isSelectedVoiceLocal {
            startEngine()
        }
        speak(text: trimmed, addToHistory: false, targetLogEntryID: nil)
    }

    func speakSelectedTextFromMenuBar() {
        guard let selectedText = SelectedTextReader.readFocusedSelection(promptForPermission: true) else {
            store.userMessage = "Select text in another app, or allow AlkiSpeak in Accessibility settings."
            return
        }

        speakExternalText(selectedText)
    }

    func setAppMode(_ mode: AppMode) {
        guard mode != store.appMode else { return }
        store.appMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "AlkiSpeak.appMode")
        if mode == .quick {
            store.logMode = .auto
        }
    }

    func setLogMode(_ mode: LogMode) {
        store.logMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "AlkiSpeak.logMode")
    }

    func setAppearance(_ appearance: AppAppearance) {
        store.appearance = appearance
        appearance.save()
    }

    func selectLogEntry(_ entry: SpeechEntry) {
        store.selectedLogEntryID = entry.id
    }

    func exportSelectedEntry() {
        guard let entry = selectedLogEntry else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Location"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let exportedURL = try dependencies.speechEntryArchiveService.export(entry: entry, to: destination)
            store.userMessage = "Exported \(exportedURL.lastPathComponent)"
        } catch {
            record(AlkiSpeakError(
                code: "archive.export",
                title: "Export Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Choose another destination and try again."
            ))
        }
    }

    func importSpeechEntry() {
        let panel = NSOpenPanel()
        panel.title = "Import Speech Entry"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let entry = try dependencies.speechEntryArchiveService.importEntry(from: source)
            try dependencies.speechEntryStore.insert(entry)
            loadSpeechEntries()
            store.selectedLogEntryID = entry.id
            store.appMode = .pro
            store.userMessage = "Imported \(source.lastPathComponent)"
        } catch {
            record(AlkiSpeakError(
                code: "archive.import",
                title: "Import Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Select a complete AlkiSpeak export folder."
            ))
        }
    }

    func addCurrentToLog() {
        guard showAddToLog,
              let job = store.speechJobs.first,
              job.status != .failed,
              !job.segments.isEmpty,
              job.segments.allSatisfy({ $0.audioURL != nil })
        else { return }
        saveEntry(for: job)
    }

    func open(_ entry: SpeechEntry) {
        stopPlayback()
        inputText = entry.textContent
        selectedVoice = entry.voice
        let urls = entry.segmentRelativePaths.compactMap { try? dependencies.speechEntryStore.absoluteURL(for: $0) }
        let segments = urls.enumerated().map { index, url in
            SpeechSegment(index: index, text: "", status: .ready, audioURL: url)
        }
        let job = SpeechJob(text: entry.textContent, voiceID: entry.voice, segments: segments, status: .completed, logEntryID: entry.id)
        store.speechJobs.insert(job, at: 0)
        dependencies.playbackCoordinator.prepare(characterCounts: Array(repeating: 1, count: urls.count))
        for (index, url) in urls.enumerated() {
            try? dependencies.playbackCoordinator.append(audioURL: url, segmentID: segments[index].id, index: index)
        }
        dependencies.playbackCoordinator.finishEnqueuing()
        store.playback.activeJobID = job.id
        store.playback.activeLogEntryID = entry.id
        store.playback.duration = entry.totalDurationSeconds
        store.playback.bufferedDuration = entry.totalDurationSeconds
    }

    func delete(_ entry: SpeechEntry) {
        do {
            try dependencies.speechEntryStore.delete(entry)
            if store.selectedLogEntryID == entry.id {
                store.selectedLogEntryID = nil
            }
            loadSpeechEntries()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.delete", title: "Delete Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    func togglePlayback() {
        dependencies.playbackCoordinator.togglePlayback()
    }

    func stopPlayback() {
        dependencies.playbackCoordinator.stop()
        dependencies.localSpeechService.stop()
        Task { await ttsQueue.cancel() }
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSpeak(text: trimmed) else { return }
        guard !trimmed.isEmpty else { return }
        store.clearErrorMessage()

        let segments = requestPolicy.segments(for: trimmed)
        if segments.count > 1 {
            store.userMessage = "Large text split into \(segments.count) segments. Sending smaller engine requests to avoid request timeouts."
        }
        let logEntryID: UUID
        let jobID = UUID()

        if addToHistory {
            logEntryID = UUID()
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
        queryStartedAt = ContinuousClock.now
        Task { queryResourceBefore = await SystemResourceMonitor.shared.snapshot() }
        store.playback = PlaybackSnapshot(
            state: .preparing,
            activeJobID: job.id,
            activeLogEntryID: logEntryID,
            currentSegmentID: segments.first?.id,
            elapsedTime: 0,
            duration: TimeInterval(trimmed.count) / 150.0,
            bufferedDuration: 0,
            statusMessage: nil
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
            guard !segments.isEmpty else { return }
            if segments.count > 1 {
                updateJob(jobID, status: .queued, error: nil)
                store.userMessage = "Speaking \(segments.count) segments in order…"
            }

            await ttsQueue.enqueue(segments)
            dependencies.playbackCoordinator.prepare(characterCounts: segments.map { $0.text.count })
            await ttsQueue.process(canGenerate: {
                await SystemResourceMonitor.shared.canProceed()
            }, onWaiting: { waiting in
                await MainActor.run {
                    self.store.playback.statusMessage = waiting ? "Waiting for resources…" : nil
                }
            }) { [generationService = dependencies.generationService, clipStore = dependencies.clipStore, workspaceID = store.activeWorkspace.id] segment in
                let result = try await generationService.synthesize(
                    text: segment.text,
                    voice: voice,
                    jobID: jobID
                )
                let url = try clipStore.writeClip(data: result.audioData, segmentID: segment.id, workspaceID: workspaceID)
                await MainActor.run {
                    self.store.dashboardTelemetry.lastLatencyMs = result.latencyMs
                    self.store.dashboardTelemetry.lastCharCount = result.charCount
                }
                let duration = try? await AVURLAsset(url: url).load(.duration).seconds
                return GeneratedSegment(audioURL: url, durationSeconds: duration)
            } onReady: { [playbackCoordinator = dependencies.playbackCoordinator] segment in
                await MainActor.run {
                    self.store.playback.currentSegmentID = segment.id
                    self.updateJobSegment(jobID, segmentID: segment.id, status: .ready, audioURL: segment.audioURL, error: nil)
                    self.updateSavedLogSegment(logEntryID, segmentID: segment.id, status: .ready, audioURL: segment.audioURL, error: nil)
                    self.updateJob(jobID, status: .playing, error: nil)
                    self.store.playback.state = .playing
                }
                guard let audioURL = segment.audioURL else { return }
                try playbackCoordinator.append(audioURL: audioURL, segmentID: segment.id, index: segment.index)
            }

            let snapshot = await ttsQueue.snapshot()
            if let failed = snapshot.first(where: {
                if case .failed = $0.status { return true }
                return false
            }), case .failed(let error) = failed.status {
                throw error
            }

            dependencies.playbackCoordinator.finishEnqueuing()
            if self.isProMode && self.logMode == .auto, let job = self.store.speechJobs.first(where: { $0.id == jobID }) {
                self.saveEntry(for: job)
            }
        } catch is CancellationError {
            updateJob(jobID, status: .cancelled, error: nil)
            store.playback = .idle
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

    private func waitForEngineReady(startGeneration: UInt64) async {
        let deadline = Date().addingTimeInterval(min(AppConfig.engineStartupTimeoutSeconds, 120))
        var attempt = 0
        consoleTrace("waitForEngineReady started deadline=\(deadline) baseURL=\(AppConfig.serverBaseURL.absoluteString)")
        while Date() < deadline {
            guard engineStartGeneration == startGeneration, !Task.isCancelled else {
                consoleTrace("waitForEngineReady cancelled startGeneration=\(startGeneration)")
                return
            }
            attempt += 1
            if await dependencies.generationService.checkHealth() {
                guard engineStartGeneration == startGeneration, !Task.isCancelled else {
                    consoleTrace("waitForEngineReady health ok after cancellation; ignoring")
                    return
                }
                consoleTrace("waitForEngineReady health ok attempt=\(attempt)")
                // Immediately update status when the engine becomes reachable, matching the
                // original waitForHealth() from 999d859. Without this the UI can sit at
                // "Starting..." for up to 5 s waiting for the supervisor's health-check cycle.
                if store.engineStatus == .starting || store.engineStatus == .retrying {
                    store.engineStatus = .running
                    consoleTrace("engineStatus set to running after health ok")
                }
                await fetchVoices()
                refreshTelemetry()
                return
            }
            consoleTrace("waitForEngineReady health not ready attempt=\(attempt) status=\(store.engineStatus.rawValue)")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refreshTelemetry()
        consoleTrace("waitForEngineReady deadline reached attempts=\(attempt)")
        guard engineStartGeneration == startGeneration, !Task.isCancelled else {
            consoleTrace("waitForEngineReady deadline reached after cancellation; ignoring")
            return
        }
        if !(await dependencies.generationService.checkHealth()) {
            store.userMessage =
                "Could not reach the Kokoro engine at \(AppConfig.serverBaseURL.absoluteString). "
                + "Verify \(AppConfig.kokoroPath) contains kokoro_server.py and .venv/bin/python3. "
                + "Expected command: python -m uvicorn kokoro_server:app --host 127.0.0.1 --port \(AppConfig.enginePort) --timeout-keep-alive 120 --timeout-graceful-shutdown 30 --log-level warning --log-config kokoro-log-config.json"
            consoleTrace("waitForEngineReady final health failed; userMessage updated")
        }
    }

    private func fetchVoices() async {
        do {
            consoleTrace("fetchVoices starting")
            let remote = try await dependencies.generationService.fetchVoices()
            consoleTrace("fetchVoices succeeded count=\(remote.count) voices=\(remote.joined(separator: ","))")
            if remote.isEmpty {
                store.userMessage = "Voice list empty. Using last voice."
            }
            mergeVoiceOptions(remote: remote)
        } catch {
            consoleTrace("fetchVoices failed error=\(String(describing: error))")
            record(normalizeEngineError(error))
        }
    }

    private func refreshLocalVoices() {
        consoleTrace("refreshLocalVoices starting")
        dependencies.localSpeechService.refreshVoices()
        consoleTrace("refreshLocalVoices localCount=\(dependencies.localSpeechService.voiceOptions.count)")
        mergeVoiceOptions(remote: store.voiceOptions.filter { !$0.isLocal }.map(\.id))
    }

    private func mergeVoiceOptions(remote: [String]) {
        // On cold start, `refreshLocalVoices()` runs before /voices returns, so `remote` is
        // often empty. Without preserving the workspace Kokoro id here, `selectedVoice`
        // (e.g. af_heart) is not in the Apple-only list and gets replaced by the first
        // Apple voice — remote synthesis then never runs until the user re-picks Kokoro.
        var remoteIDs = remote
        if !isSelectedVoiceLocal, !selectedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !remoteIDs.contains(selectedVoice)
        {
            remoteIDs.append(selectedVoice)
        }
        let remoteOptions = remoteIDs.map { name in
            VoiceOption(id: name, label: "Kokoro - \(name)", isLocal: false)
        }
        store.voiceOptions = dependencies.localSpeechService.voiceOptions + remoteOptions
        if isSelectedVoiceLocal, let remoteDefault = remoteOptions.first(where: { $0.id == AppConfig.defaultVoice }) ?? remoteOptions.first {
            selectedVoice = remoteDefault.id
        }
        if !store.voiceOptions.contains(where: { $0.id == selectedVoice }) {
            selectedVoice = store.voiceOptions.first?.id ?? AppConfig.defaultVoice
        }
        saveWorkspace()
    }

    private func wireServiceCallbacks() {
        dependencies.engineSupervisor.onHealthChanged = { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                self.consoleTrace("onHealthChanged status=\(summary.status.rawValue) pid=\(summary.pid.map(String.init) ?? "nil") retry=\(summary.retryCount) failures=\(summary.consecutiveHealthFailures) latestIssue=\(summary.latestIssue?.code ?? "nil")")
                guard self.shouldApplyEngineHealth(summary) else {
                    self.consoleTrace("ignored stale engine health status=\(summary.status.rawValue) currentStatus=\(self.store.engineStatus.rawValue)")
                    return
                }
                self.store.engineHealth = summary
                self.store.engineStatus = summary.status
                self.refreshTelemetry()
                if summary.status == .idle || summary.status == .running {
                    if self.store.lastError?.code.hasPrefix("engine.") == true {
                        self.store.clearErrorMessage()
                    }
                    await self.fetchVoices()
                }
            }
        }

        dependencies.engineSupervisor.onIssue = { [weak self] issue in
            Task { @MainActor in
                guard let self else { return }
                self.consoleTrace("onIssue code=\(issue.code) title=\(issue.title) rawError=\(issue.rawError ?? "nil") context=\(issue.context)")
                self.store.playback = .idle
                self.store.record(issue)
            }
        }

        dependencies.playbackCoordinator.onFinished = { [weak self] in self?.finishPlayback() }
        dependencies.playbackCoordinator.onSnapshotChanged = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.store.playback.state = snapshot.state
                self.store.playback.currentSegmentID = snapshot.currentSegmentID
                self.store.playback.elapsedTime = snapshot.elapsedTime
                self.store.playback.bufferedDuration = snapshot.bufferedDuration
                self.store.playback.duration = snapshot.totalDuration
                self.objectWillChange.send()
            }
        }

        if let localSpeech = dependencies.localSpeechService as? AppleSpeechService {
            localSpeech.onFinished = { [weak self] in
                self?.finishPlayback()
            }
        }
    }

    private func shouldApplyEngineHealth(_ summary: EngineHealthSummary) -> Bool {
        switch summary.status {
        case .starting, .retrying:
            return store.engineStatus != .stopped || engineStartTask != nil
        case .stopped:
            return !(engineStartTask != nil && (store.engineStatus == .starting || store.engineStatus == .retrying))
        case .running, .idle, .busy, .degraded, .timedOut, .stalled, .failed:
            return true
        }
    }

    private func finishPlayback() {
        markActiveJobsCompleted()
        store.playback.state = .stopped
        store.playback.elapsedTime = 0
        store.playback.currentSegmentID = nil
        store.dashboardTelemetry.generatedJobCount += 1
        if appMode == .quick {
            deleteActiveQuickClips()
        }
    }

    private func failPlayback(jobID: UUID, logEntryID: UUID, error: AlkiSpeakError) {
        updateJob(jobID, status: .failed, error: error)
        store.playback = PlaybackSnapshot(
            state: .failed,
            activeJobID: jobID,
            activeLogEntryID: logEntryID,
            currentSegmentID: nil,
            elapsedTime: 0,
            duration: nil,
            bufferedDuration: 0,
            statusMessage: nil
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

    private func updateJobSegment(_ jobID: UUID, segmentID: UUID, status: SpeechSegment.Status, audioURL: URL?, error: AlkiSpeakError?) {
        guard let jobIndex = store.speechJobs.firstIndex(where: { $0.id == jobID }),
              let segmentIndex = store.speechJobs[jobIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        store.speechJobs[jobIndex].segments[segmentIndex].status = status
        store.speechJobs[jobIndex].segments[segmentIndex].audioURL = audioURL
        store.speechJobs[jobIndex].segments[segmentIndex].error = error
        store.speechJobs[jobIndex].updatedAt = Date()
    }

    private func updateSavedLogSegment(_ logEntryID: UUID, segmentID: UUID, status: SpeechSegment.Status, audioURL: URL?, error: AlkiSpeakError?) {
        guard let entryIndex = store.savedLogEntries.firstIndex(where: { $0.id == logEntryID }),
              let segmentIndex = store.savedLogEntries[entryIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        store.savedLogEntries[entryIndex].segments[segmentIndex].status = status
        store.savedLogEntries[entryIndex].segments[segmentIndex].audioURL = audioURL
        store.savedLogEntries[entryIndex].segments[segmentIndex].error = error
        try? dependencies.logStore.replaceLogs(store.savedLogEntries, workspaceID: store.activeWorkspace.id)
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

    private func loadPreferences() {
        store.appearance = AppAppearance.load()
        if let raw = UserDefaults.standard.string(forKey: "AlkiSpeak.appMode"), let mode = AppMode(rawValue: raw) {
            store.appMode = mode
        }
        if let raw = UserDefaults.standard.string(forKey: "AlkiSpeak.logMode"), let mode = LogMode(rawValue: raw) {
            store.logMode = mode
        }
    }

    private func loadSpeechEntries() {
        do {
            _ = try dependencies.speechEntryStore.migrateLegacyHistoryIfNeeded()
            store.speechEntries = try dependencies.speechEntryStore.fetchAll()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.load", title: "Log Load Failed", message: error.localizedDescription, recoverySuggestion: "The legacy data was preserved. Restart and try again."))
        }
    }

    private func saveEntry(for job: SpeechJob) {
        guard !store.speechEntries.contains(where: { $0.id == job.logEntryID }) else { return }
        let urls = job.segments.compactMap(\.audioURL)
        let paths = urls.compactMap { try? dependencies.speechEntryStore.relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        let elapsed = queryStartedAt.map { $0.duration(to: ContinuousClock.now) } ?? .zero
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let fileSize = urls.reduce(Int64(0)) {
            $0 + Int64((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        Task {
            let after = await SystemResourceMonitor.shared.snapshot()
            let durations = await audioDurations(urls)
            let entry = SpeechEntry(
                id: job.logEntryID ?? UUID(),
                textContent: job.text,
                voice: job.voiceID,
                segmentRelativePaths: paths,
                segmentDurations: durations,
                totalDurationSeconds: durations.reduce(0, +),
                stats: QueryStats(
                    tokenCount: max(1, job.text.count / 4),
                    generationTimeSeconds: abs(seconds),
                    fileSizeBytes: fileSize,
                    characterCount: job.text.count,
                    segmentCount: job.segments.count,
                    resourceBefore: queryResourceBefore,
                    resourceAfter: after
                ),
                appMode: .pro
            )
            do {
                try dependencies.speechEntryStore.insert(entry)
                loadSpeechEntries()
            } catch {
                record(AlkiSpeakError(code: "persistence.log.save", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try Add to Log again."))
            }
        }
    }

    private func audioDurations(_ urls: [URL]) async -> [Double] {
        var values: [Double] = []
        for url in urls {
            values.append((try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0)
        }
        return values
    }

    private func deleteActiveQuickClips() {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return }
        for segment in job.segments {
            if let url = segment.audioURL { try? FileManager.default.removeItem(at: url) }
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

    private func canSpeak(text: String) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText
            && !store.playback.state.blocksNewSpeech
            && (status.isAvailableForRemoteSpeech || isSelectedVoiceLocal)
    }
}
