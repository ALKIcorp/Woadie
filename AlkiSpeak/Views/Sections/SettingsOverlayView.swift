import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which custom overlay is showing over the main content.
enum AppOverlay: Identifiable {
    case settings
    case storage
    case voices(VoicesTab)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .storage: return "storage"
        case .voices: return "voices"
        }
    }
}

/// Dimmed modal container shared by the settings and storage overlays.
struct OverlayContainer<Content: View>: View {
    let title: String
    var maxWidth: CGFloat = 640
    var maxHeight: CGFloat = 560
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
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .padding(40)
        }
        .transition(.opacity)
    }
}

struct SettingsOverlayView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case voices = "Voices & Services"
        case engines = "Downloads & Engines"
        case storage = "Storage"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .playback: return "slider.horizontal.3"
            case .voices: return "person.wave.2"
            case .engines: return "arrow.down.circle"
            case .storage: return "internaldrive"
            }
        }
    }

    var model: AppModel
    var onOpenStorage: () -> Void
    var onClose: () -> Void
    @State private var tab: Tab = .general
    @Environment(\.openVoices) private var openVoices

    var body: some View {
        OverlayContainer(title: "Settings", maxWidth: 800, maxHeight: 620, onClose: onClose) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Tab.allCases) { item in
                        Button { tab = item } label: {
                            Label(item.rawValue, systemImage: item.systemImage)
                                .font(WoadieTheme.rounded(size: 13, weight: tab == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(tab == item ? WoadieTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 210)

                Divider().opacity(0.4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:
            SettingsSection("Appearance", subtitle: "Light, dark, or follow the system") {
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
                .frame(maxWidth: 320)
            }
            SettingsSection("Keyboard Shortcuts", subtitle: "Speak selected text from any app") {
                HotKeySettings()
            }
        case .playback:
            SettingsSection("Speed and Pitch", subtitle: "Changes what you hear; saved clips are never re-rendered") {
                PlaybackTuningControls(model: model)
            }
        case .voices:
            SettingsSection("Your Voices", subtitle: "Pick, preview, clone or describe voices") {
                HStack {
                    WoadieButton(title: "Open Voices", systemImage: "person.wave.2", variant: .primary) { openVoices(.mine) }
                    WoadieButton(title: "New Voice…", systemImage: "plus", variant: .default) { openVoices(.new) }
                }
            }
            SettingsSection(
                "Online Services and Local Models",
                subtitle: model.cloudSettings.voices.isEmpty
                    ? "ElevenLabs, OpenAI, Gemini, OpenRouter, Mistral, or voices that run on this Mac"
                    : "\(model.cloudSettings.voices.count) added"
            ) {
                CloudVoicesSettings(model: model)
            }
        case .engines:
            SettingsSection("Voice Downloads", subtitle: "Free voices that run on this Mac download once, the first time you use them") {
                LocalModelDownloads(model: model)
            }
            SettingsSection("Kokoro on the Neural Engine", subtitle: nativeKokoroSubtitle) {
                NativeKokoroSettings(model: model)
            }
            SettingsSection("Kokoro Engine", subtitle: "Starts by itself when a Kokoro voice needs it and stops after 3 minutes unused") {
                HStack {
                    Text(model.status.isProcessExpectedAlive ? "Running" : "Off")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                    WoadieButton(title: model.startStopLabel, systemImage: model.startStopSystemImage, variant: .default) {
                        model.toggleEngine()
                    }
                }
            }
        case .storage:
            SettingsSection("Saved Clips", subtitle: storageSubtitle) {
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
    }
}

/// A titled group within a Settings tab.
private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(WoadieTheme.rounded(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// Each local model: downloaded, downloading, or a button to fetch it now.
private struct LocalModelDownloads: View {
    var model: AppModel
    /// Disk checks walk the Hugging Face cache, so they run on appear and
    /// when a download finishes, not on every render.
    @State private var downloaded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(LocalVoiceCatalog.models) { localModel in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localModel.name).font(WoadieTheme.rounded(size: 12, weight: .semibold))
                        Text(localModel.summary)
                            .font(WoadieTheme.mono(size: 9, weight: .medium))
                            .foregroundStyle(WoadieTheme.foregroundSubtle)
                            .lineLimit(1)
                    }
                    Spacer()
                    status(localModel)
                }
                .padding(10)
                .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.localModelStates) { _, _ in refresh() }
    }

    @ViewBuilder
    private func status(_ localModel: LocalVoiceCatalog.Model) -> some View {
        switch model.localModelStates[localModel.id] {
        case .preparing?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: "Downloading %.1f GB…", localModel.downloadGB))
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
            }
        case .failed(let message)?:
            WoadieButton(title: "Retry Download", systemImage: "arrow.clockwise", variant: .default) {
                model.prepareLocalModel(localModel.id)
            }
            .help(message)
        case nil:
            if downloaded.contains(localModel.id) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.success)
            } else {
                WoadieButton(title: String(format: "Download %.1f GB", localModel.downloadGB), systemImage: "arrow.down.circle", variant: .default) {
                    model.prepareLocalModel(localModel.id)
                }
            }
        }
    }

    private func refresh() {
        downloaded = Set(LocalVoiceCatalog.models.map(\.id).filter { MLXAudioServerManager.isModelDownloaded($0) })
    }
}

