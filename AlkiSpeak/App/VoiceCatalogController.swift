import Foundation

/// The voice picker's catalog and the user's voice setup: which voices exist
/// (Apple, Kokoro, native Kokoro, Edge, cloud), favorites, and the cloud and
/// local voices added in Settings. Changing the selected voice goes back
/// through `AppModel`, which persists it and starts whatever engine it needs.
@MainActor
final class VoiceCatalogController {
    private let store: AppStore
    private let dependencies: AppDependencies
    private let favoritesStore: VoiceFavoritesStore
    private let selectVoice: (String) -> Void
    private let record: (AlkiSpeakError) -> Void
    private let trace: (String) -> Void

    init(
        store: AppStore,
        dependencies: AppDependencies,
        favoritesStore: VoiceFavoritesStore,
        selectVoice: @escaping (String) -> Void,
        record: @escaping (AlkiSpeakError) -> Void,
        trace: @escaping (String) -> Void
    ) {
        self.store = store
        self.dependencies = dependencies
        self.favoritesStore = favoritesStore
        self.selectVoice = selectVoice
        self.record = record
        self.trace = trace
    }

    private var selectedVoice: String { store.selectedVoiceID }

    // MARK: Favorites

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

    // MARK: Cloud and local voice setup

    func hasCloudAPIKey(for provider: CloudProvider) -> Bool {
        !(dependencies.secretStore.secret(for: provider.id) ?? "").isEmpty
    }

