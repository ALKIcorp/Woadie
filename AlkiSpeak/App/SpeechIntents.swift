import AppIntents
import Foundation

// Shortcuts and Siri actions. They run in the app without bringing its
// window forward, through the same target as links and the local API.

enum IntentTarget {
    /// The app model, waiting briefly when Shortcuts has just launched the app.
    @MainActor
    static func current() async throws -> SpeechAutomationTarget {
        for _ in 0..<50 {
            if let target = LocalAPIController.shared.target { return target }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentError.notReady
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case unknownVoice(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "AlkiSpeak isn't ready yet. Try again in a moment."
        case .unknownVoice(let name): return "There's no voice called \(name)."
        }
    }
}

struct VoiceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Voice"
    static let defaultQuery = VoiceQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    init(_ option: VoiceOption) {
        id = option.id
        name = option.name
        detail = option.detail
    }
}

struct VoiceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceEntity] {
        try await voices().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [VoiceEntity] {
        try await voices().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.detail.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [VoiceEntity] {
        try await voices()
    }

    private func voices() async throws -> [VoiceEntity] {
        try await MainActor.run {
            guard let target = LocalAPIController.shared.target else { throw IntentError.notReady }
            return target.automationVoices.map(VoiceEntity.init)
        }
    }
}

struct SpeakTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Text"
    static let description = IntentDescription("Reads text aloud with AlkiSpeak.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Voice", description: "Leave empty to use the selected voice.")
    var voice: VoiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Speak \(\.$text)") {
            \.$voice
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let target = try await IntentTarget.current()
        target.speakExternalText(text, voice: voice?.id)
        return .result()
    }
}

struct StopSpeakingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Speaking"
    static let description = IntentDescription("Stops whatever AlkiSpeak is reading.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentTarget.current().stopPlayback()
        return .result()
    }
}

struct SaveSpeechAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Spoken Audio"
    static let description = IntentDescription("Turns text into a WAV file without playing it. Apple voices can't be saved.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Voice", description: "Leave empty to use the selected voice.")
    var voice: VoiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Make audio of \(\.$text)") {
            \.$voice
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let target = try await IntentTarget.current()
        let voiceID = voice?.id ?? target.selectedVoice
        let audio = try await target.renderAutomationAudio(text: text, voice: voiceID)
        return .result(value: IntentFile(data: audio, filename: "AlkiSpeak.wav", type: .wav))
    }
}

struct SetVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Voice"
    static let description = IntentDescription("Changes AlkiSpeak's selected voice.")
    static let openAppWhenRun = false

    @Parameter(title: "Voice")
    var voice: VoiceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set the voice to \(\.$voice)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let target = try await IntentTarget.current()
        guard target.resolveAutomationVoice(voice.id) == voice.id else { throw IntentError.unknownVoice(voice.name) }
        (target as? AppModel)?.selectedVoice = voice.id
        return .result()
    }
}

struct AlkiSpeakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SpeakTextIntent(),
            phrases: ["Speak with \(.applicationName)", "Read aloud with \(.applicationName)"],
            shortTitle: "Speak Text",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: StopSpeakingIntent(),
            phrases: ["Stop \(.applicationName)", "Stop speaking in \(.applicationName)"],
            shortTitle: "Stop Speaking",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SaveSpeechAudioIntent(),
            phrases: ["Make audio with \(.applicationName)"],
            shortTitle: "Make Spoken Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SetVoiceIntent(),
            phrases: ["Change the \(.applicationName) voice to \(\.$voice)"],
            shortTitle: "Set Voice",
            systemImageName: "person.wave.2"
        )
    }
}
