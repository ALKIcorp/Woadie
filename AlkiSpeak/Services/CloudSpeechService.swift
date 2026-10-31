import Foundation
import Security
import os.log

/// The request shape a provider speaks.
enum CloudAPIStyle: Hashable {
    /// `POST {base}/audio/speech` with JSON `model`, `input`, `voice`,
    /// `response_format`; Bearer auth. OpenRouter, OpenAI, Mistral and the
    /// `mlx-audio` server all accept it.
    case openAICompatible
    /// `POST {base}/text-to-speech/{voice_id}?output_format=…` with JSON
    /// `text`, `model_id`; `xi-api-key` auth.
    case elevenLabs
    /// Gemini Interactions API: `POST {base}/interactions`, `x-goog-api-key`
    /// auth. Audio comes back base64-encoded inside JSON (a WAV file by default).
    case gemini
}

/// A hosted (or local) speech endpoint.
struct CloudProvider: Identifiable, Hashable {
    let id: String
    let name: String
    /// `nil` for the custom provider, whose base URL the user enters.
    let defaultBaseURL: String?
    let requiresAPIKey: Bool
    let modelPrompt: String
    let voicePrompt: String
    var style: CloudAPIStyle = .openAICompatible

    static let elevenLabs = CloudProvider(
        id: "elevenlabs",
        name: "ElevenLabs",
        defaultBaseURL: "https://api.elevenlabs.io/v1",
        requiresAPIKey: true,
        modelPrompt: "e.g. eleven_v4",
        voicePrompt: "Voice ID",
        style: .elevenLabs
    )
    static let gemini = CloudProvider(
        id: "gemini",
        name: "Google Gemini",
        defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
        requiresAPIKey: true,
        modelPrompt: "e.g. gemini-3.8-flash-tts",
        voicePrompt: "e.g. Kore",
        style: .gemini
    )
    static let openRouter = CloudProvider(
        id: "openrouter",
        name: "OpenRouter",
        defaultBaseURL: "https://openrouter.ai/api/v1",
        requiresAPIKey: true,
        modelPrompt: "e.g. mistralai/voxtral-mini-tts-2603",
        voicePrompt: "e.g. en_paul_neutral"
    )
    static let openAI = CloudProvider(
        id: "openai",
        name: "OpenAI",
        defaultBaseURL: "https://api.openai.com/v1",
        requiresAPIKey: true,
        modelPrompt: "e.g. gpt-4o-mini-tts",
        voicePrompt: "e.g. marin"
    )
    static let mistral = CloudProvider(
        id: "mistral",
        name: "Mistral",
        defaultBaseURL: "https://api.mistral.ai/v1",
        requiresAPIKey: true,
        modelPrompt: "e.g. voxtral-mini-tts-latest",
        voicePrompt: "Voice preset ID"
    )
    static let localMLX = CloudProvider(
        id: "mlx-audio",
        name: "Local mlx-audio",
        defaultBaseURL: "http://localhost:8000/v1",
        requiresAPIKey: false,
        modelPrompt: "Model ID served by mlx_audio.server",
        voicePrompt: "Voice name (model-specific)"
    )
    static let custom = CloudProvider(
        id: "custom",
        name: "Custom",
        defaultBaseURL: nil,
        requiresAPIKey: false,
        modelPrompt: "Model ID",
        voicePrompt: "Voice ID"
    )

    static let all: [CloudProvider] = [.elevenLabs, .gemini, .openRouter, .openAI, .mistral, .localMLX, .custom]

    static func provider(withID id: String) -> CloudProvider? {
        all.first { $0.id == id }
    }

    /// The custom provider takes an optional key, so it always offers the field.
    var acceptsAPIKey: Bool { requiresAPIKey || self == .custom }
}

/// One user-configured voice: a provider plus the model and voice to request.
struct CloudVoice: Identifiable, Codable, Hashable {
    let id: UUID
    let providerID: String
    let model: String
    let voice: String
    let label: String
    /// A designed voice's description (local mlx-audio only). When set, it is
    /// sent as `instruct` in place of `voice`. Absent in older saved settings.
    let instructions: String?

    init(id: UUID = UUID(), providerID: String, model: String, voice: String, label: String, instructions: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.model = model
        self.voice = voice
        self.label = label
        self.instructions = instructions
    }

    var isDesigned: Bool { !(instructions ?? "").isEmpty }