extension SettingsOverlayView {
    /// Builds the clip list once for both numbers.
    var storageSubtitle: String {
        let clips = model.clipInventory
        let bytes = ClipInventory.totalBytes(of: clips)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " across \(clips.count) clips"
    }

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
    var model: AppModel

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

private struct HotKeySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HotKeyRecorderRow(label: "Speak selection / Stop", action: .speakOrStop)
            HotKeyRecorderRow(label: "Pause / Resume", action: .pauseOrResume)
            Text("Works in any app. With nothing selected, it reads new clipboard text; with AlkiSpeak in front, it reads the editor.")
                .font(WoadieTheme.mono(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HotKeyRecorderRow: View {
    let label: String
    let action: GlobalHotKeyAction
    @State private var shortcut: HotKeyShortcut?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflict = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(WoadieTheme.mono(size: 11, weight: .medium))
            Spacer()
            if conflict {
                Text("Couldn't register")
                    .font(WoadieTheme.mono(size: 10, weight: .regular))
                    .foregroundStyle(WoadieTheme.warning)
            }
            WoadieButton(
                title: isRecording ? "Press keys…" : (shortcut?.displayString ?? "Off"),
                systemImage: isRecording ? "record.circle" : "keyboard",
                variant: isRecording ? .primary : .default
            ) {
                isRecording ? stopRecording() : startRecording()
            }
            WoadieButton(title: "Reset", variant: .default) {
                save(action.defaultShortcut)
            }
            WoadieButton(title: "Clear", variant: .default) {
                save(nil)
            }
        }
        .onAppear { shortcut = GlobalHotKeyService.shared.shortcut(for: action) }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                stopRecording() // a bare Escape cancels
                return nil
            }
            guard let recorded = HotKeyShortcut(event: event) else { return nil }
            save(recorded)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(_ new: HotKeyShortcut?) {
        conflict = !GlobalHotKeyService.shared.setShortcut(new, for: action)
        shortcut = GlobalHotKeyService.shared.shortcut(for: action)
    }
}

private struct PlaybackTuningControls: View {
    var model: AppModel

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
struct CloudVoicesSettings: View {
    var model: AppModel
    @Environment(\.openVoices) private var openVoices
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
    /// Keychain and disk lookups are slow enough to notice on every redraw,
    /// so their answers are cached here and refreshed when they can change.
    @State private var hasKey = false
    @State private var downloadedModelIDs: Set<String> = []

    private var provider: CloudProvider {
        CloudProvider.provider(withID: providerID) ?? .openRouter
    }

    private var canAdd: Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!provider.requiresAPIKey || hasKey)
            && (provider.defaultBaseURL != nil || !model.cloudSettings.customBaseURL.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $providerID) {
                ForEach(CloudProvider.selectable()) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let notice = provider.notice {
                caption("⚠︎ " + notice)
            }

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
                        refreshKeyState()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        IconActionButton(systemImage: "trash") {
                            model.setCloudAPIKey("", for: provider)
                            refreshKeyState()
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
        .onAppear {
            customBaseURL = model.cloudSettings.customBaseURL
            refreshKeyState()
            refreshDownloadedModels()
        }
        .onChange(of: providerID) { _, _ in refreshKeyState() }
        .onChange(of: model.localModelStates) { _, _ in refreshDownloadedModels() }
    }

    private func refreshKeyState() {
        hasKey = model.hasCloudAPIKey(for: provider)
    }

    private func refreshDownloadedModels() {
        downloadedModelIDs = Set(LocalVoiceCatalog.models.map(\.id).filter { MLXAudioServerManager.isModelDownloaded($0) })
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
                        modelStatus(localModel)
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
                    if localModel.supportsVoiceCloning {
                        WoadieButton(title: "Clone a Voice…", systemImage: "mic.circle", variant: .default) {
                            openVoices(.new)
                        }
                    }
                }
            }
            caption("Or enter any other mlx-audio model below.")
        }
    }

    @ViewBuilder
    private func modelStatus(_ localModel: LocalVoiceCatalog.Model) -> some View {
        switch model.localModelStates[localModel.id] {
        case .preparing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                badge(String(format: "Downloading %.1f GB…", localModel.downloadGB))
            }
        case .failed(let message):
            badge("Download failed")
                .help(message)
            Button("Retry") { model.prepareLocalModel(localModel.id) }
                .buttonStyle(.plain)
                .font(WoadieTheme.mono(size: 9, weight: .semibold))
        case nil:
            if downloadedModelIDs.contains(localModel.id) {
                badge("Downloaded")
            } else {
                badge(String(format: "%.1f GB download", localModel.downloadGB))
            }
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
        if voice.isCloned {
            return "cloned from your recording"
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
    var model: AppModel
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
            // Sort once per redraw; the total and the list both use it.
            let items = self.items
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

                    Text(ByteCountFormatter.string(fromByteCount: ClipInventory.totalBytes(of: items), countStyle: .file))
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
