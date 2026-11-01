import Foundation

// MARK: - Fallback

/// Why a voice was given up on for the rest of a request.
enum FallbackReason: String, Equatable {
    case quota
    case auth
    case network
    case timeout
    case server
    case unavailable
    case cap

    /// How the notice describes it: "<voice> <phrase>, continuing with …".
    var phrase: String {
        switch self {
        case .quota: return "is out of quota or rate limited"
        case .auth: return "rejected its API key"
        case .network: return "couldn't be reached"
        case .timeout: return "timed out"
        case .server: return "had a server error"
        case .unavailable: return "isn't available"
        case .cap: return "hit this month's spending cap"
        }
    }
}

enum VoiceFallback {
    /// Whether another voice is likely to succeed where this error happened:
    /// the provider is down, out of quota, rejecting the key, or the local
    /// engine didn't start. Problems with the text itself, a deleted voice,
    /// or cancellation don't fall back.
    static func reason(for error: Error) -> FallbackReason? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return nil
            case .timedOut: return .timeout
            default: return .network
            }
        }
        guard let appError = error as? AlkiSpeakError else { return nil }
        let reason = reason(forCode: appError.code)
        // Request failures keep the URL error's code, not the error itself.
        if reason == .network, appError.context["urlErrorCode"] == "\(URLError.Code.timedOut.rawValue)" {
            return .timeout
        }
        return reason
    }

    static func reason(forCode code: String) -> FallbackReason? {
        if code.contains("cancelled") { return nil }
        if code.hasSuffix(UsageMeter.capReachedCode) { return .cap }
        if let range = code.range(of: "cloud.http.") ?? code.range(of: "http-"),
           let status = Int(code[range.upperBound...]) {
            switch status {
            case 401, 403: return .auth
            case 402, 429: return .quota
            case 408, 504: return .timeout
            case 500...599: return .server
            default: return nil
            }
        }
        if code.hasSuffix("cloud.api-key-missing") { return .auth }
        if code.hasSuffix("request-failed") || code.hasSuffix("no-response") || code.hasSuffix("missing-http-response") {
            return .network
        }
        if code.hasSuffix("empty-audio") || code.hasSuffix("gemini.no-audio") { return .server }
        if code.hasPrefix("engine.") || code.contains("native-kokoro.failed") || code.contains(".mlx.") {
            return .unavailable
        }
        return nil
    }
}

// MARK: - Usage and cost

/// Characters generated per provider per month, what the user pays per
/// million characters, and optional monthly caps. Cache hits are free and
/// aren't counted.
struct UsageSettings: Codable, Equatable {
    /// Falls back to another voice when one fails. Off means a failure stops the request.
    var fallbackEnabled = true
    /// Tried first when the selected voice fails.
    var backupVoiceID: String?
    /// Dollars per million characters, by provider key.
    var pricePerMillion: [String: Double] = [:]
    /// Monthly character caps, by provider key.
    var monthlyCap: [String: Int] = [:]
    /// Characters by month ("2026-10"), then provider key.
    var characters: [String: [String: Int]] = [:]

    static let defaultsKey = "AlkiSpeak.usageSettings"

    static func load(from defaults: UserDefaults = .standard) -> UsageSettings {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(UsageSettings.self, from: $0) } ?? UsageSettings()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func characters(forMonth month: String, provider: String) -> Int {
        characters[month]?[provider] ?? 0
    }

    /// This month's spend for a provider, or nil without a price.
    func spend(forMonth month: String, provider: String) -> Double? {
        guard let price = pricePerMillion[provider] else { return nil }
        return Double(characters(forMonth: month, provider: provider)) / 1_000_000 * price
    }

    func totalSpend(forMonth month: String) -> Double {
        (characters[month] ?? [:]).keys.compactMap { spend(forMonth: month, provider: $0) }.reduce(0, +)
    }
}