    var voiceID: String { CloudSpeechGenerationService.idPrefix + id.uuidString }
    var provider: CloudProvider? { CloudProvider.provider(withID: providerID) }
}

struct CloudSpeechSettings: Codable, Hashable {
    var voices: [CloudVoice] = []
    var customBaseURL: String = ""

    func voice(withID voiceID: String) -> CloudVoice? {
        voices.first { $0.voiceID == voiceID }
    }

    func baseURL(for provider: CloudProvider) -> String? {
        if let fixed = provider.defaultBaseURL { return fixed }
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol CloudSpeechSettingsStoring: AnyObject {
    func load() -> CloudSpeechSettings
    func save(_ settings: CloudSpeechSettings)
}

final class UserDefaultsCloudSpeechSettingsStore: CloudSpeechSettingsStoring {
    private let key = "AlkiSpeak.cloudSpeech"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CloudSpeechSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CloudSpeechSettings.self, from: data)
        else { return CloudSpeechSettings() }
        return settings
    }

    func save(_ settings: CloudSpeechSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// API keys live in the Keychain, never in `UserDefaults` or the workspace JSON.
protocol SecretStoring: AnyObject {
    func secret(for account: String) -> String?
    /// Passing `nil` (or an empty string) deletes the stored secret.
    func setSecret(_ value: String?, for account: String) throws
}

final class KeychainSecretStore: SecretStoring {
    private let service: String

    init(service: String = "com.alki.Woadie.cloud-speech") {
        self.service = service
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, for account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AlkiSpeakError(
                code: "cloud.keychain",
                title: "Couldn't Save API Key",
                message: "The Keychain rejected the key (OSStatus \(status)).",
                recoverySuggestion: "Unlock the login keychain and try again."
            )
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Routes `cloud:<uuid>` voice IDs to whichever provider the user configured
/// for that voice. Like Edge, it never depends on the local Kokoro engine.
final class CloudSpeechGenerationService: SpeechGenerating {
    static let idPrefix = "cloud:"

    private let logger = Logger(subsystem: "com.alki.Woadie", category: "CloudTTS")
    private let settings: CloudSpeechSettingsStoring
    private let secrets: SecretStoring
    private let session: URLSession
    private let localServer: LocalVoiceServerEnsuring?

    init(
        settings: CloudSpeechSettingsStoring = UserDefaultsCloudSpeechSettingsStore(),
        secrets: SecretStoring = KeychainSecretStore(),
        session: URLSession = .shared,
        localServer: LocalVoiceServerEnsuring? = nil
    ) {
        self.settings = settings
        self.secrets = secrets
        self.session = session
        self.localServer = localServer
    }

    /// There is no shared endpoint to probe; "healthy" means a voice is set up.
    func checkHealth() async -> Bool {
        !settings.load().voices.isEmpty
    }

    func fetchVoices() async throws -> [String] {
        settings.load().voices.map(\.voiceID)
    }

    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        let startedAt = Date()
        let request = try makeRequest(text: text, voiceID: voice)
        let provider = settings.load().voice(withID: voice)?.provider
        do {
            if provider == .localMLX {
                try await localServer?.ensureRunning()
            }
            let (data, response) = try await session.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let http = response as? HTTPURLResponse else {
                throw Self.failure(code: "cloud.no-response", message: "The provider returned no HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.httpError(status: http.statusCode, body: data)
            }
            let audio = provider?.style == .gemini ? try Self.geminiAudio(from: data) : data
            guard !audio.isEmpty else {
                throw Self.failure(code: "cloud.empty-audio", message: "The provider returned an empty audio response.")
            }
            logger.info("Cloud synthesis complete job=\(jobID?.uuidString ?? "none", privacy: .public) chars=\(text.count) elapsedMs=\(elapsedMs)")
            return SpeechGenerationResult(audioData: audio, latencyMs: elapsedMs, charCount: text.count)
        } catch let error as AlkiSpeakError {
            throw error
        } catch is CancellationError {
            throw Self.cancelled()
        } catch let error as URLError where error.code == .cancelled {
            throw Self.cancelled()
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            throw AlkiSpeakError.generation(
                code: "cloud.request-failed",
                title: "Cloud Speech Request Failed",
                message: "The cloud voice request failed after \(elapsedMs) ms: \(error.localizedDescription)",
                recoverySuggestion: "Check the network connection and the provider's base URL, then retry.",
                underlyingError: error
            )
        }
    }

    static func isCloudVoice(_ voiceID: String) -> Bool {
        voiceID.hasPrefix(idPrefix)
    }

    // MARK: - Request building

    func makeRequest(text: String, voiceID: String) throws -> URLRequest {
        let current = settings.load()
        guard let cloudVoice = current.voice(withID: voiceID) else {
            throw Self.failure(
                code: "cloud.voice-missing",
                message: "This cloud voice is no longer configured.",
                suggestion: "Pick another voice, or add it again in Settings → Cloud Voices."
            )
        }
        guard let provider = cloudVoice.provider else {
            throw Self.failure(code: "cloud.provider-unknown", message: "Unknown cloud provider \"\(cloudVoice.providerID)\".")
        }
        let url: URL?
        switch provider.style {
        case .openAICompatible:
            url = current.baseURL(for: provider).flatMap { Self.speechURL(base: $0) }
        case .elevenLabs:
            url = current.baseURL(for: provider).flatMap { Self.elevenLabsSpeechURL(base: $0, voiceID: cloudVoice.voice) }
        case .gemini:
            url = current.baseURL(for: provider).flatMap { Self.normalizedBase($0) }.flatMap { URL(string: $0 + "/interactions") }
        }
        guard let url else {
            throw Self.failure(
                code: "cloud.base-url",
                message: "\(provider.name) has no valid base URL.",
                suggestion: "Enter the endpoint's base URL (ending in /v1) in Settings → Cloud Voices."
            )
        }
        let apiKey = secrets.secret(for: provider.id)
        if provider.requiresAPIKey, (apiKey ?? "").isEmpty {
            throw Self.failure(
                code: "cloud.api-key-missing",
                message: "No API key saved for \(provider.name).",
                suggestion: "Add your \(provider.name) key in Settings → Cloud Voices."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConfig.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MP3 is the one format every preset returns; the clip pipeline already
        // plays Edge's MP3 output, so no extra decoding path is needed.
        switch provider.style {
        case .openAICompatible:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = [
                "model": cloudVoice.model,
                "input": text,
                "response_format": "mp3"
            ]
            if provider == .localMLX, let instructions = cloudVoice.instructions, !instructions.isEmpty {
                // Ming rejects `voice` and `instruct` together (the server then
                // answers 200 with an empty body), so a designed voice sends
                // only its description.
                body["instruct"] = instructions
            } else {
                body["voice"] = cloudVoice.voice
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .elevenLabs:
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "model_id": cloudVoice.model
            ])
        case .gemini:
            // Unary responses default to a 24 kHz mono WAV with a RIFF header,
            // which the clip pipeline plays as-is.
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": cloudVoice.model,
                "input": [["type": "user_input", "content": [["type": "text", "text": text]]]],
                "response_format": ["type": "audio"],
                "generation_config": ["speech_config": [["voice": cloudVoice.voice]]]
            ] as [String: Any])
        }
        return request
    }

    /// Decodes the last audio block of the `model_output` step:
    /// `steps[type=model_output].content[type=audio].data` (base64).
    static func geminiAudio(from body: Data) throws -> Data {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let steps = json?["steps"] as? [[String: Any]] ?? []
        let audioBlocks = steps
            .filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "audio" }
        guard let encoded = audioBlocks.last?["data"] as? String,
              let audio = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        else {
            throw failure(
                code: "cloud.gemini.no-audio",
                message: "Gemini answered without any audio.",
                suggestion: "Check that the model is a TTS model (e.g. gemini-3.8-flash-tts) and the voice name is valid."
            )
        }
        return audio
    }

    static func speechURL(base: String) -> URL? {
        normalizedBase(base).flatMap { URL(string: $0 + "/audio/speech") }
    }

    /// `{base}/text-to-speech/{voice_id}?output_format=mp3_44100_128`
    static func elevenLabsSpeechURL(base: String, voiceID: String) -> URL? {
        guard let base = normalizedBase(base),
              let escaped = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              !escaped.isEmpty,
              var components = URLComponents(string: base + "/text-to-speech/" + escaped)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        return components.url
    }

    /// Trims whitespace and trailing slashes; `nil` unless it is an http(s) URL with a host.
    static func normalizedBase(_ base: String) -> String? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return trimmed
    }

    // MARK: - Errors

    static func httpError(status: Int, body: Data) -> AlkiSpeakError {
        let detail = providerMessage(from: body)
        let suggestion: String
        switch status {
        case 401, 403: suggestion = "Check that the saved API key is valid for this provider."
        case 402: suggestion = "The provider reports insufficient credits; top up the account."
        case 404: suggestion = "Check the base URL and model ID."
        case 429: suggestion = "The provider is rate limiting requests; wait and retry."
        default: suggestion = "Check the model and voice IDs, then retry."
        }
        return failure(
            code: "cloud.http.\(status)",
            message: "The provider returned HTTP \(status)" + (detail.map { ": \($0)" } ?? "."),
            suggestion: suggestion
        )
    }

    /// Pulls a readable message out of the common error shapes
    /// (`{"error":{"message":…}}`, `{"error":"…"}`, `{"detail":…}`, and
    /// ElevenLabs' `{"detail":{"message":…}}` / `{"detail":[{"msg":…}]}`).
    static func providerMessage(from body: Data) -> String? {
        let parsed = try? JSONSerialization.jsonObject(with: body)
        // Google's endpoints wrap the error object in a one-element array.
        if let json = (parsed as? [String: Any]) ?? (parsed as? [[String: Any]])?.first {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["error"] as? String { return message }
            if let message = json["detail"] as? String { return message }
            if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let details = json["detail"] as? [[String: Any]] {
                let messages = details.compactMap { $0["msg"] as? String }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
            if let message = json["message"] as? String { return message }
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func failure(code: String, message: String, suggestion: String = "Check Settings → Cloud Voices and retry.") -> AlkiSpeakError {
        AlkiSpeakError.generation(code: code, title: "Cloud Voice Error", message: message, recoverySuggestion: suggestion)
    }

    private static func cancelled() -> AlkiSpeakError {
        AlkiSpeakError.generation(
            code: "cancelled",
            title: "Speech Request Cancelled",
            message: "The cloud speech request was cancelled before completion.",
            recoverySuggestion: "Start a new generation request when ready."
        )
    }
}

// MARK: - ElevenLabs catalog

struct ElevenLabsVoiceInfo: Identifiable, Hashable, Decodable {
    let voiceID: String
    let name: String
    let category: String?

    var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case category
    }
}

struct ElevenLabsModelInfo: Identifiable, Hashable, Decodable {
    let modelID: String
    let name: String
    let canDoTextToSpeech: Bool

    var id: String { modelID }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case name
        case canDoTextToSpeech = "can_do_text_to_speech"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? modelID
        canDoTextToSpeech = try container.decodeIfPresent(Bool.self, forKey: .canDoTextToSpeech) ?? false
    }
}

struct ElevenLabsCatalog: Hashable {
    let voices: [ElevenLabsVoiceInfo]
    let models: [ElevenLabsModelInfo]

    /// The docs' quality recommendation, falling back to whatever the account offers.
    var preferredModelID: String? {
        let ids = models.map(\.modelID)
        return ["eleven_v4", "eleven_multilingual_v2"].first(where: ids.contains) ?? ids.first
    }
}

protocol ElevenLabsCatalogFetching: AnyObject {
    func fetchCatalog() async throws -> ElevenLabsCatalog
}

/// Lists the account's voices (`GET /v1/voices`) and TTS-capable models
/// (`GET /v1/models`) so Settings can offer pickers instead of raw IDs.
final class ElevenLabsCatalogService: ElevenLabsCatalogFetching {
    private let secrets: SecretStoring
    private let session: URLSession
    private let base: String

    init(secrets: SecretStoring, session: URLSession = .shared, base: String = CloudProvider.elevenLabs.defaultBaseURL ?? "") {
        self.secrets = secrets
        self.session = session
        self.base = base
    }

    private struct VoicesResponse: Decodable {
        let voices: [ElevenLabsVoiceInfo]
    }

    func fetchCatalog() async throws -> ElevenLabsCatalog {
        guard let key = secrets.secret(for: CloudProvider.elevenLabs.id), !key.isEmpty else {
            throw AlkiSpeakError.generation(
                code: "cloud.api-key-missing",
                title: "Cloud Voice Error",
                message: "No API key saved for ElevenLabs.",
                recoverySuggestion: "Add your ElevenLabs key in Settings → Cloud Voices."
            )
        }
        async let voicesData = get("voices", key: key)
        async let modelsData = get("models", key: key)
        let voices = try JSONDecoder().decode(VoicesResponse.self, from: await voicesData).voices
        let models = try JSONDecoder().decode([ElevenLabsModelInfo].self, from: await modelsData)
            .filter(\.canDoTextToSpeech)
        return ElevenLabsCatalog(
            voices: voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            models: models
        )
    }

    private func get(_ path: String, key: String) async throws -> Data {
        guard let normalized = CloudSpeechGenerationService.normalizedBase(base),
              let url = URL(string: normalized + "/" + path)
        else {
            throw AlkiSpeakError.generation(code: "cloud.base-url", title: "Cloud Voice Error", message: "ElevenLabs has no valid base URL.", recoverySuggestion: "Retry.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudSpeechGenerationService.httpError(status: status, body: data)
        }
        return data
    }
}

// MARK: - Gemini catalog

/// Gemini's TTS models and its 30 prebuilt voices, as listed in the speech
/// generation guide. Fixed, so Settings can offer pickers without a request.
enum GeminiSpeechCatalog {
    struct Voice: Identifiable, Hashable {
        let name: String
        let trait: String
        var id: String { name }
    }

    static let models: [(id: String, name: String)] = [
        ("gemini-3.8-flash-tts", "Gemini 3.8 Flash TTS"),
        ("gemini-3.8-flash-lite-tts", "Gemini 3.8 Flash-Lite TTS")
    ]

    static let voices: [Voice] = [
        ("Zephyr", "Bright"), ("Puck", "Upbeat"), ("Charon", "Informative"), ("Kore", "Firm"),
        ("Fenrir", "Excitable"), ("Leda", "Youthful"), ("Orus", "Firm"), ("Aoede", "Breezy"),
        ("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"), ("Enceladus", "Breathy"), ("Iapetus", "Clear"),
        ("Umbriel", "Easy-going"), ("Algieba", "Smooth"), ("Despina", "Smooth"), ("Erinome", "Clear"),
        ("Algenib", "Gravelly"), ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
        ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"), ("Pulcherrima", "Forward"),
        ("Achird", "Friendly"), ("Zubenelgenubi", "Casual"), ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"),
        ("Sadaltager", "Knowledgeable"), ("Sulafat", "Warm")
    ].map { Voice(name: $0.0, trait: $0.1) }
}

// MARK: - Local mlx-audio presets

/// Local models offered as one-click voices in Settings. Each one was run on
/// this Mac through `mlx_audio.server` before being listed; mlx-audio quietly
/// falls back to a default voice for unknown names, so only exact built-in
/// names belong here.
enum LocalVoiceCatalog {
    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let license: String
        let downloadGB: Double
        let summary: String
        let voices: [Voice]
        /// Inline cues the model reads from the text itself, e.g. `[Laughter]`.
        var expressionTags: [String] = []
        /// Accepts a free-text voice description (`instruct`) instead of a voice.
        var supportsVoiceDesign = false
    }

    struct Voice: Identifiable, Hashable {
        let name: String
        let label: String
        var id: String { name }
    }

    static let models: [Model] = [
        Model(
            id: "mlx-community/Ming-3.0-tts-0.5B-bf16",
            name: "Ming-3.0-tts 0.5B",
            license: "MIT",
            downloadGB: 3.0,
            summary: "Speech Arena Elo 1187 · 44.1 kHz · EN, ZH, DE, ES, FR, KO, JA",
            voices: [
                Voice(name: "US_James", label: "Ming US James (local)"),
                Voice(name: "US_Emma", label: "Ming US Emma (local)"),
                Voice(name: "US_Stella", label: "Ming US Stella (local)"),
                Voice(name: "UK_George", label: "Ming UK George (local)"),
                Voice(name: "UK_Charlotte", label: "Ming UK Charlotte (local)")
            ],
            expressionTags: [
                "Laughter", "Sigh", "Breathing", "Cough", "Uhm",
                "Surprise-ah", "Surprise-oh", "Dissatisfaction-hnn", "Confirmation-en",
                "Question-ei", "Question-ah", "Question-en", "Question-oh", "Question-huh"
            ],
            supportsVoiceDesign: true
        ),
        Model(
            id: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit",
            name: "Qwen3-TTS 1.7B",
            license: "Apache-2.0",
            downloadGB: 2.7,
            summary: "Faster than real time · 24 kHz · English voices",
            voices: [
                Voice(name: "Ryan", label: "Qwen3 Ryan (local)"),
                Voice(name: "Aiden", label: "Qwen3 Aiden (local)")
            ]
        )
    ]
}

extension LocalVoiceCatalog {
    static func model(withID id: String) -> Model? {
        models.first { $0.id == id }
    }
}
