import SwiftUI

/// Which custom overlay is showing over the main content.
enum AppOverlay: Identifiable {
    case settings
    case storage

    var id: Int {
        switch self {
        case .settings: return 0
        case .storage: return 1
        }
    }
}

/// Dimmed modal container shared by the settings and storage overlays.
struct OverlayContainer<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            AlkiGlassSurface(cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                            .font(WoadieTheme.rounded(size: 18, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                    .padding(20)

                    Divider().opacity(0.4)

                    content
                }
            }
            .frame(maxWidth: 640, maxHeight: 560)
            .padding(40)
        }
        .transition(.opacity)
    }
}

struct SettingsOverlayView: View {
    @ObservedObject var model: AppModel
    var onOpenStorage: () -> Void
    var onClose: () -> Void

    var body: some View {
        OverlayContainer(title: "Settings", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureSettingRow(
                        title: "Appearance",
                        systemImage: "circle.lefthalf.filled",
                        subtitle: "Light, dark, or follow the system",
                        initiallyExpanded: true
                    ) {
                        Picker("Appearance", selection: Binding(
                            get: { model.appearance },
                            set: { model.setAppearance($0) }
                        )) {
                            ForEach(AppAppearance.allCases, id: \.self) { appearance in
                                Text(appearance.label).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    DisclosureSettingRow(
                        title: "Playback Tuning",
                        systemImage: "slider.horizontal.3",
                        subtitle: "Listen-only speed and pitch — clips are never re-rendered",
                        initiallyExpanded: true
                    ) {
                        PlaybackTuningControls(model: model)
                    }

                    DisclosureSettingRow(
                        title: "Cloud Voices",
                        systemImage: "cloud",
                        subtitle: model.cloudSettings.voices.isEmpty
                            ? "OpenRouter, OpenAI, Mistral, local mlx-audio, or any OpenAI-compatible endpoint"
                            : "\(model.cloudSettings.voices.count) configured"
                    ) {
                        CloudVoicesSettings(model: model)
                    }

                    DisclosureSettingRow(
                        title: "Native Kokoro",
                        systemImage: "cpu",
                        subtitle: nativeKokoroSubtitle
                    ) {
                        NativeKokoroSettings(model: model)
                    }

                    DisclosureSettingRow(
                        title: "Storage",
                        systemImage: "internaldrive",
                        subtitle: ByteCountFormatter.string(fromByteCount: model.totalStorageBytes, countStyle: .file) + " across \(model.clipInventory.count) clips"
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                WoadieButton(title: "Open Clips Folder", systemImage: "folder", variant: .default) {
                                    model.openClipsFolder()
                                }
                                WoadieButton(title: "Clean Up Orphans", systemImage: "trash", variant: .default) {
                                    model.cleanupOrphanClips()
                                }
                            }
                            WoadieButton(title: "Open Storage Dashboard", systemImage: "square.grid.2x2", variant: .primary) {
                                onOpenStorage()
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

extension SettingsOverlayView {
    var nativeKokoroSubtitle: String {
        switch model.nativeKokoroState {
        case .off: return "Kokoro on the Neural Engine, without the Python engine"
        case .loading: return "Loading…"
        case .ready(let count): return "On · \(count) voices"
        case .failed: return "Couldn't load"
        }
    }
}

/// Turns the in-process CoreML Kokoro on or off. It sits beside the Python
/// Kokoro engine rather than replacing it.
private struct NativeKokoroSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runs Kokoro-82M inside AlkiSpeak on the Neural Engine via speech-swift (Apache-2.0). Its voices appear under Kokoro (Native) and work even when the Python Kokoro engine is stopped.")
                .font(WoadieTheme.mono(size: 10, weight: .medium))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                switch model.nativeKokoroState {
                case .off:
                    WoadieButton(title: "Turn On (~170 MB download)", systemImage: "arrow.down.circle", variant: .primary) {
                        model.enableNativeKokoro()
                    }
                case .loading:
                    ProgressView().controlSize(.small)
                    Text("Downloading and loading the model…")
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                case .ready:
                    WoadieButton(title: "Turn Off", systemImage: "power", variant: .default) {
                        model.disableNativeKokoro()
                    }
                case .failed(let message):
                    WoadieButton(title: "Retry", systemImage: "arrow.clockwise", variant: .default) {
                        model.enableNativeKokoro()
                    }
                    WoadieButton(title: "Turn Off", systemImage: "power", variant: .default) {
                        model.disableNativeKokoro()
                    }
                    Text(message)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.destructive)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct PlaybackTuningControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tuningRow(
                label: "Speed",
                value: model.playbackTuning.speed,
                display: String(format: "%.2fx", model.playbackTuning.speed),
                range: PlaybackTuning.speedRange,
                step: 0.05,
                onChange: model.setPlaybackSpeed
            )
            tuningRow(
                label: "Pitch",
                value: model.playbackTuning.pitch,
                display: String(format: "%+.0f st", model.playbackTuning.pitch),
                range: PlaybackTuning.pitchRange,
                step: 1,
                onChange: model.setPlaybackPitch
            )
            Button("Reset to default") { model.resetPlaybackTuning() }
                .buttonStyle(.plain)
                .font(WoadieTheme.mono(size: 10, weight: .semibold))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                .disabled(model.playbackTuning.isDefault)
        }
    }

    private func tuningRow(
        label: String,
        value: Double,
        display: String,
        range: ClosedRange<Double>,
        step: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(WoadieTheme.rounded(size: 12, weight: .semibold))
                Spacer()
                Text(display)
                    .font(WoadieTheme.mono(size: 11, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
            }
            Slider(
                value: Binding(get: { value }, set: { onChange($0) }),
                in: range,
                step: step
            )
        }
    }
}

/// Add/remove cloud voices and manage each provider's Keychain-stored key.
/// Keys are write-only here: once saved they are never read back into the UI.
private struct CloudVoicesSettings: View {
    @ObservedObject var model: AppModel
    @State private var providerID = CloudProvider.openRouter.id
    @State private var apiKey = ""
    @State private var customBaseURL = ""
    @State private var modelID = ""
    @State private var voiceID = ""
    @State private var label = ""
    @State private var elevenLabsCatalog: ElevenLabsCatalog?
    @State private var isLoadingCatalog = false
    @State private var catalogError: String?
    @State private var designDescription = ""
    @State private var designLabel = ""
    @State private var cartesiaVoices: [CartesiaCatalog.Voice]?
    @State private var dialogueNames = ["Joe", "Jane"]
    @State private var dialogueVoices = ["Puck", "Kore"]

    private var provider: CloudProvider {
        CloudProvider.provider(withID: providerID) ?? .openRouter
    }

    private var hasKey: Bool { model.hasCloudAPIKey(for: provider) }

    private var canAdd: Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!provider.requiresAPIKey || hasKey)
            && (provider.defaultBaseURL != nil || !model.cloudSettings.customBaseURL.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $providerID) {
                ForEach(CloudProvider.all) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if provider.defaultBaseURL == nil {
                HStack {
                    TextField("Base URL, e.g. https://host/v1", text: $customBaseURL)
                        .textFieldStyle(.roundedBorder)
                    WoadieButton(title: "Save", variant: .default) {
                        model.setCloudCustomBaseURL(customBaseURL)
                    }
                }
            } else if let base = provider.defaultBaseURL {
                caption(base)
            }

            if provider.acceptsAPIKey {
                HStack {
                    SecureField(hasKey ? "Key saved in Keychain — paste to replace" : "API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    WoadieButton(title: "Save Key", systemImage: "key", variant: .default) {
                        model.setCloudAPIKey(apiKey, for: provider)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        IconActionButton(systemImage: "trash") {
                            model.setCloudAPIKey("", for: provider)
                        }
                        .help("Remove the saved \(provider.name) key")
                    }
                }
            }

            if provider == .elevenLabs && hasKey {
                elevenLabsPickers
            }
            if provider == .gemini {
                geminiPickers
                if hasKey {
                    geminiDialogueBuilder
                }
            }
            if provider == .localMLX {
                localPresets
            }
            if provider == .cartesia && hasKey {
                cartesiaPickers
            }

            HStack {
                TextField("Model", text: $modelID, prompt: Text(provider.modelPrompt))
                    .textFieldStyle(.roundedBorder)
                TextField("Voice", text: $voiceID, prompt: Text(provider.voicePrompt))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                WoadieButton(title: "Add Voice", systemImage: "plus", variant: .primary) {
                    model.addCloudVoice(provider: provider, model: modelID, voice: voiceID, label: label)
                    voiceID = ""
                    label = ""
                }
                .disabled(!canAdd)
            }
            if provider.requiresAPIKey && !hasKey {
                caption("Save a \(provider.name) API key before adding voices.")
            }

            if !model.cloudSettings.voices.isEmpty {
                Divider().opacity(0.4)
                ForEach(model.cloudSettings.voices) { voice in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.label)
                                .font(WoadieTheme.rounded(size: 12, weight: .semibold))
                            caption("\(voice.provider?.name ?? voice.providerID) · \(voice.model) · \(voiceSummary(voice))")
                        }
                        Spacer()
                        IconActionButton(systemImage: "trash") {
                            model.removeCloudVoice(voice)
                        }
                        .help("Remove this voice")
                    }
                }
            }
        }
        .onAppear { customBaseURL = model.cloudSettings.customBaseURL }
    }

    /// Fills the model and voice fields from the account instead of raw IDs.
    @ViewBuilder
    private var elevenLabsPickers: some View {
        if let catalog = elevenLabsCatalog {
            HStack {
                Picker("Voice", selection: Binding(
                    get: { voiceID },
                    set: { id in
                        voiceID = id
                        label = catalog.voices.first { $0.voiceID == id }?.name ?? label
                    }
                )) {
                    Text("Choose a voice").tag("")
                    ForEach(catalog.voices) { voice in
                        Text(voice.category.map { "\(voice.name) · \($0)" } ?? voice.name).tag(voice.voiceID)
                    }
                }
                Picker("Model", selection: $modelID) {
                    ForEach(catalog.models) { model in
                        Text(model.name).tag(model.modelID)
                    }
                }
            }
            .pickerStyle(.menu)
            caption("\(catalog.voices.count) voices · \(catalog.models.count) speech models on this account")
        } else {
            HStack {
                WoadieButton(title: isLoadingCatalog ? "Loading…" : "Load My Voices", systemImage: "arrow.down.circle", variant: .default) {
                    loadCatalog()
                }
                .disabled(isLoadingCatalog)
                if let catalogError {
                    caption(catalogError)
                }
            }
        }
    }

    /// Verified local models with one-click Add per voice. The model downloads
    /// on first use, so its size is shown up front.
    private var localPresets: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LocalVoiceCatalog.models) { localModel in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(localModel.name)
                            .font(WoadieTheme.rounded(size: 12, weight: .semibold))
                        badge(localModel.license)
                        badge(String(format: "%.1f GB download", localModel.downloadGB))
                    }
                    caption(localModel.summary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(localModel.voices) { voice in
                            let added = model.hasCloudVoice(provider: .localMLX, model: localModel.id, voice: voice.name)
                            WoadieButton(
                                title: voice.name.replacingOccurrences(of: "_", with: " "),
                                systemImage: added ? "checkmark" : "plus",
                                variant: .default
                            ) {
                                model.addLocalPreset(model: localModel, voice: voice)
                            }
                            .disabled(added)
                            .help(added ? "Already in your voices" : "Add \(voice.label)")
                        }
                    }
                    if localModel.supportsVoiceDesign {
                        HStack {
                            TextField("Or describe a voice, e.g. a warm, gentle storyteller", text: $designDescription)
                                .textFieldStyle(.roundedBorder)
                            TextField("Label", text: $designLabel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            WoadieButton(title: "Design", systemImage: "wand.and.stars", variant: .default) {
                                model.addDesignedLocalVoice(model: localModel, description: designDescription, label: designLabel)
                                designDescription = ""
                                designLabel = ""
                            }
                            .disabled(designDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            caption("Or enter any other mlx-audio model below.")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(WoadieTheme.mono(size: 9, weight: .semibold))
            .foregroundStyle(WoadieTheme.foregroundSubtle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(WoadieTheme.borderSubtle))
    }

    /// Gemini's voices and models are fixed, so no request is needed to list them.
    private var geminiPickers: some View {
        HStack {
            Picker("Voice", selection: Binding(
                get: { voiceID },
                set: { name in
                    voiceID = name
                    label = name.isEmpty ? label : "Gemini \(name)"
                    if modelID.isEmpty, let first = GeminiSpeechCatalog.models.first {
                        modelID = first.id
                    }
                }
            )) {
                Text("Choose a voice").tag("")
                ForEach(GeminiSpeechCatalog.voices) { voice in
                    Text("\(voice.name) · \(voice.trait)").tag(voice.name)
                }
            }
            Picker("Model", selection: $modelID) {
                Text("Choose a model").tag("")
                ForEach(GeminiSpeechCatalog.models, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
        .pickerStyle(.menu)
    }

    /// Fills the voice from the account's Cartesia library; models are fixed.
    @ViewBuilder
    private var cartesiaPickers: some View {
        if let voices = cartesiaVoices {
            HStack {
                Picker("Voice", selection: Binding(
                    get: { voiceID },
                    set: { id in
                        voiceID = id
                        label = voices.first { $0.id == id }.map { "Cartesia \($0.name)" } ?? label
                        if modelID.isEmpty, let first = CartesiaCatalog.models.first {
                            modelID = first.id
                        }
                    }
                )) {
                    Text("Choose a voice").tag("")
                    ForEach(voices) { voice in
                        let detail = [voice.tagline, voice.language].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        Text(detail.isEmpty ? voice.name : "\(voice.name) · \(detail)").tag(voice.id)
                    }
                }
                Picker("Model", selection: $modelID) {
                    Text("Choose a model").tag("")
                    ForEach(CartesiaCatalog.models, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }
            .pickerStyle(.menu)
            caption("\(voices.count) voices on this account")
        } else {
            HStack {
                WoadieButton(title: isLoadingCatalog ? "Loading…" : "Load My Voices", systemImage: "arrow.down.circle", variant: .default) {
                    isLoadingCatalog = true
                    catalogError = nil
                    Task {
                        do {
                            cartesiaVoices = try await model.loadCartesiaVoices()
                        } catch {
                            catalogError = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
                        }
                        isLoadingCatalog = false
                    }
                }
                .disabled(isLoadingCatalog)
                if let catalogError {
                    caption(catalogError)
                }
            }
        }
    }

    private func voiceSummary(_ voice: CloudVoice) -> String {
        if let speakers = voice.speakers, !speakers.isEmpty {
            return speakers.map { "\($0.name) (\($0.voice))" }.joined(separator: " & ")
        }
        return voice.isDesigned ? "“\(voice.instructions ?? "")”" : voice.voice
    }

    private var dialogueNamesAreValid: Bool {
        let names = dialogueNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return names.allSatisfy { !$0.isEmpty && !$0.contains(":") }
            && Set(names.map { $0.lowercased() }).count == names.count
    }

    /// Two named speakers, each read by a prebuilt voice, in one Gemini voice.
    private var geminiDialogueBuilder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Two-speaker dialogue")
                .font(WoadieTheme.rounded(size: 12, weight: .semibold))
            ForEach(0..<DialogueScript.maxSpeakers, id: \.self) { index in
                HStack {
                    TextField("Speaker \(index + 1)", text: $dialogueNames[index])
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Picker("Voice", selection: $dialogueVoices[index]) {
                        ForEach(GeminiSpeechCatalog.voices) { voice in
                            Text("\(voice.name) · \(voice.trait)").tag(voice.name)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            HStack {
                caption("Then write lines like “\(dialogueNames[0]): Hi!” and “\(dialogueNames[1]) (calm and relaxed): Hello!”")
                Spacer()
                WoadieButton(title: "Add Dialogue", systemImage: "person.2", variant: .default) {
                    let speakers = zip(dialogueNames, dialogueVoices).map { DialogueSpeaker(name: $0, voice: $1) }
                    model.addGeminiDialogueVoice(
                        model: modelID.isEmpty ? (GeminiSpeechCatalog.models.first?.id ?? "") : modelID,
                        speakers: speakers,
                        label: ""
                    )
                }
                .disabled(!dialogueNamesAreValid)
            }
            if !dialogueNamesAreValid {
                caption("Give each speaker a different name without a colon.")
            }
        }
    }

    private func loadCatalog() {
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                let catalog = try await model.loadElevenLabsCatalog()
                elevenLabsCatalog = catalog
                if modelID.isEmpty, let preferred = catalog.preferredModelID {
                    modelID = preferred
                }
            } catch {
                catalogError = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
            }
            isLoadingCatalog = false
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WoadieTheme.mono(size: 10, weight: .medium))
            .foregroundStyle(WoadieTheme.foregroundSubtle)
    }
}

struct StorageDashboardView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var sortField: ClipSortField = .date
    @State private var ascending = false
    @State private var renameTarget: ClipInventoryItem?
    @State private var renameText = ""

    private var items: [ClipInventoryItem] {
        model.sortedClipInventory(by: sortField, ascending: ascending)
    }

    var body: some View {
        OverlayContainer(title: "Storage", onClose: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Picker("Sort", selection: $sortField) {
                        ForEach(ClipSortField.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)

                    Button {
                        ascending.toggle()
                    } label: {
                        Image(systemName: ascending ? "arrow.up" : "arrow.down")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(ascending ? "Ascending" : "Descending")

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: model.totalStorageBytes, countStyle: .file))
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }

                if items.isEmpty {
                    Text("No saved clips yet")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $renameTarget) { item in
            renameSheet(item)
        }
    }

    private func row(_ item: ClipInventoryItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(WoadieTheme.rounded(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    label(item.voice)
                    label(String(format: "%.1fs", item.durationSeconds))
                    label(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))
                    label(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                IconActionButton(systemImage: "pencil") {
                    renameText = item.displayName
                    renameTarget = item
                }
                IconActionButton(systemImage: "doc.on.doc") {
                    model.copyClipText(item)
                }
                IconActionButton(systemImage: "folder") {
                    model.showClipInFinder(item)
                }
                IconActionButton(systemImage: "trash") {
                    model.deleteClip(item)
                }
            }
        }
        .padding(12)
        .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(WoadieTheme.mono(size: 9, weight: .medium))
            .foregroundStyle(WoadieTheme.foregroundSubtle)
    }

    private func renameSheet(_ item: ClipInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Clip")
                .font(WoadieTheme.rounded(size: 16, weight: .semibold))
            TextField("Display name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { renameTarget = nil }
                    .buttonStyle(.plain)
                Spacer()
                WoadieButton(title: "Save", variant: .primary) {
                    if let entry = model.store.speechEntries.first(where: { $0.id == item.id }) {
                        model.rename(entry, to: renameText)
                    }
                    renameTarget = nil
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
