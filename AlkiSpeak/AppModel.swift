import Combine
import AVFoundation
import AppKit
import Foundation

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
        canSpeak(text: inputText)
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

    private var isSelectedVoiceLocal: Bool {
        selectedVoice.hasPrefix("apple:")
    }

    /// Edge and cloud voices are reached over the network like Kokoro, but
    /// don't depend on the local Kokoro engine being up — they should remain
    /// speakable even while the engine is starting, stopped, or failed.
    private var isSelectedVoiceEngineIndependent: Bool {
        selectedVoice.hasPrefix(EdgeSpeechGenerationService.idPrefix)
            || CloudSpeechGenerationService.isCloudVoice(selectedVoice)
            || NativeKokoroSpeechService.isNativeKokoroVoice(selectedVoice)
    }

    /// Only the Python Kokoro voices need the engine on port 7777.
    private var isSelectedVoicePythonKokoro: Bool {
        !selectedVoice.isEmpty && !isSelectedVoiceLocal && !isSelectedVoiceEngineIndependent
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

    func speakExternalText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appMode == .quick {
            pipeline.deleteActiveClips()
        }
        interruptForOverride()
        inputText = trimmed
        if !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning && isSelectedVoicePythonKokoro {
            if status == .stopped {
                // The request below starts the engine and waits for it.
                engine.markSleeping()
            } else {
                startEngine()
            }
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
        pipeline.stop()
    }

    func confirmPortSwitchAndStart() {
        engine.takeOverPortAndStart()
    }

    private func speak(text: String, addToHistory: Bool, targetLogEntryID: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSpeak(text: trimmed) else { return }
        guard !trimmed.isEmpty else { return }
        store.clearErrorMessage()
        pipeline.speak(
            text: trimmed,
            voice: selectedVoice,
            dialogueSpeakers: selectedDialogueSpeakers?.map(\.name),
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

    private func canSpeak(text: String) -> Bool {
        // Intentionally does not gate on the current playback state: a new
        // request is allowed to override whatever is playing or generating
        // (`speak()` interrupts it first), so the user never has to pause or
        // stop before generating again.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText
            && (status.isAvailableForRemoteSpeech || isSelectedVoiceLocal || isSelectedVoiceEngineIndependent || isEngineOnStandby)
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

    func speechJobFinishedGenerating(_ job: SpeechJob) {
        if isProMode && logMode == .auto {
            saveEntry(for: job)
        }
    }
}