actor UsageMeter {
    static let shared = UsageMeter()
    static let capReachedCode = "usage.cap-reached"

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    nonisolated static func monthKey(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Providers that never cost money.
    nonisolated static let freeProviders: Set<String> = ["apple", "edge", "kokoro", "kokoro-native", CloudProvider.localMLX.id]

    /// The usage bucket for a voice: its cloud provider, or the engine.
    nonisolated static func providerKey(forVoice voice: String, cloudProviderID: String?) -> String {
        if let cloudProviderID { return cloudProviderID }
        if voice.hasPrefix("apple:") { return "apple" }
        if voice.hasPrefix(EdgeSpeechGenerationService.idPrefix) { return "edge" }
        if NativeKokoroSpeechService.isNativeKokoroVoice(voice) { return "kokoro-native" }
        return "kokoro"
    }

    func settings() -> UsageSettings { UsageSettings.load(from: defaults) }

    func update(_ change: (inout UsageSettings) -> Void) {
        var settings = UsageSettings.load(from: defaults)
        change(&settings)
        settings.save(to: defaults)
    }

    /// Throws when generating `characters` more would pass the provider's cap.
    func checkCap(provider: String, adding characters: Int) throws {
        let settings = UsageSettings.load(from: defaults)
        guard let cap = settings.monthlyCap[provider] else { return }
        let used = settings.characters(forMonth: Self.monthKey(for: now()), provider: provider)
        guard used + characters > cap else { return }
        throw AlkiSpeakError.generation(
            code: Self.capReachedCode,
            title: "Monthly Cap Reached",
            message: "This voice's provider has used \(used.formatted()) of its \(cap.formatted())-character monthly cap.",
            recoverySuggestion: "Raise or remove the cap in Settings → Usage, or pick another voice."
        )
    }

    func record(provider: String, characters: Int) {
        update { settings in
            let month = Self.monthKey(for: now())
            settings.characters[month, default: [:]][provider, default: 0] += characters
        }
    }
}

// MARK: - Generating with fallback

/// Generates one request's segments, moving down a chain of voices when one
/// fails for a reason another could get past. Once it moves on it stays on
/// the new voice for the rest of the request, so the voice doesn't flip back
/// and forth between segments.
final class FallbackGenerator: @unchecked Sendable {
    struct Candidate {
        let voice: String
        let label: String
        let service: SpeechGenerating
        let cacheConfiguration: String
        let providerKey: String
        /// Python Kokoro voices (including blends) need the engine woken first.
        let needsPythonEngine: Bool
    }

    private actor Cursor {
        private(set) var index = 0
        /// Moves past `from`; true only for the caller that actually moved it.
        func advance(from: Int) -> Bool {
            guard index == from else { return false }
            index = from + 1
            return true
        }
    }

    let candidates: [Candidate]
    private let cursor = Cursor()
    private let cache: AudioClipCache
    private let usage: UsageMeter
    private let prepareEngine: @MainActor (String) async throws -> Void
    private let onFallback: @MainActor (Candidate, Candidate, FallbackReason) -> Void

    init(
        candidates: [Candidate],
        cache: AudioClipCache,
        usage: UsageMeter,
        prepareEngine: @escaping @MainActor (String) async throws -> Void,
        onFallback: @escaping @MainActor (Candidate, Candidate, FallbackReason) -> Void
    ) {
        precondition(!candidates.isEmpty)
        self.candidates = candidates
        self.cache = cache
        self.usage = usage
        self.prepareEngine = prepareEngine
        self.onFallback = onFallback
    }

    /// Wakes the selected voice's engine, falling back if it can't start.
    func preparePrimary() async throws {
        guard candidates[0].needsPythonEngine else { return }
        do {
            try await prepareEngine(candidates[0].voice)
        } catch {
            try await moveOn(from: 0, after: error)
        }
    }

    /// Audio for `text`: cached, or generated by the current voice or the
    /// next ones in the chain. `context` is the job's surrounding segments;
    /// its audio and request IDs belong to the selected voice, so a fallback
    /// voice gets only the text.
    func generate(text: String, jobID: UUID?, context: SpeechContext = .none) async throws -> (result: SpeechGenerationResult, fromCache: Bool) {
        var index = await cursor.index
        while true {
            let candidate = candidates[index]
            let key = AudioClipCache.key(text: text, voiceConfiguration: candidate.cacheConfiguration)
            if let cached = await cache.audio(forKey: key) {
                return (SpeechGenerationResult(audioData: cached, latencyMs: 0, charCount: text.count), true)
            }
            do {
                try await usage.checkCap(provider: candidate.providerKey, adding: text.count)
                if index > 0, candidate.needsPythonEngine {
                    try await prepareEngine(candidate.voice)
                }
                let result: SpeechGenerationResult
                if let contextual = candidate.service as? ContextualSpeechGenerating {
                    let candidateContext = index == 0 ? context : context.textOnly
                    result = try await contextual.synthesize(text: text, voice: candidate.voice, jobID: jobID, context: candidateContext)
                } else {
                    result = try await candidate.service.synthesize(text: text, voice: candidate.voice, jobID: jobID)
                }
                await cache.store(result.audioData, forKey: key)
                await usage.record(provider: candidate.providerKey, characters: text.count)
                return (result, false)
            } catch {
                try await moveOn(from: index, after: error)
                index = await cursor.index
            }
        }
    }

    private func moveOn(from index: Int, after error: Error) async throws {
        guard !Task.isCancelled,
              let reason = VoiceFallback.reason(for: error),
              index + 1 < candidates.count
        else { throw error }
        if await cursor.advance(from: index) {
            await onFallback(candidates[index], candidates[index + 1], reason)
        }
    }
}
