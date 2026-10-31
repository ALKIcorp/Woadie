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
    private let favoritesStore = VoiceFavoritesStore()
    private var cancellables: Set<AnyCancellable> = []
    private var engineStartTask: Task<Void, Never>?
    /// The task running the current generation/playback request. Cancelled by
    /// `interruptForOverride()` so a superseding request actually tears down the
    /// in-flight network call (cooperative cancellation propagates through
    /// `URLSession.data(for:)`) instead of letting it finish uselessly in the
    /// background while only its result gets discarded.
    private var activeSpeechTask: Task<Void, Never>?
    private var engineStartGeneration: UInt64 = 0
    private var queryStartedAt: ContinuousClock.Instant?
    private var queryResourceBefore: SystemResourceSnapshot = .empty
    private var resourceUsageAccumulator = QueryResourceUsageAccumulator()
    private var resourceSamplingGeneration: UInt64 = 0
    private var resourceSamplingTask: Task<Void, Never>?
    // The transport snapshot republishes the whole observable store, which
    // re-renders the entire view tree (glass surfaces, waveform, voice picker).
    // 30 Hz keeps the scrubber/timecode smooth while leaving the main thread
    // free enough that taps on controls and the voice picker stay responsive
    // during playback. The waveform interpolates per display frame on its own
    // `TimelineView`, so it stays fluid regardless of this rate.
    private let playbackSnapshotMinimumInterval: TimeInterval = 1.0 / 30.0
    private var lastPlaybackSnapshotAppliedAt: TimeInterval = 0
    private var performanceDiagnosticsTask: Task<Void, Never>?
    private var performanceDiagnosticPhase: PerformanceDiagnosticPhase = .idle
    private var activePerformanceDiagnosticJobID: UUID?
    private var hasRequestedAccessibilityPrompt = false

    private func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        guard AppConfig.isVerboseConsoleTracingEnabled else { return }
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
        set {
            store.selectedVoiceID = newValue
            saveWorkspace()
        }
    }
    var message: String { store.userMessage }
    var selectedTextPermissionRequired: Bool { store.selectedTextPermissionRequired }
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
        status.isAvailableForRemoteSpeech || isSelectedVoiceLocal || isSelectedVoiceEngineIndependent
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

    /// Grouped voices for the dropdown: Favorites first, then per-source sections.
    var voiceSections: [VoiceGrouping.Section] {
        VoiceGrouping.sections(voices: voiceOptions, favorites: store.voiceFavorites)
    }

    var voiceFavorites: Set<String> { store.voiceFavorites }

    func isFavorite(_ voiceID: String) -> Bool {
        store.voiceFavorites.contains(voiceID)
    }

    func toggleFavorite(_ voiceID: String) {
        if store.voiceFavorites.contains(voiceID) {
            store.voiceFavorites.remove(voiceID)
        } else {
            store.voiceFavorites.insert(voiceID)
        }
        favoritesStore.save(store.voiceFavorites)
    }

    // MARK: Listen-only playback tuning

    var playbackTuning: PlaybackTuning { store.playbackTuning }

    func setPlaybackSpeed(_ speed: Double) {
        applyTuning(store.playbackTuning.withSpeed(speed))
    }

    func setPlaybackPitch(_ pitch: Double) {
        applyTuning(store.playbackTuning.withPitch(pitch))
    }

    func resetPlaybackTuning() {
        applyTuning(.default)
    }

    private func applyTuning(_ tuning: PlaybackTuning) {
        store.playbackTuning = tuning
        tuning.save()
        dependencies.playbackCoordinator.applyTuning(tuning)
    }

    // MARK: Cloud voices

    var cloudSettings: CloudSpeechSettings { store.cloudSettings }

    func hasCloudAPIKey(for provider: CloudProvider) -> Bool {
        !(dependencies.secretStore.secret(for: provider.id) ?? "").isEmpty
    }

    /// Saves (or, with an empty string, removes) a provider's key in the Keychain.
    func setCloudAPIKey(_ key: String, for provider: CloudProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try dependencies.secretStore.setSecret(trimmed.isEmpty ? nil : trimmed, for: provider.id)
            store.userMessage = trimmed.isEmpty ? "\(provider.name) key removed." : "\(provider.name) key saved to Keychain."
            objectWillChange.send()
        } catch let error as AlkiSpeakError {
            record(error)
        } catch {
            store.userMessage = error.localizedDescription
        }
    }

    func setCloudCustomBaseURL(_ url: String) {
        store.cloudSettings.customBaseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
    }

    func addCloudVoice(provider: CloudProvider, model: String, voice: String, label: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !voice.isEmpty else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudVoice = CloudVoice(
            providerID: provider.id,
            model: model,
            voice: voice,
            label: trimmedLabel.isEmpty ? "\(provider.name) · \(voice)" : trimmedLabel
        )
        store.cloudSettings.voices.append(cloudVoice)
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
        refreshCloudVoices()
        selectedVoice = cloudVoice.voiceID
        if provider == .localMLX {
            warmUpLocalVoiceServer()
        }
    }

    /// Starts the local mlx-audio server in the background so the first local
    /// voice request doesn't pay its boot time. Speaking a local voice also
    /// ensures the server, so a failure here is only logged.
    func warmUpLocalVoiceServer() {
        Task { [localVoiceServer = dependencies.localVoiceServer] in
            do {
                try await localVoiceServer.ensureRunning()
            } catch {
                self.consoleTrace("local voice server warm-up failed error=\(String(describing: error))")
            }
        }
    }

    func hasCloudVoice(provider: CloudProvider, model: String, voice: String) -> Bool {
        store.cloudSettings.voices.contains { $0.providerID == provider.id && $0.model == model && $0.voice == voice }
    }

    /// One-click add for a verified local preset; a no-op if it's already added.
    func addLocalPreset(model: LocalVoiceCatalog.Model, voice: LocalVoiceCatalog.Voice) {
        guard !hasCloudVoice(provider: .localMLX, model: model.id, voice: voice.name) else { return }
        addCloudVoice(provider: .localMLX, model: model.id, voice: voice.name, label: voice.label)
    }

    /// The account's ElevenLabs voices and TTS models, for the Settings pickers.
    func loadElevenLabsCatalog() async throws -> ElevenLabsCatalog {
        try await dependencies.elevenLabsCatalog.fetchCatalog()
    }

    /// Called on app quit. Leaves alone a server the app adopted rather than launched.
    func shutDownLocalVoiceServer() {
        dependencies.localVoiceServer.stopOwnedServer()
    }

    func removeCloudVoice(_ cloudVoice: CloudVoice) {
        store.cloudSettings.voices.removeAll { $0.id == cloudVoice.id }
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
        if selectedVoice == cloudVoice.voiceID {
            // `mergeVoiceOptions` keeps the selected ID alive on purpose, so
            // move off the deleted voice before it re-adds it as a ghost.
            selectedVoice = AppConfig.defaultVoice
        }
        if store.voiceFavorites.remove(cloudVoice.voiceID) != nil {
            favoritesStore.save(store.voiceFavorites)
        }
        refreshCloudVoices()
    }

    /// Rebuilds the catalog's cloud entries from settings without re-fetching
    /// the Kokoro and Edge lists over the network.
    private func refreshCloudVoices() {
        let others = store.voiceOptions
            .filter { !$0.isLocal && !CloudSpeechGenerationService.isCloudVoice($0.id) }
            .map(\.id)
        mergeVoiceOptions(remote: others + store.cloudSettings.voices.map(\.voiceID))
    }

    var lastQueryResourceUsage: QueryResourceUsage? { store.lastQueryResourceUsage }

    var isResourceSamplingActiveForTesting: Bool { resourceSamplingTask != nil }

    private var isSelectedVoiceLocal: Bool {
        selectedVoice.hasPrefix("apple:")
    }

    /// Edge and cloud voices are reached over the network like Kokoro, but
    /// don't depend on the local Kokoro engine being up — they should remain
    /// speakable even while the engine is starting, stopped, or failed.
    private var isSelectedVoiceEngineIndependent: Bool {
        selectedVoice.hasPrefix(EdgeSpeechGenerationService.idPrefix)
            || CloudSpeechGenerationService.isCloudVoice(selectedVoice)
    }

    private func remoteService(for voice: String) -> SpeechGenerating {
        if voice.hasPrefix(EdgeSpeechGenerationService.idPrefix) { return dependencies.edgeSpeechService }
        if CloudSpeechGenerationService.isCloudVoice(voice) { return dependencies.cloudSpeechService }
        return dependencies.generationService
    }

    init(store: AppStore, dependencies: AppDependencies) {
        self.store = store
        self.dependencies = dependencies
        consoleTrace("init isRunningUnitTests=\(AppConfig.isRunningUnitTests) kokoroPath=\(AppConfig.kokoroPath) baseURL=\(AppConfig.serverBaseURL.absoluteString)")
        if !AppConfig.isRunningUnitTests {
            startPerformanceDiagnosticSession()
        }

        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.consoleTrace("availableVoicesDidChangeNotification received")
                self?.refreshLocalVoices()
            }
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
            startPerformanceDiagnosticSampling()
            consoleTrace("auto-starting engine from AppModel.init")
            startEngine()
            // Edge voices don't depend on the Kokoro engine, so fetch them right
            // away instead of waiting on waitForEngineReady().
            Task { await fetchVoices() }
            if store.cloudSettings.voices.contains(where: { $0.providerID == CloudProvider.localMLX.id }) {
                warmUpLocalVoiceServer()
            }
        } else {
            consoleTrace("unit test mode detected; skipping auto-start")
        }
    }

    deinit {
        performanceDiagnosticsTask?.cancel()
    }

    func startEngine() {
        consoleTrace("startEngine requested currentStatus=\(status.rawValue) supervisorRunning=\(dependencies.engineSupervisor.isRunning) pid=\(dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil")")
        guard !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning else {
            consoleTrace("startEngine ignored because engine is already expected alive or supervisor reports running")
            return
        }
        dependencies.performanceDiagnostics.recordMarker(
            phase: .engineStart,
            message: "Engine start requested.",
            jobID: nil,
            context: performanceDiagnosticContext()
        )
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
        dependencies.performanceDiagnostics.recordMarker(
            phase: .engineStop,
            message: "Engine stop requested.",
            jobID: activePerformanceDiagnosticJobID,
            context: performanceDiagnosticContext()
        )
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
        }
        // A new request always takes over: stop whatever is playing or generating
        // so the user never has to pause/stop first. The in-flight job (if any) is
        // superseded by this job's `activeJobID`, and the TTS queue is reset
        // atomically at the start of the new request.
        interruptForOverride()
        speak(text: inputText, addToHistory: isProMode && logMode == .auto, targetLogEntryID: nil)
        if appMode == .quick {
            inputText = ""
        }
    }

    /// Stops the current utterance so a freshly requested one can take over
    /// immediately. Safe to call when nothing is active. Unlike `stopPlayback()`
    /// this does not push the transport to `.idle` (the new request overwrites it
    /// a moment later, so we avoid a visible flash) and it does not fire a
    /// detached queue cancel — the new request cancels and re-seeds the queue in
    /// the same task, which keeps the override race-free.
    private func interruptForOverride() {
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        finishResourceSampling()
        finishPerformanceDiagnosticJob(message: "Superseded by a new request.")
        dependencies.playbackCoordinator.stop()
        dependencies.localSpeechService.stop()
        markActiveJobsCompleted()
    }

    func speakExternalText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appMode == .quick {
            deleteActiveQuickClips()
        }
        interruptForOverride()
        inputText = trimmed
        if !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning && !isSelectedVoiceLocal && !isSelectedVoiceEngineIndependent {
            startEngine()
        }
        speak(text: trimmed, addToHistory: false, targetLogEntryID: nil)
    }

    func speakSelectedTextFromMenuBar() {
        Task {
            switch await dependencies.selectedTextReader.readFocusedSelection() {
            case .selected(let selectedText):
                store.selectedTextPermissionRequired = false
                store.userMessage = ""
                speakExternalText(selectedText)
            case .permissionRequired:
                store.selectedTextPermissionRequired = true
                store.userMessage = "Accessibility access is required to read selected text."
                requestAccessibilityAccessOnce()
            case .noSelection:
                store.selectedTextPermissionRequired = false
                store.userMessage = "No text is selected in another app. Select text and try again."
            }
        }
    }

    /// Fires the asynchronous macOS Accessibility prompt at most once per app
    /// launch. Opening System Settings remains an explicit, repeatable user action.
    private func requestAccessibilityAccessOnce() {
        guard !hasRequestedAccessibilityPrompt else { return }
        hasRequestedAccessibilityPrompt = true
        dependencies.selectedTextReader.requestAccessibilityPrompt()
    }

    func openAccessibilitySettings() {
        dependencies.selectedTextReader.openAccessibilitySettings()
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

    func reinsert(_ entry: SpeechEntry) {
        stopPlayback()
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

    func savePlaybackToDefaultFolder() {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID }),
              job.status != .failed,
              !job.segments.isEmpty,
              job.segments.allSatisfy({ $0.audioURL != nil })
        else { return }

        let urls = job.segments.compactMap(\.audioURL)
        guard !urls.isEmpty else { return }

        guard let downloads = try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        let destination = downloads.appendingPathComponent(defaultClipFilename())

        Task {
            do {
                let savedURL = try await exportPlaybackAudio(urls: urls, to: destination)
                saveEntry(for: job)
                store.userMessage = "Saved \(savedURL.lastPathComponent) to Downloads."
            } catch {
                record(AlkiSpeakError(code: "playback.savedefault", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try Save As instead."))
            }
        }
    }

    func savePlaybackAs() {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return }

        let urls = job.segments.compactMap(\.audioURL)
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.title = "Save Audio As..."
            panel.prompt = "Save"
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = self.defaultClipFilename()

            guard panel.runModal() == .OK, let destination = panel.url else { return }

            Task {
                do {
                    let savedURL = try await self.exportPlaybackAudio(urls: urls, to: destination)
                    self.store.userMessage = "Saved \(savedURL.lastPathComponent)"
                } catch {
                    self.record(AlkiSpeakError(code: "playback.saveas", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try a different location."))
                }
            }
        }
    }

    func sharePlaybackAudio(from anchorRect: CGRect = .zero) {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return }

        let urls = job.segments.compactMap { $0.audioURL }
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            guard let mainWindow = NSApp.windows.first(where: { $0.isKeyWindow }),
                  let contentView = mainWindow.contentView
            else { return }
            let picker = NSSharingServicePicker(items: urls)
            let rect: NSRect = anchorRect == .zero
                ? contentView.bounds
                : NSRect(
                    x: anchorRect.minX,
                    y: contentView.bounds.height - anchorRect.maxY,
                    width: anchorRect.width,
                    height: anchorRect.height
                )
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    private func defaultClipFilename() -> String {
        "AlkiSpeak_Clip_\(Int(Date().timeIntervalSince1970)).wav"
    }

    private func exportPlaybackAudio(urls: [URL], to destination: URL) async throws -> URL {
        if urls.count == 1 {
            try FileManager.default.copyItem(at: urls[0], to: destination)
            return destination
        }

        let composition = AVMutableComposition()
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
                try compositionAudioTrack?.insertTimeRange(timeRange, of: track, at: insertTime)
                insertTime = CMTimeAdd(insertTime, timeRange.duration)
            }
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            try FileManager.default.copyItem(at: urls[0], to: destination)
            return destination
        }
        let outputURL = destination.deletingPathExtension().appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        await exportSession.export()
        if let error = exportSession.error {
            throw error
        }
        return outputURL
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
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        finishResourceSampling()
        finishPerformanceDiagnosticJob(message: "Playback stopped.")
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
        setPerformanceDiagnosticPhase(
            isSelectedVoiceLocal ? .localSpeech : .remoteGeneration,
            jobID: jobID,
            message: "Speech job started.",
            context: [
                "characterCount": "\(trimmed.count)",
                "segmentCount": "\(segments.count)",
                "voiceSource": diagnosticVoiceSource(for: selectedVoice)
            ]
        )
        Task { queryResourceBefore = await SystemResourceMonitor.shared.snapshot() }
        startResourceSampling()
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

        activeSpeechTask = Task {
            // Supersede any older in-flight generation before this request does
            // anything. Done here (in the same task, before branching) so it
            // covers both the remote queue and a remote→local switch, with
            // deterministic ordering relative to this request's own enqueue.
            await ttsQueue.cancel()
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
                    if waiting {
                        self.setPerformanceDiagnosticPhase(
                            .resourceWait,
                            jobID: jobID,
                            message: "Generation paused while waiting for system resources.",
                            context: ["segmentCount": "\(segments.count)"]
                        )
                    }
                }
            }) { [generationService = remoteService(for: voice), clipStore = dependencies.clipStore, workspaceID = store.activeWorkspace.id] segment in
                await MainActor.run {
                    self.setPerformanceDiagnosticPhase(
                        .remoteGeneration,
                        jobID: jobID,
                        message: "Generating segment.",
                        context: [
                            "segmentIndex": "\(segment.index)",
                            "segmentCharacterCount": "\(segment.text.count)"
                        ]
                    )
                }
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
                    self.setPerformanceDiagnosticPhase(
                        .playback,
                        jobID: jobID,
                        message: "Segment ready for playback.",
                        context: ["segmentIndex": "\(segment.index)"]
                    )
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

            // If a newer request superseded this job while we were generating,
            // do not finalize the transport or persist — the new job now owns
            // playback and finishing here would prematurely cut it off.
            guard store.playback.activeJobID == jobID else {
                finishResourceSampling()
                return
            }

            dependencies.playbackCoordinator.finishEnqueuing()
            finishResourceSampling()
            if self.isProMode && self.logMode == .auto, let job = self.store.speechJobs.first(where: { $0.id == jobID }) {
                self.saveEntry(for: job)
            }
        } catch is CancellationError {
            finishResourceSampling()
            finishPerformanceDiagnosticJob(message: "Speech request cancelled.")
            updateJob(jobID, status: .cancelled, error: nil)
            store.playback = .idle
        } catch {
            let appError = normalizeGenerationError(error)
            failPlayback(jobID: jobID, logEntryID: logEntryID, error: appError)
        }
    }

    private func speakLocal(text: String, jobID: UUID, logEntryID: UUID) {
        do {
            setPerformanceDiagnosticPhase(
                .localSpeech,
                jobID: jobID,
                message: "Local speech playback started.",
                context: ["characterCount": "\(text.count)"]
            )
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

    /// Fetches the Kokoro, Edge and cloud voice lists independently — each is
    /// a different dependency (local engine, Microsoft's service, user config),
    /// so one being unreachable should not blank out the others' voices.
    private func fetchVoices() async {
        consoleTrace("fetchVoices starting")
        async let kokoroResult = fetchVoicesResult(from: dependencies.generationService, label: "kokoro")
        async let edgeResult = fetchVoicesResult(from: dependencies.edgeSpeechService, label: "edge")
        async let cloudResult = fetchVoicesResult(from: dependencies.cloudSpeechService, label: "cloud")
        let (kokoro, edge, cloud) = await (kokoroResult, edgeResult, cloudResult)

        var combined: [String] = []
        if let kokoro { combined += kokoro }
        if let edge { combined += edge }
        if let cloud { combined += cloud }

        consoleTrace("fetchVoices completed count=\(combined.count) voices=\(combined.joined(separator: ","))")
        if combined.isEmpty {
            store.userMessage = "Voice list empty. Using last voice."
        }
        mergeVoiceOptions(remote: combined)
    }

    private func fetchVoicesResult(from service: SpeechGenerating, label: String) async -> [String]? {
        do {
            return try await service.fetchVoices()
        } catch {
            consoleTrace("fetchVoices(\(label)) failed error=\(String(describing: error))")
            return nil
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
        let remoteOptions = remoteIDs.map { id -> VoiceOption in
            if id.hasPrefix(EdgeSpeechGenerationService.idPrefix) {
                let name = EdgeSpeechGenerationService.stripPrefix(id)
                return VoiceOption(id: id, label: "Edge - \(name)", source: .edge)
            }
            if CloudSpeechGenerationService.isCloudVoice(id) {
                let label = store.cloudSettings.voice(withID: id)?.label ?? "Removed voice"
                return VoiceOption(id: id, label: "Cloud - \(label)", source: .api)
            }
            return VoiceOption(id: id, label: "Kokoro - \(id)", source: .kokoro)
        }
        store.voiceOptions = dependencies.localSpeechService.voiceOptions + remoteOptions
        selectedVoice = VoiceSelection.resolved(
            current: selectedVoice,
            in: store.voiceOptions,
            fallback: AppConfig.defaultVoice
        )
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
                guard self.shouldApplyPlaybackSnapshot(snapshot) else { return }
                var playback = self.store.playback
                playback.state = snapshot.state
                playback.currentSegmentID = snapshot.currentSegmentID
                playback.elapsedTime = snapshot.elapsedTime
                playback.bufferedDuration = snapshot.bufferedDuration
                playback.duration = snapshot.totalDuration
                self.store.playback = playback
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

    private func shouldApplyPlaybackSnapshot(_ snapshot: PlaybackTransportSnapshot) -> Bool {
        let playback = store.playback
        let now = Date.timeIntervalSinceReferenceDate
        let shouldApplyImmediately =
            snapshot.state != playback.state ||
            snapshot.state != .playing ||
            snapshot.currentSegmentID != playback.currentSegmentID ||
            abs(snapshot.bufferedDuration - playback.bufferedDuration) > 0.001 ||
            abs(snapshot.totalDuration - (playback.duration ?? 0)) > 0.001

        guard shouldApplyImmediately || now - lastPlaybackSnapshotAppliedAt >= playbackSnapshotMinimumInterval else {
            return false
        }
        lastPlaybackSnapshotAppliedAt = now
        return true
    }

    private func finishPlayback() {
        finishResourceSampling()
        finishPerformanceDiagnosticJob(message: "Playback finished.")
        markActiveJobsCompleted()
        store.playback.state = .stopped
        store.playback.elapsedTime = 0
        store.playback.currentSegmentID = nil
        store.dashboardTelemetry.generatedJobCount += 1
    }

    private func failPlayback(jobID: UUID, logEntryID: UUID, error: AlkiSpeakError) {
        finishResourceSampling()
        dependencies.performanceDiagnostics.recordMarker(
            phase: .failure,
            message: "Playback failed.",
            jobID: jobID,
            context: performanceDiagnosticContext([
                "errorCode": error.code,
                "errorTitle": error.title
            ])
        )
        finishPerformanceDiagnosticJob(message: "Playback failed.")
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

    // MARK: Performance diagnostics

    private func startPerformanceDiagnosticSession() {
        dependencies.performanceDiagnostics.startSession(
            context: [
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                "diagnosticLog": dependencies.performanceDiagnostics.logURL.path,
                "diagnosticSummary": dependencies.performanceDiagnostics.summaryURL.path
            ]
        )
        dependencies.performanceDiagnostics.recordMarker(
            phase: .idle,
            message: "AppModel initialized.",
            jobID: nil,
            context: performanceDiagnosticContext()
        )
    }

    private func startPerformanceDiagnosticSampling() {
        performanceDiagnosticsTask?.cancel()
        let interval = UInt64(AppConfig.performanceDiagnosticIdleSampleIntervalSeconds * 1_000_000_000)
        performanceDiagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                let system = await SystemResourceMonitor.shared.snapshot()
                await MainActor.run {
                    self?.recordPerformanceDiagnosticSample(
                        system: system,
                        context: ["source": "app-sampler"]
                    )
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func setPerformanceDiagnosticPhase(
        _ phase: PerformanceDiagnosticPhase,
        jobID: UUID?,
        message: String,
        context: [String: String] = [:]
    ) {
        performanceDiagnosticPhase = phase
        activePerformanceDiagnosticJobID = jobID
        dependencies.performanceDiagnostics.recordMarker(
            phase: phase,
            message: message,
            jobID: jobID,
            context: performanceDiagnosticContext(context)
        )
    }

    private func finishPerformanceDiagnosticJob(message: String) {
        guard activePerformanceDiagnosticJobID != nil || performanceDiagnosticPhase != .idle else { return }
        dependencies.performanceDiagnostics.recordMarker(
            phase: .idle,
            message: message,
            jobID: activePerformanceDiagnosticJobID,
            context: performanceDiagnosticContext()
        )
        performanceDiagnosticPhase = .idle
        activePerformanceDiagnosticJobID = nil
    }

    private func recordPerformanceDiagnosticSample(system: SystemResourceSnapshot, context: [String: String]) {
        let process = dependencies.telemetryService.capture(
            engineProcessID: dependencies.engineSupervisor.processIdentifier
        )
        dependencies.performanceDiagnostics.recordSample(
            phase: performanceDiagnosticPhase,
            jobID: activePerformanceDiagnosticJobID,
            system: system,
            process: process,
            context: performanceDiagnosticContext(context)
        )
    }

    private func performanceDiagnosticContext(_ extra: [String: String] = [:]) -> [String: String] {
        var context = [
            "engineStatus": status.rawValue,
            "enginePID": dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil",
            "playbackState": store.playback.state.rawValue,
            "appMode": appMode.rawValue,
            "voiceSource": diagnosticVoiceSource(for: selectedVoice)
        ]
        extra.forEach { context[$0.key] = $0.value }
        return context
    }

    private func diagnosticVoiceSource(for voiceID: String) -> String {
        if voiceID.hasPrefix("apple:") { return "apple" }
        if voiceID.hasPrefix(EdgeSpeechGenerationService.idPrefix) { return "edge" }
        if CloudSpeechGenerationService.isCloudVoice(voiceID) { return "cloud" }
        return "kokoro"
    }

    // MARK: Query resource sampling

    private func startResourceSampling() {
        resourceSamplingTask?.cancel()
        resourceSamplingGeneration &+= 1
        let generation = resourceSamplingGeneration
        resourceUsageAccumulator.reset()
        resourceSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await SystemResourceMonitor.shared.snapshot()
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self, self.resourceSamplingGeneration == generation else { return }
                    self.resourceUsageAccumulator.record(snapshot)
                    self.recordPerformanceDiagnosticSample(
                        system: snapshot,
                        context: ["source": "query-sampler"]
                    )
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @discardableResult
    private func finishResourceSampling() -> QueryResourceUsage? {
        resourceSamplingTask?.cancel()
        resourceSamplingTask = nil
        resourceSamplingGeneration &+= 1
        guard let usage = resourceUsageAccumulator.usage else { return nil }
        resourceUsageAccumulator.reset()
        store.lastQueryResourceUsage = usage
        dependencies.performanceDiagnostics.recordMarker(
            phase: performanceDiagnosticPhase,
            message: "Query resource sampling finished.",
            jobID: activePerformanceDiagnosticJobID,
            context: performanceDiagnosticContext([
                "sampleCount": "\(usage.sampleCount)",
                "averageCPUPercent": String(format: "%.1f", usage.averageCPUPercent),
                "averageRAMUsedMB": String(format: "%.0f", usage.averageRAMUsedMB),
                "peakRAMUsedMB": String(format: "%.0f", usage.peakRAMUsedMB)
            ])
        )
        return usage
    }

    // MARK: Storage inventory

    var clipInventory: [ClipInventoryItem] {
        ClipInventory.items(from: store.speechEntries)
    }

    func sortedClipInventory(by field: ClipSortField, ascending: Bool) -> [ClipInventoryItem] {
        ClipInventory.sorted(clipInventory, by: field, ascending: ascending)
    }

    var totalStorageBytes: Int64 {
        ClipInventory.totalBytes(of: clipInventory)
    }

    func rename(_ entry: SpeechEntry, to displayName: String?) {
        do {
            try dependencies.speechEntryStore.rename(entry, to: displayName)
            loadSpeechEntries()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.rename", title: "Rename Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    func cleanupOrphanClips() {
        do {
            let removed = try dependencies.speechEntryStore.cleanupOrphanClips()
            store.userMessage = removed == 0 ? "No orphaned clips found." : "Removed \(removed) orphaned clip\(removed == 1 ? "" : "s")."
        } catch {
            record(AlkiSpeakError(code: "persistence.clips.cleanup", title: "Cleanup Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    func openClipsFolder() {
        guard let url = try? dependencies.speechEntryStore.clipsRootURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showClipInFinder(_ item: ClipInventoryItem) {
        let urls = item.segmentRelativePaths.compactMap { try? dependencies.speechEntryStore.absoluteURL(for: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyClipText(_ item: ClipInventoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    func deleteClip(_ item: ClipInventoryItem) {
        guard let entry = store.speechEntries.first(where: { $0.id == item.id }) else { return }
        delete(entry)
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
        store.voiceFavorites = favoritesStore.load()
        store.cloudSettings = dependencies.cloudSpeechSettings.load()
        store.playbackTuning = PlaybackTuning.load()
        dependencies.playbackCoordinator.applyTuning(store.playbackTuning)
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
                    resourceAfter: after,
                    resourceUsage: store.lastQueryResourceUsage
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
        // Intentionally does not gate on the current playback state: a new
        // request is allowed to override whatever is playing or generating
        // (`speak()` interrupts it first), so the user never has to pause or
        // stop before generating again.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText
            && (status.isAvailableForRemoteSpeech || isSelectedVoiceLocal || isSelectedVoiceEngineIndependent)
    }
}
