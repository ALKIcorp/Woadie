import Combine
import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    let store: AppStore
    private let dependencies: AppDependencies
    private let favoritesStore = VoiceFavoritesStore()
    @ObservationIgnored private lazy var voiceCatalog = VoiceCatalogController(
        store: store,
        dependencies: dependencies,
        favoritesStore: favoritesStore,
        selectVoice: { [weak self] in self?.selectedVoice = $0 },
        record: { [weak self] in self?.record($0) },
        trace: { [weak self] in self?.consoleTrace($0) }
    )
    @ObservationIgnored private lazy var diagnostics = SpeechDiagnostics(dependencies: dependencies, store: store) { [weak self] in
        self?.diagnosticsBaseContext() ?? [:]
    }
    @ObservationIgnored private lazy var pipeline = SpeechPipeline(store: store, dependencies: dependencies, diagnostics: diagnostics)
    @ObservationIgnored private lazy var engine = KokoroEngineController(
        store: store,
        dependencies: dependencies,
        diagnostics: diagnostics,
        selectedVoiceUsesEngine: { [weak self] in self?.isSelectedVoicePythonKokoro ?? false },
        fetchVoices: { [weak self] in await self?.fetchVoices() },
        stopPlayback: { [weak self] in self?.stopPlayback() },
        trace: { [weak self] in self?.consoleTrace($0) }
    )
    @ObservationIgnored private lazy var history = HistoryController(store: store, dependencies: dependencies) { [weak self] error in
        self?.record(error)
    }
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var tuningSaveTask: Task<Void, Never>?
    /// A long Apple-voice job's passages, split once rather than per word.
    @ObservationIgnored private var passageCache: (jobID: UUID, passages: [NSRange])?
    @ObservationIgnored private var hasRequestedAccessibilityPrompt = false
    @ObservationIgnored private var lastHotKeyClipboardChangeCount = NSPasteboard.general.changeCount

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
            guard newValue != store.selectedVoiceID else { return }
            store.selectedVoiceID = newValue
            noteRecentVoice(newValue)
            saveWorkspace()
            prepareForSelectedVoice()
        }
    }
    var message: String { store.userMessage }
    var selectedTextPermissionRequired: Bool { store.selectedTextPermissionRequired }
    var engineCheckMessage: String? {
        guard let issue = store.engineHealth.latestIssue else { return nil }
        return "\(issue.title): \(issue.description) Probable cause: \(issue.probableCause)"
    }
    var engineStatusLabel: String {
        if isEngineOnStandby { return "Kokoro Standby" }
        // The supervisor's state isn't observable. It changes along with the
        // health summary, so reading that redraws the label when it does.
        _ = store.engineHealth
        return dependencies.engineSupervisor.engineState.statusText
    }
    var chatItems: [SpeechEntry] { store.speechEntries }
    var playingId: UUID? { store.playbackState.activeLogEntryID }
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
        canSpeak(text: inputText, voice: selectedVoice)
    }

    var canEditText: Bool {
        status.isAvailableForRemoteSpeech || isSelectedVoiceLocal || isSelectedVoiceEngineIndependent || isEngineOnStandby
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
        store.voiceLabelsByID[selectedVoice] ?? "Select Voice"
    }

    func cycleVoice(_ offset: Int) {
        let ids = voiceOptions.filter { !$0.isLocal }.map(\.id)
        if let next = VoiceCycler.next(current: selectedVoice, in: ids, offset: offset) {
            selectedVoice = next
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
    var voiceSections: [VoiceGrouping.Section] { store.voiceSections }

    var voiceDropdownSections: [AlkiDropdownSection] { store.voiceDropdownSections }

    var voiceFavorites: Set<String> { store.voiceFavorites }

    func isFavorite(_ voiceID: String) -> Bool { voiceCatalog.isFavorite(voiceID) }

    func toggleFavorite(_ voiceID: String) { voiceCatalog.toggleFavorite(voiceID) }

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
        dependencies.playbackCoordinator.applyTuning(tuning)
        // A knob drag sends dozens of values a second; save once it settles.
        tuningSaveTask?.cancel()
        tuningSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.savePendingTuning()
        }
    }

    /// Writes a tuning change that is still waiting on `applyTuning`'s delay.
    func savePendingTuning() {
        guard tuningSaveTask != nil else { return }
        tuningSaveTask?.cancel()
        tuningSaveTask = nil
        store.playbackTuning.save()
    }

    // MARK: Cloud voices

    var cloudSettings: CloudSpeechSettings { store.cloudSettings }

    func hasCloudAPIKey(for provider: CloudProvider) -> Bool {
        voiceCatalog.hasCloudAPIKey(for: provider)
    }

    /// Saves (or, with an empty string, removes) a provider's key in the Keychain.
    func setCloudAPIKey(_ key: String, for provider: CloudProvider) {
        // Settings re-reads the Keychain after saving, so nothing to publish.
        _ = voiceCatalog.setCloudAPIKey(key, for: provider)
    }

    func setCloudCustomBaseURL(_ url: String) {
        voiceCatalog.setCloudCustomBaseURL(url)
    }

    func addCloudVoice(provider: CloudProvider, model: String, voice: String, label: String) {
        voiceCatalog.makeCloudVoice(provider: provider, model: model, voice: voice, label: label).map(appendCloudVoice)
    }

    func addDesignedLocalVoice(model localModel: LocalVoiceCatalog.Model, description: String, label: String) {
        voiceCatalog.makeDesignedLocalVoice(model: localModel, description: description, label: label).map(appendCloudVoice)
    }

    func addClonedLocalVoice(recording: URL, transcript: String, label: String) throws {
        appendCloudVoice(try voiceCatalog.makeClonedLocalVoice(recording: recording, transcript: transcript, label: label))
    }

    private func appendCloudVoice(_ cloudVoice: CloudVoice) {
        voiceCatalog.add(cloudVoice)
        selectedVoice = cloudVoice.voiceID
        if cloudVoice.provider == .localMLX {
            warmUpLocalVoiceServer()
            prepareLocalModel(cloudVoice.model)
        }
    }

    func addGeminiDialogueVoice(model: String, speakers: [DialogueSpeaker], label: String) {
        voiceCatalog.makeGeminiDialogueVoice(model: model, speakers: speakers, label: label).map(appendCloudVoice)
    }

    /// The cast when the selected voice is a dialogue voice, else `nil`.
    var selectedDialogueSpeakers: [DialogueSpeaker]? {
        guard let speakers = store.cloudSettings.voice(withID: selectedVoice)?.speakers, !speakers.isEmpty else { return nil }
        return speakers
    }

    /// Inline expression cues (e.g. `[Laughter]`) the selected voice's model reads.
    var selectedVoiceExpressionTags: [String] {
        guard let voice = store.cloudSettings.voice(withID: selectedVoice), voice.provider == .localMLX else { return [] }
        return LocalVoiceCatalog.model(withID: voice.model)?.expressionTags ?? []
    }

    /// Inserts `[tag]` at the cursor, replacing any selected text, or at the
    /// end without one. Spaces are added only where the tag would otherwise
    /// touch a word. Returns the character offset just after the insertion,
    /// for the editor to put the cursor back.
    @discardableResult
    func insertExpressionTag(_ tag: String, replacing range: Range<Int>? = nil) -> Int {
        let text = inputText
        let count = text.count
        let lower = min(max(range?.lowerBound ?? count, 0), count)
        let upper = min(max(range?.upperBound ?? count, lower), count)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        let before = text[..<start]
        let after = text[end...]

        var insertion = "[\(tag)]"
        if let previous = before.last, !previous.isWhitespace {
            insertion = " " + insertion
        }
        if after.first.map({ !$0.isWhitespace }) ?? true {
            insertion += " "
        }
        inputText = String(before) + insertion + String(after)
        return lower + insertion.count
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

    enum LocalModelState: Equatable {
        case preparing
        case failed(String)
    }

    /// Local models currently downloading/loading, or whose preparation failed.
    /// Absent means idle; Settings checks the disk for "downloaded".
    private(set) var localModelStates: [String: LocalModelState] = [:]

    /// Downloads and loads a local model in the background with no time limit,
    /// so its first speech request doesn't have to.
    enum ReadinessTone { case ready, busy, warning, off, problem }

    /// The status pill in plain words, about the voice that's selected:
    /// "Ready", "Warming up voice…", "Downloading voice (2.7 GB)…".
    var readiness: (text: String, tone: ReadinessTone) {
        if let cloud = store.cloudSettings.voice(withID: selectedVoice), cloud.provider == .localMLX {
            switch localModelStates[cloud.model] {
            case .preparing?:
                let size = LocalVoiceCatalog.model(withID: cloud.model).map { String(format: " (%.1f GB)", $0.downloadGB) } ?? ""
                return ("Downloading voice\(size)…", .busy)
            case .failed?:
                return ("Voice download failed", .problem)
            case nil:
                return ("Ready", .ready)
            }
        }
        if NativeKokoroSpeechService.isNativeKokoroVoice(selectedVoice) {
            switch nativeKokoroState {
            case .loading: return ("Loading voice…", .busy)
            case .failed: return ("Voice couldn't load", .problem)
            case .off, .ready: return ("Ready", .ready)
            }
        }
        // Standby wakes the engine on Generate, so it's ready as far as the user is concerned.
        guard isSelectedVoicePythonKokoro, !isEngineOnStandby else { return ("Ready", .ready) }
        switch status {
        case .starting, .retrying: return ("Warming up voice…", .busy)
        case .running, .idle: return ("Ready", .ready)
        case .busy: return ("Working…", .busy)
        case .degraded: return ("Ready · running slowly", .warning)
        case .timedOut, .stalled: return ("Voice engine not responding", .warning)
        case .stopped: return ("Voice engine off", .off)
        case .failed: return ("Voice engine failed", .problem)
        }
    }

    func prepareLocalModel(_ modelID: String) {
        guard localModelStates[modelID] != .preparing else { return }
        localModelStates[modelID] = .preparing
        Task { [localVoiceServer = dependencies.localVoiceServer] in
            do {
                try await localVoiceServer.prepareModel(modelID)
                self.localModelStates[modelID] = nil
            } catch {
                let message = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
                self.localModelStates[modelID] = .failed(message)
                self.consoleTrace("local model prepare failed model=\(modelID) error=\(String(describing: error))")
            }
        }
    }

    func hasCloudVoice(provider: CloudProvider, model: String, voice: String) -> Bool {
        voiceCatalog.hasCloudVoice(provider: provider, model: model, voice: voice)
    }

    /// One-click add for a verified local preset; a no-op if it's already added.
    func addLocalPreset(model: LocalVoiceCatalog.Model, voice: LocalVoiceCatalog.Voice) {
        guard !hasCloudVoice(provider: .localMLX, model: model.id, voice: voice.name) else { return }
        addCloudVoice(provider: .localMLX, model: model.id, voice: voice.name, label: voice.label)
    }

    // MARK: Native Kokoro (CoreML)

    enum NativeKokoroState: Equatable {
        case off
        case loading
        case ready(voiceCount: Int)
        case failed(String)
    }

    private(set) var nativeKokoroState: NativeKokoroState = .off

    var isNativeKokoroEnabled: Bool { dependencies.nativeKokoroService.isEnabled }

    /// Turns native Kokoro on, downloading the CoreML model (~170 MB) on first
    /// use, then lists its voices under "Kokoro (Native)".
    func enableNativeKokoro() {
        dependencies.nativeKokoroService.isEnabled = true
        loadNativeKokoro()
    }

    func disableNativeKokoro() {
        dependencies.nativeKokoroService.isEnabled = false
        nativeKokoroState = .off
        if NativeKokoroSpeechService.isNativeKokoroVoice(selectedVoice) {
            // `mergeVoiceOptions` keeps the selected ID alive on purpose.
            selectedVoice = AppConfig.defaultVoice
        }
        voiceCatalog.replaceNativeKokoroVoices(with: [])
    }

    private func loadNativeKokoro() {
        nativeKokoroState = .loading
        Task {
            do {
                let count = try await dependencies.nativeKokoroService.prepare()
                let native = try await dependencies.nativeKokoroService.fetchVoices()
                guard dependencies.nativeKokoroService.isEnabled else { return }
                voiceCatalog.replaceNativeKokoroVoices(with: native)
                // Report ready only once the voices are in the picker.
                nativeKokoroState = .ready(voiceCount: count)
            } catch {
                let message = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
                nativeKokoroState = .failed(message)
                consoleTrace("native Kokoro load failed error=\(String(describing: error))")
            }
        }
    }

    /// The account's Cartesia voices, for the Settings picker.
    func loadCartesiaVoices() async throws -> [CartesiaCatalog.Voice] {
        try await voiceCatalog.loadCartesiaVoices()
    }

    /// The account's ElevenLabs voices and TTS models, for the Settings pickers.
    func loadElevenLabsCatalog() async throws -> ElevenLabsCatalog {
        try await voiceCatalog.loadElevenLabsCatalog()
    }

    /// Called on app quit. Leaves alone a server the app adopted rather than launched.
    func shutDownLocalVoiceServer() {
        dependencies.localVoiceServer.stopOwnedServer()
    }

    func removeCloudVoice(_ cloudVoice: CloudVoice) {
        voiceCatalog.remove(cloudVoice)
    }

    var lastQueryResourceUsage: QueryResourceUsage? { store.lastQueryResourceUsage }

    var isResourceSamplingActiveForTesting: Bool { diagnostics.isResourceSamplingActive }

    private var isSelectedVoiceLocal: Bool { Self.isLocal(selectedVoice) }
    private var isSelectedVoiceEngineIndependent: Bool { Self.isEngineIndependent(selectedVoice) }
    private var isSelectedVoicePythonKokoro: Bool { Self.isPythonKokoro(selectedVoice) }

    private static func isLocal(_ voice: String) -> Bool {
        voice.hasPrefix("apple:")
    }

    /// Edge and cloud voices are reached over the network like Kokoro, but
    /// don't depend on the local Kokoro engine being up — they should remain
    /// speakable even while the engine is starting, stopped, or failed.
    private static func isEngineIndependent(_ voice: String) -> Bool {
        voice.hasPrefix(EdgeSpeechGenerationService.idPrefix)
            || CloudSpeechGenerationService.isCloudVoice(voice)
            || NativeKokoroSpeechService.isNativeKokoroVoice(voice)
    }

    /// Only the Python Kokoro voices need the engine on port 7777.
    private static func isPythonKokoro(_ voice: String) -> Bool {
        !voice.isEmpty && !isLocal(voice) && !isEngineIndependent(voice)
    }

    private var isSelectedVoiceLocalMLX: Bool {
        store.cloudSettings.voice(withID: selectedVoice)?.provider == .localMLX
    }

    /// The engine is off because the selected voice doesn't use it, or it
    /// went unused long enough to be stopped. It starts again when a Kokoro
    /// voice is picked or Generate is pressed.
    var isEngineOnStandby: Bool { engine.isOnStandby }

    private func schedulePythonEngineIdleStop() {
        engine.scheduleIdleStop()
    }

    /// Starts the Python Kokoro engine only when the selected voice needs it.
    /// With no cached Kokoro voice list yet, it starts once anyway so the
    /// picker can offer Kokoro voices.
    func startEngineIfNeeded() {
        guard isSelectedVoicePythonKokoro || cachedKokoroVoices.isEmpty else {
            consoleTrace("startEngineIfNeeded skipped; selected voice doesn't use the Kokoro engine")
            return
        }
        startEngine()
    }

    /// Starts whatever background server a newly picked voice needs, so it is
    /// warm by the time the user presses Generate.
    private func prepareForSelectedVoice() {
        guard !AppConfig.isRunningUnitTests else { return }
        if isSelectedVoicePythonKokoro {
            // Only one Kokoro runtime at a time: the CoreML model and the
            // Python engine hold the same weights.
            Task { [nativeKokoro = dependencies.nativeKokoroService] in await nativeKokoro.release() }
            startEngine()
        } else if NativeKokoroSpeechService.isNativeKokoroVoice(selectedVoice) {
            stopPythonKokoroEngineIfIdle()
        } else if isSelectedVoiceLocalMLX {
            warmUpLocalVoiceServer()
        }
        schedulePythonEngineIdleStop()
    }

    /// Stops the Python Kokoro engine to free its memory (a native Kokoro
    /// voice took over, or it went unused), unless it is still generating.
    func stopPythonKokoroEngineIfIdle() {
        engine.stopIfIdle()
    }

    private var cachedKokoroVoices: [String] { voiceCatalog.cachedKokoroVoices }

    init(store: AppStore, dependencies: AppDependencies) {
        self.store = store
        self.dependencies = dependencies
        consoleTrace("init isRunningUnitTests=\(AppConfig.isRunningUnitTests) kokoroPath=\(AppConfig.kokoroPath) baseURL=\(AppConfig.serverBaseURL.absoluteString)")
        if !AppConfig.isRunningUnitTests {
            diagnostics.startSession()
        }
        (dependencies.localSpeechService as? AppleSpeechService)?.onWillSpeakRange = { [weak store] range in
            store?.appleSpokenRange = range
        }

        NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.consoleTrace("availableVoicesDidChangeNotification received")
                self?.refreshLocalVoices()
            }
            .store(in: &cancellables)

        consoleTrace("wiring service callbacks")
        engine.wireSupervisorCallbacks()
        // Created now, not on first use, so it owns the playback callbacks.
        pipeline.host = self
        loadPreferences()
        consoleTrace("loading workspace")
        loadWorkspace()
        loadSpeechEntries()
        consoleTrace("refreshing local voices")
        refreshLocalVoices()
        if !AppConfig.isRunningUnitTests {
            diagnostics.startIdleSampling()
            consoleTrace("starting engine from AppModel.init if the selected voice needs it")
            startEngineIfNeeded()
            // Edge voices don't depend on the Kokoro engine, so fetch them right
            // away instead of waiting on waitForEngineReady().
            Task { await fetchVoices() }
            if isSelectedVoiceLocalMLX {
                warmUpLocalVoiceServer()
            }
            // Fetch anything not on disk yet; downloaded models load on first use.
            let localModels = Set(store.cloudSettings.voices.filter { $0.provider == .localMLX }.map(\.model))
            for model in localModels where !MLXAudioServerManager.isModelDownloaded(model) {
                prepareLocalModel(model)
            }
            if dependencies.nativeKokoroService.isEnabled {
                let cachedNative = dependencies.nativeKokoroService.cachedVoices
                if cachedNative.isEmpty {
                    loadNativeKokoro()
                } else {
                    // fetchVoices lists these from the cache; the model loads
                    // on the first native request instead of at launch.
                    nativeKokoroState = .ready(voiceCount: cachedNative.count)
                }
            }
        } else {
            consoleTrace("unit test mode detected; skipping auto-start")
        }
    }

    func startEngine() { engine.start() }
    func stopEngine() { engine.stop() }
    func restartEngine() { engine.restart() }
    func toggleEngine() { engine.toggle() }

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
            pipeline.deleteActiveClips()
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
        pipeline.interrupt()
    }

    // MARK: Text cleanup and pronunciations

    /// What the selected voice will actually be sent for `text`: cleaned up,
    /// then with the pronunciation list applied.
    func spokenText(for text: String) -> String {
        spokenText(for: text, voice: selectedVoice)
    }

    func spokenText(for text: String, voice: String) -> String {
        let cleaned = TextNormalizer.clean(text, options: store.textCleanup)
        // Phoneme markup is a Kokoro (Python engine) feature.
        return TextNormalizer.applyPronunciations(cleaned, entries: store.pronunciations, phonemesSupported: Self.isPythonKokoro(voice))
    }

    func setTextCleanup(_ options: TextCleanupOptions) {
        store.textCleanup = options
        if !AppConfig.isRunningUnitTests { options.save() }
    }

    func setPronunciations(_ entries: [PronunciationEntry]) {
        store.pronunciations = entries
        if !AppConfig.isRunningUnitTests { PronunciationEntry.save(entries) }
    }

    /// Speaks `text` in the selected voice, cleaned up, without logging it.
    /// Used to try a pronunciation.
    func previewText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        store.clearErrorMessage()
        pipeline.speak(text: spokenText(for: trimmed), voice: selectedVoice, dialogueSpeakers: nil, addToHistory: false, targetLogEntryID: nil)
    }

    // MARK: Read-along

    /// What the read-along view shows: the passage being spoken and the part
    /// to highlight. Nil when read-along is off or nothing is playing.
    struct ReadAlongState: Equatable {
        let passage: String
        /// Within `passage` (UTF-16).
        let highlight: NSRange?
        /// The words of `passage`, for click-to-seek.
        let words: [NSRange]
        let segmentIndex: Int
        /// Where `passage` starts in its segment (UTF-16).
        let passageOffset: Int
        let canSeek: Bool
    }

    func setReadAlongMode(_ mode: ReadAlongMode) {
        store.readAlongMode = mode
        if !AppConfig.isRunningUnitTests {
            UserDefaults.standard.set(mode.rawValue, forKey: ReadAlongMode.defaultsKey)
        }
    }

    var readAlongState: ReadAlongState? {
        let mode = store.readAlongMode
        let playback = store.playbackState
        guard mode != .off,
              playback.state == .playing || playback.state == .paused || playback.state == .preparing,
              let jobID = playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return nil }

        if job.voiceID.hasPrefix("apple:") {
            // Apple reports the exact range it's speaking; it can't seek.
            let text = job.text
            let spoken = store.appleSpokenRange
            let passages: [NSRange]
            if let cached = passageCache, cached.jobID == job.id {
                passages = cached.passages
            } else {
                passages = ReadAlong.passages(in: text)
                passageCache = (job.id, passages)
            }
            let passage = passages.last { $0.location <= (spoken?.location ?? 0) } ?? passages.first
            guard let passage else { return nil }
            let passageText = (text as NSString).substring(with: passage)
            var highlight: NSRange?
            if let spoken {
                let local = NSRange(location: spoken.location - passage.location, length: spoken.length)
                highlight = mode == .word
                    ? local
                    : ReadAlong.unit(containing: local.location, in: ReadAlong.units(in: passageText, mode: .sentence))
            }
            return ReadAlongState(passage: passageText, highlight: highlight, words: [], segmentIndex: 0, passageOffset: passage.location, canSeek: false)
        }

        let segments = job.segments.map { ReadAlong.Segment(length: ($0.text as NSString).length, duration: $0.durationSeconds) }
        guard let position = ReadAlong.position(elapsed: playback.elapsedTime, segments: segments) else { return nil }
        let text = job.segments[position.segment].text
        let passages = ReadAlong.passages(in: text)
        let passage = passages.last { $0.location <= position.offset } ?? NSRange(location: 0, length: (text as NSString).length)
        let passageText = (text as NSString).substring(with: passage)
        let local = position.offset - passage.location
        let highlight = playback.state == .preparing ? nil : ReadAlong.unit(containing: local, in: ReadAlong.units(in: passageText, mode: mode))
        return ReadAlongState(
            passage: passageText,
            highlight: highlight,
            words: ReadAlong.units(in: passageText, mode: .word),
            segmentIndex: position.segment,
            passageOffset: passage.location,
            canSeek: true
        )
    }

    /// Jumps playback to a word the user clicked in the read-along view.
    func seekReadAlong(segmentIndex: Int, offset: Int) {
        guard let jobID = store.playbackState.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return }
        let segments = job.segments.map { ReadAlong.Segment(length: ($0.text as NSString).length, duration: $0.durationSeconds) }
        seek(to: ReadAlong.time(segment: segmentIndex, offset: offset, segments: segments))
    }

    // MARK: Books

    /// The chapter job that's playing: which chapter, and where in the
    /// chapter's spoken text the job's text starts (for resuming mid-chapter).
    @ObservationIgnored private var bookPlayback: (jobID: UUID, chapter: Int, baseOffset: Int)?
    @ObservationIgnored private var bookProgressTask: Task<Void, Never>?
    @ObservationIgnored private var bookRenderTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?

    var currentChapter: BookChapter? {
        guard let book = store.book, book.chapters.indices.contains(store.bookChapter) else { return nil }
        return book.chapters[store.bookChapter]
    }

    /// Where this book was left off, if anywhere.
    var bookProgress: BookProgress? {
        store.book.flatMap { BookProgress.all()[$0.id] }
    }

    func openBook(_ book: Book) {
        try? book.save()
        store.book = book
        store.bookRender = nil
        if !AppConfig.isRunningUnitTests {
            UserDefaults.standard.set(book.id, forKey: BookProgress.lastBookKey)
        }
        let saved = BookProgress.all()[book.id]
        store.bookChapter = min(saved?.chapter ?? 0, book.chapters.count - 1)
        inputText = book.chapters[store.bookChapter].text
        var message = "Opened “\(book.title)” · \(book.chapters.count) chapters · \(book.wordCount.formatted()) words"
        if let saved, saved.chapter > 0 || saved.offset > 0 {
            message += " · Resume where you left off in chapter \(store.bookChapter + 1)"
        }
        store.userMessage = message
    }

    func closeBook() {
        saveBookPosition()
        bookRenderTask?.cancel()
        bookProgressTask?.cancel()
        bookPlayback = nil
        store.book = nil
        store.bookRender = nil
        if !AppConfig.isRunningUnitTests {
            UserDefaults.standard.removeObject(forKey: BookProgress.lastBookKey)
        }
    }

    /// Reopens the last book at launch.
    private func restoreLastBook() {
        guard let id = UserDefaults.standard.string(forKey: BookProgress.lastBookKey),
              let book = Book.load(id: id)
        else { return }
        store.book = book
        store.bookChapter = min(BookProgress.all()[id]?.chapter ?? 0, book.chapters.count - 1)
    }

    func selectChapter(_ index: Int) {
        guard let book = store.book, book.chapters.indices.contains(index) else { return }
        saveBookPosition()
        let wasPlaying = bookPlayback != nil && (store.playbackState.state == .playing || store.playbackState.state == .preparing)
        store.bookChapter = index
        inputText = book.chapters[index].text
        saveProgress(chapter: index, offset: 0)
        if wasPlaying { listenToChapter(resume: false) }
    }

    /// Plays the current chapter, from where it was left off when `resume`.
    func listenToChapter(resume: Bool) {
        guard let chapter = currentChapter, let book = store.book else { return }
        let spoken = spokenText(for: chapter.text)
        var start = 0
        if resume, let saved = BookProgress.all()[book.id], saved.chapter == store.bookChapter, saved.offset > 0 {
            // Back up to the start of the sentence that was playing.
            let sentences = ReadAlong.units(in: spoken, mode: .sentence)
            start = ReadAlong.unit(containing: saved.offset, in: sentences)?.location ?? 0
        }
        let text = (spoken as NSString).substring(from: min(start, (spoken as NSString).length))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        store.clearErrorMessage()
        store.appleSpokenRange = nil
        pipeline.speak(text: text, voice: selectedVoice, dialogueSpeakers: nil, addToHistory: false, targetLogEntryID: nil)
        guard let jobID = store.playbackState.activeJobID else { return }
        bookPlayback = (jobID, store.bookChapter, start)
        trackBookPosition()
    }

    /// Saves the listening position every few seconds while a chapter plays.
    private func trackBookPosition() {
        bookProgressTask?.cancel()
        guard !AppConfig.isRunningUnitTests else { return }
        bookProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.bookPlayback != nil else { return }
                self.saveBookPosition()
            }
        }
    }

    /// Records the chapter and character the listener is at.
    func saveBookPosition() {
        guard let playing = bookPlayback,
              store.playbackState.activeJobID == playing.jobID,
              let job = store.speechJobs.first(where: { $0.id == playing.jobID })
        else { return }
        let segments = job.segments.map { ReadAlong.Segment(length: ($0.text as NSString).length, duration: $0.durationSeconds) }
        guard let position = ReadAlong.position(elapsed: store.playbackState.elapsedTime, segments: segments) else { return }
        // Segments are consecutive slices of the job's text, separated by a space.
        let before = job.segments.prefix(position.segment).reduce(0) { $0 + ($1.text as NSString).length + 1 }
        saveProgress(chapter: playing.chapter, offset: playing.baseOffset + before + position.offset)
    }

    private func saveProgress(chapter: Int, offset: Int) {
        guard let book = store.book, !AppConfig.isRunningUnitTests else { return }
        BookProgress.save(BookProgress(chapter: chapter, offset: offset), for: book.id)
    }

    /// A chapter finished: continue with the next unless the sleep timer says stop.
    private func bookChapterFinished(jobID: UUID) {
        guard let playing = bookPlayback, playing.jobID == jobID, let book = store.book else { return }
        bookPlayback = nil
        bookProgressTask?.cancel()
        let next = playing.chapter + 1
        if store.sleepTimer == .endOfChapter {
            setSleepTimer(.off)
            saveProgress(chapter: min(next, book.chapters.count - 1), offset: 0)
            store.userMessage = "Sleep timer: stopped at the end of the chapter."
            return
        }
        guard book.chapters.indices.contains(next) else {
            saveProgress(chapter: 0, offset: 0)
            store.userMessage = "Finished “\(book.title)”."
            return
        }
        store.bookChapter = next
        inputText = book.chapters[next].text
        saveProgress(chapter: next, offset: 0)
        listenToChapter(resume: false)
    }

    // MARK: Sleep timer

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTimerTask?.cancel()
        store.sleepTimer = timer
        guard case .at(let date) = timer else { return }
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.saveBookPosition()
            self.pipeline.stop()
            self.store.sleepTimer = .off
            self.store.userMessage = "Sleep timer: playback stopped."
        }
    }

    // MARK: Rendering and export

    /// The chapter's audio file for the selected voice and current text
    /// settings, so a change to either renders afresh.
    private func renderedChapterURL(_ index: Int, in book: Book, voice: String) -> URL {
        let spoken = spokenText(for: book.chapters[index].text)
        let key = AudioClipCache.key(text: spoken, voiceConfiguration: pipeline.cacheConfiguration(forVoice: voice))
        return book.folder.appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(String(format: "%03d-", index + 1) + key.prefix(16) + ".caf")
    }

    /// Generates every chapter's audio in the background, caching each piece
    /// so playback is instant, and saving one file per chapter for export.
    /// Calls `then` when everything is rendered.
    func renderBook(then: (@MainActor () -> Void)? = nil) {
        guard let book = store.book else { return }
        let voice = selectedVoice
        guard !voice.hasPrefix("apple:") else {
            store.userMessage = "Apple voices speak live and can't be rendered ahead. Pick another voice to render or export."
            return
        }
        bookRenderTask?.cancel()
        let plan = book.chapters.indices.map { index in
            (index: index, url: renderedChapterURL(index, in: book, voice: voice), segments: pipeline.segmentTexts(for: spokenText(for: book.chapters[index].text), voice: voice))
        }
        let total = plan.reduce(0) { $0 + $1.segments.count }
        store.bookRender = BookRenderState(done: 0, total: total, isRunning: true, message: nil)
        let renderID = UUID()
        speechRequestStarted(jobID: renderID)
        bookRenderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.speechRequestFinished(jobID: renderID) }
            var done = 0
            do {
                for chapter in plan {
                    if FileManager.default.fileExists(atPath: chapter.url.path) {
                        done += chapter.segments.count
                        self.store.bookRender?.done = done
                        continue
                    }
                    var clips: [Data] = []
                    for segment in chapter.segments {
                        // Respect the resource guard: wait while the Mac is busy.
                        while !(await SystemResourceMonitor.shared.canProceed()) {
                            self.store.bookRender?.message = "Waiting for the Mac to be less busy…"
                            try await Task.sleep(for: .seconds(2))
                        }
                        self.store.bookRender?.message = nil
                        try Task.checkCancellation()
                        clips.append(try await self.pipeline.audio(for: segment, voice: voice).data)
                        done += 1
                        self.store.bookRender?.done = done
                    }
                    let url = chapter.url
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await Task.detached(priority: .utility) { try AudiobookExporter.writeChapter(clips: clips, to: url) }.value
                }
                self.store.bookRender = BookRenderState(done: total, total: total, isRunning: false, message: "Whole book rendered")
                then?()
            } catch is CancellationError {
                self.store.bookRender?.isRunning = false
                self.store.bookRender?.message = "Paused"
            } catch {
                self.store.bookRender?.isRunning = false
                self.store.bookRender?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func pauseBookRender() {
        bookRenderTask?.cancel()
    }

    enum AudiobookExportKind { case m4b, chapterFiles }

    /// Renders anything missing, then writes a .m4b with chapter markers or
    /// a folder of per-chapter MP3s.
    func exportBook(_ kind: AudiobookExportKind) {
        guard let book = store.book else { return }
        let destination: URL
        switch kind {
        case .m4b:
            let panel = NSSavePanel()
            panel.title = "Export Audiobook"
            panel.nameFieldStringValue = book.title + ".m4b"
            panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Audio]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        case .chapterFiles:
            let panel = NSOpenPanel()
            panel.title = "Choose a Folder for the Chapter Files"
            panel.prompt = "Export Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url.appendingPathComponent(book.title.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        }
        let voice = selectedVoice
        renderBook { [weak self] in
            guard let self else { return }
            let chapters = book.chapters.indices.map { index -> (title: String, file: URL, duration: TimeInterval) in
                let url = self.renderedChapterURL(index, in: book, voice: voice)
                let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
                return (book.chapters[index].title, url, duration)
            }
            self.store.bookRender?.message = "Writing the audiobook…"
            Task {
                do {
                    switch kind {
                    case .m4b: try await AudiobookExporter.exportM4B(chapters: chapters, title: book.title, to: destination)
                    case .chapterFiles: try await AudiobookExporter.exportChapterFiles(chapters: chapters, to: destination)
                    }
                    self.store.bookRender?.message = "Exported"
                    self.store.userMessage = "Exported “\(book.title)” to \(destination.lastPathComponent)."
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    self.store.bookRender?.message = nil
                    self.store.userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: Documents and web pages

    /// True while a document or web page is loading.
    private(set) var isImporting = false

    /// Shows an Open panel for PDFs, EPUBs, Word, RTF, HTML, Markdown and text.
    func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "Open a Document to Read Aloud"
        panel.prompt = "Open"
        panel.allowedContentTypes = DocumentImporter.readableTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDocument(at: url)
    }

    /// Loads a file's text into the editor.
    func importDocument(at url: URL) {
        loadDocument(named: url.lastPathComponent) {
            try await DocumentImporter.importDocument(at: url)
        }
    }

    /// Loads a web page's main article into the editor, optionally speaking it.
    func importWebPage(_ url: URL, speakWhenLoaded: Bool = false) {
        loadDocument(named: url.host() ?? "the page", speakWhenLoaded: speakWhenLoaded) {
            try await DocumentImporter.importWebPage(url)
        }
    }

    /// Reads the clipboard aloud. A copied link reads the page it points to.
    func speakClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            store.userMessage = "The clipboard has no text to read."
            return
        }
        if let url = DocumentImporter.webURL(in: text) {
            importWebPage(url, speakWhenLoaded: true)
        } else {
            speakExternalText(text)
        }
    }

    private func loadDocument(
        named name: String,
        speakWhenLoaded: Bool = false,
        _ load: @escaping @Sendable () async throws -> ImportedDocument
    ) {
        isImporting = true
        store.userMessage = "Opening \(name)…"
        Task {
            defer { isImporting = false }
            do {
                let document = try await Task.detached(priority: .userInitiated) { try await load() }.value
                if document.chapters.count >= 2 {
                    openBook(Book(title: document.title, source: document.source, chapters: document.chapters))
                    if speakWhenLoaded { listenToChapter(resume: true) }
                    return
                }
                if store.book != nil { closeBook() }
                inputText = document.text
                var message = "Loaded “\(document.title)” · \(document.wordCount.formatted()) words"
                if document.wasTruncated { message += " (the first part only; it's very long)" }
                store.userMessage = message
                if speakWhenLoaded { speak() }
            } catch {
                store.userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Speaks a short sample in `voiceID`, in its own language, without
    /// changing the selected voice or adding anything to the log.
    /// Speaks `text` in `voice` (any voice ID, even one not in the list yet,
    /// like a blend being tried) without changing the selection or the log.
    func speakSample(_ text: String, voice: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        store.clearErrorMessage()
        store.appleSpokenRange = nil
        pipeline.speak(text: spokenText(for: trimmed), voice: voice, dialogueSpeakers: nil, addToHistory: false, targetLogEntryID: nil)
    }

    /// One voice's audio for `text`, without playing it, for side-by-side
    /// comparison. Cached, so comparing again is instant.
    func sampleAudio(_ text: String, voice: String) async throws -> (data: Data, latencyMs: Int, fromCache: Bool) {
        try await pipeline.audio(for: spokenText(for: text), voice: voice)
    }

    // MARK: Kokoro blends

    /// Saves a blend as a voice and selects it.
    func addKokoroBlend(name: String, parts: [KokoroBlend.Part]) {
        let clean = parts.filter { $0.weight > 0 }
        guard clean.count >= 2 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let blend = KokoroBlend(name: trimmed.isEmpty ? "My blend" : trimmed, parts: clean)
        store.kokoroBlends.append(blend)
        if !AppConfig.isRunningUnitTests { KokoroBlend.save(store.kokoroBlends) }
        voiceCatalog.mergeVoiceOptions(remote: store.voiceOptions.filter { !$0.isLocal }.map(\.id))
        selectedVoice = blend.voiceID
    }

    func removeKokoroBlend(_ blend: KokoroBlend) {
        if selectedVoice == blend.voiceID, let first = blend.parts.first {
            selectedVoice = first.voice
        }
        store.kokoroBlends.removeAll { $0.id == blend.id }
        if !AppConfig.isRunningUnitTests { KokoroBlend.save(store.kokoroBlends) }
        store.voiceFavorites.remove(blend.voiceID)
        voiceCatalog.mergeVoiceOptions(remote: store.voiceOptions.filter { !$0.isLocal && $0.id != blend.voiceID }.map(\.id))
    }

    func previewVoice(_ voiceID: String) {
        guard let option = store.voiceOptions.first(where: { $0.id == voiceID }) else { return }
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        store.clearErrorMessage()
        let speakers = store.cloudSettings.voice(withID: voiceID)?.speakers?.map(\.name)
        let text: String
        if let speakers, speakers.count >= 2 {
            text = "\(speakers[0]): Hi, I'm \(speakers[0]).\n\(speakers[1]): And I'm \(speakers[1]). This is how we sound."
        } else {
            text = VoiceNaming.sampleText(for: option)
        }
        pipeline.speak(text: text, voice: voiceID, dialogueSpeakers: speakers, addToHistory: false, targetLogEntryID: nil)
    }

    /// Speaks text from outside the window (the Services menu, a hotkey, a
    /// link, Shortcuts or the local API), in `voice` or the selected voice.
    func speakExternalText(_ text: String, voice: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let voice = voice ?? selectedVoice
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        inputText = trimmed
        if !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning && Self.isPythonKokoro(voice) {
            if status == .stopped {
                // The request below starts the engine and waits for it.
                engine.markSleeping()
            } else {
                startEngine()
            }
        }
        speak(text: trimmed, voice: voice, addToHistory: false, targetLogEntryID: nil)
    }

    // MARK: Automation

    /// Starts the local API if it's turned on. Links and Shortcuts need no setup.
    func startAutomation() {
        LocalAPIController.shared.configure(target: self, secrets: dependencies.secretStore)
    }

    /// Runs an `alkispeak://` link.
    func perform(_ command: AutomationCommand) {
        switch command {
        case .speak(let text, let voiceQuery):
            let voice = resolveAutomationVoice(voiceQuery)
            speakExternalText(text, voice: voice)
            if voice == nil, let voiceQuery {
                store.userMessage = "There's no voice called \u{201C}\(voiceQuery)\u{201D}, so this uses \(selectedVoiceLabel)."
            }
        case .stop:
            stopPlayback()
        case .pauseOrResume:
            handlePauseHotKey()
        }
    }

    /// The voice an automation request names: an exact ID, or a voice whose
    /// name or label matches, ignoring case. nil names the selected voice.
    func resolveAutomationVoice(_ query: String?) -> String? {
        AutomationVoices.resolve(query, in: voiceOptions, selected: selectedVoice)
    }

    /// One WAV of `text` in `voice`, without playing it. Apple voices only
    /// speak live, so they can't be saved this way.
    func renderAutomationAudio(text: String, voice: String) async throws -> Data {
        guard !Self.isLocal(voice) else {
            throw AlkiSpeakError.generation(
                code: "automation.live-only-voice",
                title: "Voice Can't Be Saved",
                message: "Apple voices speak live and can't be saved as audio.",
                recoverySuggestion: "Pick a Kokoro, Edge or cloud voice."
            )
        }
        let spoken = spokenText(for: text, voice: voice)
        var clips: [Data] = []
        for segment in pipeline.segmentTexts(for: spoken, voice: voice) {
            clips.append(try await pipeline.audio(for: segment, voice: voice).data)
        }
        return try AudioJoiner.wav(from: clips)
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

    enum HotKeyOutcome: Equatable {
        case speakingSelection
        case speakingClipboard
        case speakingEditor
        case stopped
        case nothingSelected
        case permissionRequired
    }

    /// The global speak shortcut: stop if something is playing, otherwise
    /// speak the other app's selection, then fresh clipboard text, then (when
    /// AlkiSpeak itself is in front) the editor.
    func handleSpeakHotKey() async -> HotKeyOutcome {
        switch store.playbackState.state {
        case .playing, .preparing, .paused:
            stopPlayback()
            return .stopped
        case .idle, .stopped, .failed:
            break
        }
        if NSApp.isActive {
            guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingSelected }
            speak()
            return .speakingEditor
        }
        switch await dependencies.selectedTextReader.readFocusedSelection() {
        case .selected(let text):
            store.selectedTextPermissionRequired = false
            speakExternalText(text)
            return .speakingSelection
        case .permissionRequired:
            store.selectedTextPermissionRequired = true
            requestAccessibilityAccessOnce()
            return .permissionRequired
        case .noSelection:
            // Only clipboard text the shortcut hasn't already spoken, so a
            // stale clipboard isn't read out by surprise.
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != lastHotKeyClipboardChangeCount,
                  let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return .nothingSelected }
            lastHotKeyClipboardChangeCount = pasteboard.changeCount
            speakExternalText(text)
            return .speakingClipboard
        }
    }

    func handlePauseHotKey() {
        guard store.playbackState.state == .playing || store.playbackState.state == .paused else { return }
        togglePlayback()
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
        history.exportEntry(entry)
    }

    func importSpeechEntry() {
        history.importSpeechEntry()
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

    /// Replays a saved entry and puts its text and voice back in the editor.
    func open(_ entry: SpeechEntry) {
        stopPlayback()
        inputText = entry.textContent
        selectedVoice = entry.voice
        history.loadForPlayback(entry)
    }

    /// Replays a saved entry without touching the editor.
    func reinsert(_ entry: SpeechEntry) {
        stopPlayback()
        history.loadForPlayback(entry)
    }

    func savePlaybackToDefaultFolder() {
        history.savePlaybackToDownloads { [weak self] job in
            self?.saveEntry(for: job)
        }
    }

    func savePlaybackAs() {
        history.savePlaybackAs()
    }

    func sharePlaybackAudio(from anchorRect: CGRect = .zero) {
        history.sharePlaybackAudio(from: anchorRect)
    }

    func delete(_ entry: SpeechEntry) {
        history.delete(entry)
    }

    func togglePlayback() {
        dependencies.playbackCoordinator.togglePlayback()
    }

    func stopPlayback() {
        saveBookPosition()
        pipeline.stop()
    }

    func confirmPortSwitchAndStart() {
        engine.takeOverPortAndStart()
    }

    private func speak(text: String, voice: String? = nil, addToHistory: Bool, targetLogEntryID: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voice ?? selectedVoice
        guard canSpeak(text: trimmed, voice: voice) else { return }
        guard !trimmed.isEmpty else { return }
        store.clearErrorMessage()
        store.appleSpokenRange = nil
        pipeline.speak(
            text: spokenText(for: trimmed, voice: voice),
            voice: voice,
            dialogueSpeakers: voice == selectedVoice ? selectedDialogueSpeakers?.map(\.name) : nil,
            addToHistory: addToHistory,
            targetLogEntryID: targetLogEntryID
        )
    }

    /// Fetches the Kokoro, Edge and cloud voice lists independently — each is
    /// a different dependency (local engine, Microsoft's service, user config),
    /// so one being unreachable should not blank out the others' voices.
    private func fetchVoices() async {
        await voiceCatalog.fetchVoices()
    }

    private func refreshLocalVoices() {
        voiceCatalog.refreshLocalVoices()
    }

    private func record(_ error: AlkiSpeakError) {
        store.record(error)
    }

    private func refreshTelemetry() {
        engine.refreshTelemetry()
    }

    /// App state stamped on every diagnostics event.
    private func diagnosticsBaseContext() -> [String: String] {
        [
            "engineStatus": status.rawValue,
            "enginePID": dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil",
            "playbackState": store.playback.state.rawValue,
            "appMode": appMode.rawValue,
            "voiceSource": SpeechDiagnostics.voiceSource(for: selectedVoice)
        ]
    }

    // MARK: Storage inventory

    var clipInventory: [ClipInventoryItem] { history.clipInventory }

    func sortedClipInventory(by field: ClipSortField, ascending: Bool) -> [ClipInventoryItem] {
        ClipInventory.sorted(clipInventory, by: field, ascending: ascending)
    }

    var totalStorageBytes: Int64 {
        ClipInventory.totalBytes(of: clipInventory)
    }

    func rename(_ entry: SpeechEntry, to displayName: String?) { history.rename(entry, to: displayName) }
    func cleanupOrphanClips() { history.cleanupOrphanClips() }
    func openClipsFolder() { history.openClipsFolder() }
    func showClipInFinder(_ item: ClipInventoryItem) { history.showClipInFinder(item) }
    func copyClipText(_ item: ClipInventoryItem) { history.copyClipText(item) }
    func deleteClip(_ item: ClipInventoryItem) { history.deleteClip(item) }

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

    private static let recentVoicesKey = "AlkiSpeak.recentVoices"

    private func noteRecentVoice(_ voiceID: String) {
        var recent = store.recentVoiceIDs.filter { $0 != voiceID }
        recent.insert(voiceID, at: 0)
        store.recentVoiceIDs = Array(recent.prefix(VoiceGrouping.recentLimit + 1))
        guard !AppConfig.isRunningUnitTests else { return }
        UserDefaults.standard.set(store.recentVoiceIDs, forKey: Self.recentVoicesKey)
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
        store.recentVoiceIDs = UserDefaults.standard.stringArray(forKey: Self.recentVoicesKey) ?? []
        store.kokoroBlends = KokoroBlend.load()
        store.textCleanup = TextCleanupOptions.load()
        store.readAlongMode = ReadAlongMode.load()
        if !AppConfig.isRunningUnitTests { restoreLastBook() }
        store.pronunciations = PronunciationEntry.load()
        store.cloudSettings = dependencies.cloudSpeechSettings.load()
        store.playbackTuning = PlaybackTuning.load()
        dependencies.playbackCoordinator.applyTuning(store.playbackTuning)
    }

    private func loadSpeechEntries() {
        history.loadSpeechEntries()
    }

    private func saveEntry(for job: SpeechJob) {
        history.saveEntry(for: job, generationSeconds: diagnostics.generationSeconds, resourceBefore: diagnostics.resourceBefore)
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

    private func canSpeak(text: String, voice: String) -> Bool {
        // Intentionally does not gate on the current playback state: a new
        // request is allowed to override whatever is playing or generating
        // (`speak()` interrupts it first), so the user never has to pause or
        // stop before generating again.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText
            && (status.isAvailableForRemoteSpeech || Self.isLocal(voice) || Self.isEngineIndependent(voice) || isEngineOnStandby)
    }
}

extension AppModel: SpeechPipelineHost {
    func prepareEngine(forVoice voice: String) async throws {
        // Only the Python Kokoro voices need the engine; it may be asleep.
        guard !voice.hasPrefix("apple:"),
              !voice.hasPrefix(EdgeSpeechGenerationService.idPrefix),
              !CloudSpeechGenerationService.isCloudVoice(voice),
              !NativeKokoroSpeechService.isNativeKokoroVoice(voice)
        else { return }
        try await engine.wake()
    }

    func speechRequestStarted(jobID: UUID) {
        dependencies.engineSupervisor.noteRequestStarted(jobID: jobID)
        engine.cancelIdleStop()
    }

    func speechRequestFinished(jobID: UUID) {
        dependencies.engineSupervisor.noteRequestFinished(jobID: jobID)
        schedulePythonEngineIdleStop()
    }

    func speechPlaybackFinished(jobID: UUID) {
        bookChapterFinished(jobID: jobID)
    }

    func speechJobFinishedGenerating(_ job: SpeechJob) {
        if isProMode && logMode == .auto {
            saveEntry(for: job)
        }
    }
}