    /// Saves (or, with an empty string, removes) a provider's key in the
    /// Keychain. Returns true when the stored key changed.
    @discardableResult
    func setCloudAPIKey(_ key: String, for provider: CloudProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try dependencies.secretStore.setSecret(trimmed.isEmpty ? nil : trimmed, for: provider.id)
            store.userMessage = trimmed.isEmpty ? "\(provider.name) key removed." : "\(provider.name) key saved to Keychain."
            return true
        } catch let error as AlkiSpeakError {
            record(error)
        } catch {
            store.userMessage = error.localizedDescription
        }
        return false
    }

    func setCloudCustomBaseURL(_ url: String) {
        store.cloudSettings.customBaseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
    }

    func hasCloudVoice(provider: CloudProvider, model: String, voice: String) -> Bool {
        store.cloudSettings.voices.contains { $0.providerID == provider.id && $0.model == model && $0.voice == voice }
    }

    /// A cloud voice from the Add Voice form, or nil when model or voice is blank.
    func makeCloudVoice(provider: CloudProvider, model: String, voice: String, label: String) -> CloudVoice? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !voice.isEmpty else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudVoice(
            providerID: provider.id,
            model: model,
            voice: voice,
            label: trimmedLabel.isEmpty ? "\(provider.name) · \(voice)" : trimmedLabel
        )
    }

    /// A local voice built from a description instead of a built-in name.
    func makeDesignedLocalVoice(model localModel: LocalVoiceCatalog.Model, description: String, label: String) -> CloudVoice? {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localModel.supportsVoiceDesign, !description.isEmpty else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = description.count > 32
            ? String(description.prefix(32)).trimmingCharacters(in: .whitespaces) + "…"
            : description
        let fallbackLabel = "Designed · " + shortened
        return CloudVoice(
            providerID: CloudProvider.localMLX.id,
            model: localModel.id,
            voice: "",
            label: trimmedLabel.isEmpty ? fallbackLabel : trimmedLabel,
            instructions: description
        )
    }

    /// A local voice cloned from a recording. `transcript` must be the
    /// exact words spoken in it; Qwen3 lines the two up to learn the voice.
    /// The clip is converted and kept by the app, so the original can go.
    func makeClonedLocalVoice(recording: URL, transcript: String, label: String) throws -> CloudVoice {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw AlkiSpeakError.generation(
                code: "clone.transcript",
                title: "Transcript Needed",
                message: "Type the exact words spoken in the recording.",
                recoverySuggestion: "The cloned voice copies how those words were said, so they must match the clip."
            )
        }
        let id = UUID()
        let stored = try VoiceCloneReference.store(from: recording, id: id)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudVoice(
            id: id,
            providerID: CloudProvider.localMLX.id,
            model: LocalVoiceCatalog.cloningModelID,
            voice: "",
            label: trimmedLabel.isEmpty ? "My voice (local)" : trimmedLabel,
            referenceAudioPath: stored.path,
            referenceText: transcript
        )
    }

    /// A Gemini voice that reads `Name: line` scripts with two prebuilt
    /// voices. Names must be distinct, non-empty and colon-free.
    func makeGeminiDialogueVoice(model: String, speakers: [DialogueSpeaker], label: String) -> CloudVoice? {
        let cast = speakers.map {
            DialogueSpeaker(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), voice: $0.voice)
        }
        let validVoices = Set(GeminiSpeechCatalog.voices.map(\.name))
        guard !model.isEmpty,
              cast.count == DialogueScript.maxSpeakers,
              cast.allSatisfy({ !$0.name.isEmpty && !$0.name.contains(":") && validVoices.contains($0.voice) }),
              Set(cast.map { $0.name.lowercased() }).count == cast.count
        else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudVoice(
            providerID: CloudProvider.gemini.id,
            model: model,
            voice: cast.map(\.voice).joined(separator: "+"),
            label: trimmedLabel.isEmpty ? "Gemini dialogue · " + cast.map(\.name).joined(separator: " & ") : trimmedLabel,
            speakers: cast
        )
    }

    /// Saves a new voice and lists it in the picker.
    func add(_ cloudVoice: CloudVoice) {
        store.cloudSettings.voices.append(cloudVoice)
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
        refreshCloudVoices()
    }

    func remove(_ cloudVoice: CloudVoice) {
        store.cloudSettings.voices.removeAll { $0.id == cloudVoice.id }
        dependencies.cloudSpeechSettings.save(store.cloudSettings)
        if let referencePath = cloudVoice.referenceAudioPath {
            VoiceCloneReference.remove(atPath: referencePath)
        }
        if selectedVoice == cloudVoice.voiceID {
            // `mergeVoiceOptions` keeps the selected ID alive on purpose, so
            // move off the deleted voice before it re-adds it as a ghost.
            selectVoice(AppConfig.defaultVoice)
        }
        if store.voiceFavorites.remove(cloudVoice.voiceID) != nil {
            favoritesStore.save(store.voiceFavorites)
        }
        refreshCloudVoices()
    }

    /// The account's Cartesia voices, for the Settings picker.
    func loadCartesiaVoices() async throws -> [CartesiaCatalog.Voice] {
        try await dependencies.cartesiaVoices.fetchVoices()
    }

    /// The account's ElevenLabs voices and TTS models, for the Settings pickers.
    func loadElevenLabsCatalog() async throws -> ElevenLabsCatalog {
        try await dependencies.elevenLabsCatalog.fetchCatalog()
    }

    // MARK: Catalog

    private static let kokoroVoiceCacheKey = "AlkiSpeak.kokoroVoiceCache"

    /// The Kokoro voice list from the last time the engine answered, so the
    /// picker still lists Kokoro voices while the engine is off.
    var cachedKokoroVoices: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.kokoroVoiceCacheKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.kokoroVoiceCacheKey) }
    }

    func fetchVoices() async {
        trace("fetchVoices starting")
        async let kokoroResult = fetchVoicesResult(from: dependencies.generationService, label: "kokoro")
        async let edgeResult = fetchVoicesResult(from: dependencies.edgeSpeechService, label: "edge")
        async let cloudResult = fetchVoicesResult(from: dependencies.cloudSpeechService, label: "cloud")
        async let nativeResult = fetchVoicesResult(from: dependencies.nativeKokoroService, label: "kokoro-native")
        let (kokoro, edge, cloud, native) = await (kokoroResult, edgeResult, cloudResult, nativeResult)

        var combined: [String] = []
        if let kokoro, !kokoro.isEmpty {
            cachedKokoroVoices = kokoro
            combined += kokoro
        } else {
            // The engine only runs while a Kokoro voice is selected.
            combined += cachedKokoroVoices
        }
        if let native { combined += native }
        if let edge { combined += edge }
        if let cloud { combined += cloud }

        trace("fetchVoices completed count=\(combined.count) voices=\(combined.joined(separator: ","))")
        if combined.isEmpty {
            store.userMessage = "Voice list empty. Using last voice."
        }
        mergeVoiceOptions(remote: combined)
    }

    private func fetchVoicesResult(from service: SpeechGenerating, label: String) async -> [String]? {
        do {
            return try await service.fetchVoices()
        } catch {
            trace("fetchVoices(\(label)) failed error=\(String(describing: error))")
            return nil
        }
    }

    func refreshLocalVoices() {
        trace("refreshLocalVoices starting")
        dependencies.localSpeechService.refreshVoices()
        trace("refreshLocalVoices localCount=\(dependencies.localSpeechService.voiceOptions.count)")
        mergeVoiceOptions(remote: store.voiceOptions.filter { !$0.isLocal }.map(\.id))
    }

    /// Rebuilds the catalog's cloud entries from settings without re-fetching
    /// the Kokoro and Edge lists over the network.
    func refreshCloudVoices() {
        let others = store.voiceOptions
            .filter { !$0.isLocal && !CloudSpeechGenerationService.isCloudVoice($0.id) }
            .map(\.id)
        mergeVoiceOptions(remote: others + store.cloudSettings.voices.map(\.voiceID))
    }

    /// Replaces the native Kokoro entries, keeping every other remote voice.
    func replaceNativeKokoroVoices(with native: [String]) {
        let others = store.voiceOptions
            .filter { !$0.isLocal && $0.source != .kokoroNative }
            .map(\.id)
        mergeVoiceOptions(remote: others + native)
    }

    func mergeVoiceOptions(remote: [String]) {
        // On cold start, `refreshLocalVoices()` runs before /voices returns, so `remote` is
        // often empty. Without preserving the workspace Kokoro id here, `selectedVoice`
        // (e.g. af_heart) is not in the Apple-only list and gets replaced by the first
        // Apple voice — remote synthesis then never runs until the user re-picks Kokoro.
        var remoteIDs = remote
        if !selectedVoice.hasPrefix("apple:"), !selectedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
            if NativeKokoroSpeechService.isNativeKokoroVoice(id) {
                return VoiceOption(id: id, label: "Kokoro Native - \(NativeKokoroSpeechService.stripPrefix(id))", source: .kokoroNative)
            }
            return VoiceOption(id: id, label: "Kokoro - \(id)", source: .kokoro)
        }
        let options = dependencies.localSpeechService.voiceOptions + remoteOptions
        if options != store.voiceOptions {
            store.voiceOptions = options
        }
        let resolved = VoiceSelection.resolved(
            current: selectedVoice,
            in: store.voiceOptions,
            fallback: AppConfig.defaultVoice
        )
        if resolved != selectedVoice {
            selectVoice(resolved)
        }
    }
}
