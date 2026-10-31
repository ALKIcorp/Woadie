import Foundation
import Security
import os.log

/// A hosted (or local) speech endpoint that speaks the OpenAI-style
/// `POST {baseURL}/audio/speech` shape: JSON `model`, `input`, `voice`,
/// `response_format` in, raw audio bytes out. OpenRouter, OpenAI, Mistral and
/// the `mlx-audio` server all accept it, so one adapter covers every preset.
struct CloudProvider: Identifiable, Hashable {
    let id: String
    let name: String
    /// `nil` for the custom provider, whose base URL the user enters.
    let defaultBaseURL: String?
    let requiresAPIKey: Bool
    let modelPrompt: String
    let voicePrompt: String

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

    static let all: [CloudProvider] = [.openRouter, .openAI, .mistral, .localMLX, .custom]

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

    init(id: UUID = UUID(), providerID: String, model: String, voice: String, label: String) {
        self.id = id
        self.providerID = providerID
        self.model = model
        self.voice = voice
        self.label = label
    }

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
        do {
            if settings.load().voice(withID: voice)?.providerID == CloudProvider.localMLX.id {
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
            guard !data.isEmpty else {
                throw Self.failure(code: "cloud.empty-audio", message: "The provider returned an empty audio response.")
            }
            logger.info("Cloud synthesis complete job=\(jobID?.uuidString ?? "none", privacy: .public) chars=\(text.count) elapsedMs=\(elapsedMs)")
            return SpeechGenerationResult(audioData: data, latencyMs: elapsedMs, charCount: text.count)
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
        guard let base = current.baseURL(for: provider), let url = Self.speechURL(base: base) else {
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
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // MP3 is the one format every preset returns; the clip pipeline already
        // plays Edge's MP3 output, so no extra decoding path is needed.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": cloudVoice.model,
            "input": text,
            "voice": cloudVoice.voice,
            "response_format": "mp3"
        ])
        return request
    }

    static func speechURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/audio/speech"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
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
    /// (`{"error":{"message":…}}`, `{"error":"…"}`, `{"detail":…}`).
    static func providerMessage(from body: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["error"] as? String { return message }
            if let message = json["detail"] as? String { return message }
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
