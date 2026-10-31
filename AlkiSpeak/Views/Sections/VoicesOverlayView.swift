import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The tabs of the Voices screen.
enum VoicesTab: String, CaseIterable, Identifiable {
    case mine = "My Voices"
    case browse = "Browse"
    case new = "New Voice"

    var id: Self { self }
}

/// Opens the Voices screen from anywhere below `ContentView`, e.g. the
/// "Clone a voice" button inside Settings.
struct OpenVoicesAction {
    let open: (VoicesTab) -> Void
    func callAsFunction(_ tab: VoicesTab) { open(tab) }
}

private struct OpenVoicesKey: EnvironmentKey {
    static let defaultValue = OpenVoicesAction { _ in }
}

extension EnvironmentValues {
    var openVoices: OpenVoicesAction {
        get { self[OpenVoicesKey.self] }
        set { self[OpenVoicesKey.self] = newValue }
    }
}

/// One place for voices: the ones you use, every voice there is, and making
/// a new one (cloning, describing, or connecting an online service).
struct VoicesOverlayView: View {
    var model: AppModel
    @State var tab: VoicesTab
    var onClose: () -> Void

    var body: some View {
        OverlayContainer(title: "Voices", maxWidth: 720, maxHeight: 640, onClose: onClose) {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(VoicesTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.vertical, 14)

                switch tab {
                case .mine:
                    MyVoicesList(model: model, onBrowse: { tab = .browse }, onNew: { tab = .new })
                case .browse:
                    BrowseVoicesList(model: model)
                case .new:
                    NewVoicePane(model: model, onFinished: onClose)
                }
            }
        }
    }
}

// MARK: - Rows

/// A voice with its tag, a sample button, a favorite star and "Use".
private struct VoiceRow: View {
    var model: AppModel
    let voice: VoiceOption
    var onRemove: (() -> Void)? = nil

