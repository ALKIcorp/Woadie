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
        case pronunciation = "Text & Pronunciation"
        case voices = "Voices & Services"
        case engines = "Downloads & Engines"
        case usage = "Usage & Fallback"
        case storage = "Storage"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .playback: return "slider.horizontal.3"
            case .pronunciation: return "character.bubble"
            case .voices: return "person.wave.2"
            case .engines: return "arrow.down.circle"
            case .usage: return "chart.bar"
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
                .fixedSize()
            }
            SettingsSection("Keyboard Shortcuts", subtitle: "Speak selected text from any app") {
                HotKeySettings()
            }
        case .playback:
            SettingsSection("Speed and Pitch", subtitle: "Changes what you hear; saved clips are never re-rendered") {
                PlaybackTuningControls(model: model)
            }
            SettingsSection("Read Along", subtitle: "Highlight the text as it's spoken. Click a word to jump there") {
                Picker("Read along", selection: Binding(
                    get: { model.store.readAlongMode },
                    set: { model.setReadAlongMode($0) }
                )) {
                    ForEach(ReadAlongMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .pronunciation:
            SettingsSection("Clean Up Text Before Speaking", subtitle: "Fixes what voices stumble on. Your text in the editor isn't changed") {
                TextCleanupSettings(model: model)
            }
            SettingsSection("Try It", subtitle: "Type or paste anything to see what will be spoken") {
                SpokenTextPreview(model: model)
            }
            SettingsSection("Pronunciations", subtitle: "Teach voices how to say names and words. Applies to every voice") {
                PronunciationSettings(model: model)
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
        case .usage:
            UsageAndFallbackSettings(model: model)
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
            AudioCacheSettings()
        }
    }
}

/// Size of the replay cache, and a way to empty it.
/// Fallback voices, and characters and spend per provider this month.
private struct UsageAndFallbackSettings: View {
    var model: AppModel
    @State private var settings = UsageSettings.load()
    private let month = UsageMeter.monthKey(for: Date())

    var body: some View {
        SettingsSection(
            "When a Voice Fails",
            subtitle: "If a voice can't be reached, runs out of quota, rejects its key or hits a cap, speech continues with your backup voice, then native Kokoro (if it's on), then an Edge voice."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Fall back to another voice", isOn: binding(\.fallbackEnabled))
                    .font(WoadieTheme.rounded(size: 12, weight: .regular))
                Picker("Backup voice", selection: binding(\.backupVoiceID)) {
                    Text("None").tag(String?.none)
                    ForEach(model.voiceOptions.filter { !$0.isLocal }) { voice in
                        Text(voice.label).tag(Optional(voice.id))
                    }
                }
                .font(WoadieTheme.rounded(size: 12, weight: .regular))
                .disabled(!settings.fallbackEnabled)
                .frame(maxWidth: 420)
            }
        }

        SettingsSection(
            "Usage This Month",
            subtitle: "Characters generated per provider. Cached replays are free and aren't counted. Enter what you pay per million characters to see spend; a cap makes that provider fall back once reached."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Provider").frame(width: 150, alignment: .leading)
                    Text("Characters").frame(width: 90, alignment: .trailing)
                    Text("$ / 1M chars").frame(width: 100, alignment: .trailing)
                    Text("Monthly cap").frame(width: 110, alignment: .trailing)
                    Text("Spend").frame(width: 70, alignment: .trailing)
                }
                .font(WoadieTheme.mono(size: 10, weight: .semibold))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                ForEach(providers, id: \.self) { provider in
                    row(for: provider)
                }
                Text("Total this month: " + settings.totalSpend(forMonth: month).formatted(.currency(code: "USD")))
                    .font(WoadieTheme.mono(size: 11, weight: .semibold))
                    .padding(.top, 4)
            }
        }
        .onAppear { settings = UsageSettings.load() }
    }

    /// Paid providers the user has set up, plus any provider used this month.
    private var providers: [String] {
        let configured = model.cloudSettings.voices.map(\.providerID)
        let used = Array((settings.characters[month] ?? [:]).keys)
        var seen = Set<String>()
        return (configured + used + ["edge", "kokoro", "kokoro-native"]).filter { seen.insert($0).inserted }
    }

    private func name(for provider: String) -> String {
        switch provider {
        case "edge": return "Edge"
        case "kokoro": return "Kokoro"
        case "kokoro-native": return "Kokoro (Native)"
        case "apple": return "Apple"
        default: return CloudProvider.all.first { $0.id == provider }?.name ?? provider
        }
    }

    @ViewBuilder
    private func row(for provider: String) -> some View {
        let isFree = UsageMeter.freeProviders.contains(provider)
        HStack {
            Text(name(for: provider)).frame(width: 150, alignment: .leading)
            Text(settings.characters(forMonth: month, provider: provider).formatted())
                .frame(width: 90, alignment: .trailing)
            if isFree {
                Text("free").foregroundStyle(WoadieTheme.foregroundSubtle).frame(width: 100, alignment: .trailing)
            } else {
                TextField("–", value: priceBinding(provider), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            TextField("none", value: capBinding(provider), format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
            Text(settings.spend(forMonth: month, provider: provider).map { $0.formatted(.currency(code: "USD")) } ?? "–")
                .frame(width: 70, alignment: .trailing)
        }
        .font(WoadieTheme.mono(size: 11, weight: .medium))
        .textFieldStyle(.roundedBorder)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UsageSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                save { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func priceBinding(_ provider: String) -> Binding<Double?> {
        Binding(
            get: { settings.pricePerMillion[provider] },
            set: { value in
                settings.pricePerMillion[provider] = value
                save { $0.pricePerMillion[provider] = value }
            }
        )
    }

    private func capBinding(_ provider: String) -> Binding<Int?> {
        Binding(
            get: { settings.monthlyCap[provider] },
            set: { value in
                let cap = value.flatMap { $0 > 0 ? $0 : nil }
                settings.monthlyCap[provider] = cap
                save { $0.monthlyCap[provider] = cap }
            }
        )
    }

    /// Writes through the meter, so a save never races its usage counting.
    private func save(_ change: @escaping @Sendable (inout UsageSettings) -> Void) {
        Task { await UsageMeter.shared.update(change) }
    }
}

private struct AudioCacheSettings: View {
    @State private var bytes: Int64?
    @State private var isClearing = false

    var body: some View {
        SettingsSection(
            "Audio Cache",
            subtitle: "Speech you've already generated plays back instantly, with no network or engine work. Kept up to 1 GB; the oldest clips go first."
        ) {
            HStack {
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    .font(WoadieTheme.mono(size: 11, weight: .medium))
                Spacer()
                WoadieButton(title: isClearing ? "Clearing…" : "Clear Cache", systemImage: "trash", variant: .default) {
                    guard !isClearing else { return }
                    isClearing = true
                    Task {
                        await AudioClipCache.shared.removeAll()
                        bytes = await AudioClipCache.shared.totalBytes()
                        isClearing = false
                    }
                }
                .disabled(bytes == 0)
            }
        }
        .task { bytes = await AudioClipCache.shared.totalBytes() }
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

/// The cleanup rule switches.
private struct TextCleanupSettings: View {
    var model: AppModel

    var body: some View {
        let options = model.store.textCleanup
        VStack(alignment: .leading, spacing: 6) {
            toggle("Clean up text", \.isEnabled)
            Group {
                toggle("Remove formatting: headings, bold, bullets, links, code blocks, HTML", \.formatting)
                toggle("Read web and email addresses as \"link to github dot com\"", \.links)
                toggle("Skip citation marks like [12]", \.citations)
                toggle("Read versions like v1.2.3 as \"version 1 point 2 point 3\"", \.versions)
                toggle("Join lines a PDF broke mid-sentence", \.lineWraps)
            }
            .padding(.leading, 18)
            .disabled(!options.isEnabled)
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<TextCleanupOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.store.textCleanup[keyPath: keyPath] },
            set: { value in
                var options = model.store.textCleanup
                options[keyPath: keyPath] = value
                model.setTextCleanup(options)
            }
        ))
        .font(WoadieTheme.rounded(size: 12, weight: .regular))
    }
}

/// Shows the cleaned-up, pronunciation-applied text for whatever is typed.
private struct SpokenTextPreview: View {
    var model: AppModel
    @State private var sample = "## Release notes\nSee **v2.1.0** at https://www.github.com/alki/woadie [3]. Questions? hello@alki.example"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: $sample, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                Text(model.spokenText(for: sample))
                    .font(WoadieTheme.rounded(size: 12, weight: .regular))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconActionButton(systemImage: "play.circle") { model.previewText(sample) }
                    .help("Hear it in the selected voice")
            }
            .padding(10)
            .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The pronunciation list: word, how to say it, a sample button.
private struct PronunciationSettings: View {
    var model: AppModel
    @State private var newWord = ""
    @State private var newSayAs = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.store.pronunciations) { entry in
                HStack(spacing: 8) {
                    TextField("Word", text: binding(entry.id, \.word))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Image(systemName: "arrow.right").foregroundStyle(WoadieTheme.foregroundSubtle)
                    TextField("Say as", text: binding(entry.id, \.sayAs))
                        .textFieldStyle(.roundedBorder)
                    IconActionButton(systemImage: "play.circle") { model.previewText(entry.word) }
                        .help("Hear it in the selected voice")
                    IconActionButton(systemImage: "trash") {
                        model.setPronunciations(model.store.pronunciations.filter { $0.id != entry.id })
                    }
                    .help("Remove")
                }
            }
            HStack(spacing: 8) {
                TextField("Word, e.g. ALKI", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Image(systemName: "arrow.right").foregroundStyle(WoadieTheme.foregroundSubtle)
                TextField("Say as, e.g. Al-kee", text: $newSayAs)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                WoadieButton(title: "Add", systemImage: "plus", variant: .primary, action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || newSayAs.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("For Kokoro voices you can also write sounds between slashes, e.g. /ˈælki/.")
                .font(WoadieTheme.mono(size: 10, weight: .medium))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
            HStack {
                WoadieButton(title: "Import…", systemImage: "square.and.arrow.down", variant: .ghost, action: importList)
                WoadieButton(title: "Export…", systemImage: "square.and.arrow.up", variant: .ghost, action: exportList)
                    .disabled(model.store.pronunciations.isEmpty)
                if let message {
                    Text(message)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
            }
        }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<PronunciationEntry, String>) -> Binding<String> {
        Binding(
            get: { model.store.pronunciations.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                var entries = model.store.pronunciations
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index][keyPath: keyPath] = value
                model.setPronunciations(entries)
            }
        )
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        let sayAs = newSayAs.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !sayAs.isEmpty else { return }
        model.setPronunciations(model.store.pronunciations + [PronunciationEntry(word: word, sayAs: sayAs)])
        newWord = ""
        newSayAs = ""
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try PronunciationEntry.importJSON(Data(contentsOf: url))
            // Imported words replace existing entries for the same word.
            let words = Set(imported.map { $0.word.lowercased() })
            model.setPronunciations(model.store.pronunciations.filter { !words.contains($0.word.lowercased()) } + imported)
            message = "Imported \(imported.count)"
        } catch {
            message = "That file isn't a pronunciation list."
        }
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AlkiSpeak Pronunciations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PronunciationEntry.exportJSON(model.store.pronunciations).write(to: url)
            message = "Exported \(model.store.pronunciations.count)"
        } catch {
            message = error.localizedDescription
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