    private var isSelected: Bool { model.selectedVoice == voice.id }
    private var isFavorite: Bool { model.voiceFavorites.contains(voice.id) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(voice.detail)
                    .font(WoadieTheme.mono(size: 9, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconActionButton(systemImage: "play.circle") { model.previewVoice(voice.id) }
                .help("Hear a short sample")
                .disabled(!voice.isAvailable)
            Button { model.toggleFavorite(voice.id) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorite ? WoadieTheme.warning : WoadieTheme.foregroundSubtle)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            if let onRemove {
                IconActionButton(systemImage: "trash", action: onRemove)
                    .help("Remove this voice")
            }
            if isSelected {
                Text("In use")
                    .font(WoadieTheme.mono(size: 9, weight: .semibold))
                    .foregroundStyle(WoadieTheme.success)
                    .frame(width: 64)
            } else {
                WoadieButton(title: "Use", variant: .default) { model.selectedVoice = voice.id }
                    .frame(width: 64)
                    .disabled(!voice.isAvailable)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isSelected ? WoadieTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(WoadieTheme.mono(size: 9, weight: .semibold))
                .tracking(1.4)
            Spacer()
            if let trailing {
                Text(trailing).font(WoadieTheme.mono(size: 9, weight: .regular))
            }
        }
        .foregroundStyle(WoadieTheme.foregroundSubtle)
        .padding(.top, 10)
        .padding(.horizontal, 10)
    }
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(WoadieTheme.mono(size: 10, weight: .medium))
        .foregroundStyle(WoadieTheme.foregroundSubtle)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - My Voices

private struct MyVoicesList: View {
    var model: AppModel
    var onBrowse: () -> Void
    var onNew: () -> Void

    private var byID: [String: VoiceOption] {
        Dictionary(model.voiceOptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let byID = byID
        let added = model.cloudSettings.voices.compactMap { cloud in byID[cloud.voiceID].map { (cloud, $0) } }
        let favorites = model.voiceOptions.filter { model.voiceFavorites.contains($0.id) }
        let recent = model.store.recentVoiceIDs.compactMap { byID[$0] }.prefix(VoiceGrouping.recentLimit)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if added.isEmpty && favorites.isEmpty && recent.isEmpty {
                    VStack(spacing: 12) {
                        note("Voices you add, clone or star show up here.")
                        HStack {
                            WoadieButton(title: "Browse Voices", systemImage: "magnifyingglass", variant: .default, action: onBrowse)
                            WoadieButton(title: "New Voice", systemImage: "plus", variant: .primary, action: onNew)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                if !added.isEmpty {
                    SectionHeader(title: "Added by you", trailing: "\(added.count)")
                    ForEach(added, id: \.0.id) { cloud, voice in
                        VoiceRow(model: model, voice: voice, onRemove: { model.removeCloudVoice(cloud) })
                    }
                }
                if !favorites.isEmpty {
                    SectionHeader(title: "Favorites", trailing: "\(favorites.count)")
                    ForEach(favorites) { VoiceRow(model: model, voice: $0) }
                }
                if !recent.isEmpty {
                    SectionHeader(title: "Recent")
                    ForEach(Array(recent)) { VoiceRow(model: model, voice: $0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Browse

private struct BrowseVoicesList: View {
    enum Place: String, CaseIterable, Identifiable {
        case all = "All"
        case onDevice = "On this Mac"
        case online = "Online"
        var id: Self { self }
    }

    var model: AppModel
    @State private var query = ""
    @State private var place: Place = .all

    var body: some View {
        let filtered = VoiceGrouping.search(model.voiceOptions, query: query).filter { voice in
            switch place {
            case .all: return true
            case .onDevice: return voice.isOnDevice
            case .online: return !voice.isOnDevice
            }
        }
        let sections = VoiceGrouping.sections(voices: filtered, favorites: [])
        VStack(spacing: 10) {
            HStack {
                TextField("Search by name, language or accent", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Where", selection: $place) {
                    ForEach(Place.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if place != .online && query.isEmpty {
                        MoreLocalVoices(model: model)
                    }
                    if sections.isEmpty {
                        note("No voices match.")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(sections) { section in
                        SectionHeader(title: section.title, trailing: "\(section.voices.count)")
                        ForEach(section.voices) { VoiceRow(model: model, voice: $0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

/// Free voices that run on this Mac but aren't added yet. Each model
/// downloads once, the first time one of its voices is used.
private struct MoreLocalVoices: View {
    var model: AppModel

    var body: some View {
        let missing = LocalVoiceCatalog.models.compactMap { localModel -> (LocalVoiceCatalog.Model, [LocalVoiceCatalog.Voice])? in
            let voices = localModel.voices.filter { !model.hasCloudVoice(provider: .localMLX, model: localModel.id, voice: $0.name) }
            return voices.isEmpty ? nil : (localModel, voices)
        }
        if !missing.isEmpty {
            SectionHeader(title: "Get more voices for this Mac")
            ForEach(missing, id: \.0.id) { localModel, voices in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(localModel.name)
                            .font(WoadieTheme.rounded(size: 12, weight: .semibold))
                        Text(String(format: "Free · %.1f GB download", localModel.downloadGB))
                            .font(WoadieTheme.mono(size: 9, weight: .medium))
                            .foregroundStyle(WoadieTheme.foregroundSubtle)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(voices) { voice in
                            WoadieButton(
                                title: voice.name.split(separator: "_").last.map(String.init) ?? voice.name,
                                systemImage: "plus",
                                variant: .default
                            ) {
                                model.addLocalPreset(model: localModel, voice: voice)
                            }
                            .help("Add \(voice.label)")
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: - New Voice

private struct NewVoicePane: View {
    enum Kind { case clone, describe, connect }

    var model: AppModel
    var onFinished: () -> Void
    @State private var kind: Kind?

    var body: some View {
        switch kind {
        case nil:
            VStack(spacing: 12) {
                card(
                    "Clone my voice",
                    systemImage: "mic.circle",
                    text: "Read one sentence out loud. Your recording stays on this Mac."
                ) { kind = .clone }
                card(
                    "Describe a voice",
                    systemImage: "wand.and.stars",
                    text: "Type what it should sound like, e.g. \"a warm, gentle storyteller\"."
                ) { kind = .describe }
                card(
                    "Connect a service",
                    systemImage: "link",
                    text: "Use voices from ElevenLabs, OpenAI, Gemini and others with your own API key."
                ) { kind = .connect }
            }
            .padding(16)
            Spacer(minLength: 0)
        case .clone?:
            back { CloneVoiceFlow(model: model, onFinished: onFinished) }
        case .describe?:
            back { DescribeVoiceForm(model: model, onFinished: onFinished) }
        case .connect?:
            back {
                ScrollView {
                    CloudVoicesSettings(model: model)
                        .padding(16)
                }
            }
        }
    }

    private func card(_ title: String, systemImage: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(WoadieTheme.rounded(size: 15, weight: .semibold))
                    Text(text)
                        .font(WoadieTheme.rounded(size: 12, weight: .regular))
                        .foregroundStyle(WoadieTheme.foregroundMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(WoadieTheme.foregroundSubtle)
            }
            .padding(16)
            .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WoadieTheme.borderSubtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func back<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { kind = nil } label: {
                Label("All options", systemImage: "chevron.left")
                    .font(WoadieTheme.rounded(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            content()
        }
    }
}

/// Record → listen → name. The new voice is selected when it's created.
private struct CloneVoiceFlow: View {
    enum Step { case record, listen, name, done }

    var model: AppModel
    var onFinished: () -> Void
    @StateObject private var recorder = VoiceCloneRecorder()
    @State private var step: Step = .record
    @State private var clipURL: URL?
    @State private var transcript = CloneVoiceFlow.script
    @State private var name = "My voice"
    @State private var errorMessage: String?
    @State private var player: NSSound?
    @State private var modelDownloaded = true

    static let script = "Hi, this is my voice. I'm recording a short sample so the app can learn how I sound, and then read anything I type back to me."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepIndicator
            switch step {
            case .record: recordStep
            case .listen: listenStep
            case .name: nameStep
            case .done: doneStep
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.warning)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear { modelDownloaded = MLXAudioServerManager.isModelDownloaded(LocalVoiceCatalog.cloningModelID) }
        .onDisappear {
            _ = recorder.stop()
            player?.stop()
        }
    }

    private var stepIndicator: some View {
        let steps: [(Step, String)] = [(.record, "Record"), (.listen, "Listen"), (.name, "Name")]
        let current = steps.firstIndex { $0.0 == step } ?? steps.count
        return HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "\(index + 1).circle.fill" : "\(index + 1).circle")
                    Text(item.1)
                }
                .font(WoadieTheme.rounded(size: 12, weight: index == current ? .semibold : .regular))
                .foregroundStyle(index <= current ? WoadieTheme.foreground : WoadieTheme.foregroundSubtle)
                if index < steps.count - 1 {
                    Rectangle().fill(WoadieTheme.borderSubtle).frame(width: 24, height: 1)
                }
            }
        }
    }

    private var recordStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("Press Record and read this out loud in your normal voice, somewhere quiet. 10–20 seconds is plenty.")
            Text("“\(Self.script)”")
                .font(WoadieTheme.rounded(size: 15, weight: .regular))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 10) {
                WoadieButton(
                    title: recorder.isRecording ? String(format: "Stop · %.0fs", recorder.elapsed) : "Record",
                    systemImage: recorder.isRecording ? "stop.fill" : "mic.fill",
                    variant: .primary
                ) { toggleRecording() }
                WoadieButton(title: "Use a Recording Instead…", systemImage: "folder", variant: .ghost) { chooseFile() }
                    .disabled(recorder.isRecording)
            }
        }
    }

    private var listenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("Listen back. If it's noisy or cut off, record it again.")
            HStack(spacing: 10) {
                WoadieButton(title: "Play Recording", systemImage: "play.fill", variant: .default) {
                    guard let clipURL else { return }
                    player?.stop()
                    player = NSSound(contentsOf: clipURL, byReference: true)
                    player?.play()
                }
                WoadieButton(title: "Record Again", systemImage: "arrow.counterclockwise", variant: .ghost) {
                    player?.stop()
                    discardRecording()
                    step = .record
                }
            }
            note("The words spoken in the recording:")
            TextField("Exact words spoken", text: $transcript, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            WoadieButton(title: "Next", systemImage: "arrow.right", variant: .primary) {
                player?.stop()
                step = .name
            }
            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("What should this voice be called?")
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if !modelDownloaded {
                note("The first clone downloads the free cloning model once (about 2.5 GB). It runs on this Mac.")
            }
            WoadieButton(title: "Create Voice", systemImage: "person.wave.2", variant: .primary) { create() }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            note("Only clone voices you have permission to use.")
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(name) is ready and selected.", systemImage: "checkmark.seal.fill")
                .font(WoadieTheme.rounded(size: 15, weight: .semibold))
                .foregroundStyle(WoadieTheme.success)
            note("Type anything in the main window and press Generate. The first time may take a moment while the voice loads.")
            HStack {
                WoadieButton(title: "Hear It", systemImage: "play.circle", variant: .default) {
                    model.previewVoice(model.selectedVoice)
                }
                WoadieButton(title: "Done", variant: .primary, action: onFinished)
            }
        }
    }

    private func toggleRecording() {
        errorMessage = nil
        if recorder.isRecording {
            clipURL = recorder.stop()
            transcript = Self.script
            if clipURL != nil { step = .listen }
            return
        }
        discardRecording()
        Task {
            do {
                try await recorder.start()
            } catch {
                errorMessage = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
            }
        }
    }

    private func chooseFile() {
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a Voice Recording"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        discardRecording()
        clipURL = url
        // A chosen file says something else, so the transcript is the user's to type.
        transcript = ""
        step = .listen
    }

    private func create() {
        guard let clipURL else { return }
        errorMessage = nil
        do {
            try model.addClonedLocalVoice(recording: clipURL, transcript: transcript, label: name)
            discardRecording()
            step = .done
        } catch {
            errorMessage = (error as? AlkiSpeakError)?.message ?? error.localizedDescription
        }
    }

    /// Deletes a temporary recording; a file the user chose is left alone.
    private func discardRecording() {
        if let clipURL, clipURL.lastPathComponent.hasPrefix("woadie-clone-") {
            try? FileManager.default.removeItem(at: clipURL)
        }
        clipURL = nil
    }
}

/// A voice made from a description, using the Ming model's voice design.
private struct DescribeVoiceForm: View {
    var model: AppModel
    var onFinished: () -> Void
    @State private var description = ""
    @State private var name = ""
    @State private var created = false

    private var designModel: LocalVoiceCatalog.Model? {
        LocalVoiceCatalog.models.first { $0.supportsVoiceDesign }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if created {
                Label("\(name.isEmpty ? "Your voice" : name) is ready and selected.", systemImage: "checkmark.seal.fill")
                    .font(WoadieTheme.rounded(size: 15, weight: .semibold))
                    .foregroundStyle(WoadieTheme.success)
                HStack {
                    WoadieButton(title: "Hear It", systemImage: "play.circle", variant: .default) {
                        model.previewVoice(model.selectedVoice)
                    }
                    WoadieButton(title: "Done", variant: .primary, action: onFinished)
                }
            } else if let designModel {
                note("Describe how it should sound: age, tone, pace, accent.")
                TextField("e.g. A calm older man with a slight British accent, speaking slowly", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                note(String(format: "Runs on this Mac with %@ (free, %.1f GB download the first time).", designModel.name, designModel.downloadGB))
                WoadieButton(title: "Create Voice", systemImage: "wand.and.stars", variant: .primary) {
                    model.addDesignedLocalVoice(model: designModel, description: description, label: name)
                    created = true
                }
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
