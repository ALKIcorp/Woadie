import CoreML
import Foundation
import KokoroTTS
import os.log

/// The slice of speech-swift's `KokoroTTSModel` AlkiSpeak uses, so tests can
/// substitute a fake instead of downloading the CoreML weights.
protocol NativeKokoroSynthesizing: AnyObject {
    var availableVoices: [String] { get }
    func synthesize(text: String, voice: String, language: String, speed: Float) throws -> [Float]
}

extension KokoroTTSModel: NativeKokoroSynthesizing {}

/// Kokoro-82M running in-process on CoreML / the Neural Engine via
/// speech-swift, with no Python engine. Voice IDs are prefixed
/// `"kokoro-native:"` so `AppModel` can route them here.
///
/// The model (~170 MB) downloads from Hugging Face the first time it loads,
/// so nothing is fetched until the user enables native Kokoro in Settings.
final class NativeKokoroSpeechService: SpeechGenerating {
    static let idPrefix = "kokoro-native:"
    static let enabledDefaultsKey = "AlkiSpeak.nativeKokoroEnabled"

    private let logger = Logger(subsystem: "com.alki.Woadie", category: "NativeKokoro")
    private let engine: NativeKokoroEngine
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        loadModel: @escaping @Sendable () async throws -> NativeKokoroSynthesizing = {
            // Keep CoreML off the GPU: on macOS 27.2 the MPSGraph compiler
            // rejects the model's transposes ("axes in perm tensor must be
            // unique") and the process crashes during load, which can't be
            // caught. The Neural Engine is what this model targets anyway.
            try await KokoroTTSModel.fromPretrained(computeUnits: .cpuAndNeuralEngine)
        }
    ) {
        self.defaults = defaults
        self.engine = NativeKokoroEngine(loadModel: loadModel)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    /// Loads (downloading on first use) and returns the voice count.
    func prepare() async throws -> Int {
        try await engine.voices().count
    }

    func checkHealth() async -> Bool {
        guard isEnabled else { return false }
        return await engine.isLoaded
    }

    func fetchVoices() async throws -> [String] {
        guard isEnabled else { return [] }
        return try await engine.voices().map { Self.idPrefix + $0 }
    }

    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        let voiceName = Self.stripPrefix(voice)
        let startedAt = Date()
        do {
            let samples = try await engine.synthesize(text: text, voice: voiceName, language: Self.language(forVoice: voiceName))
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info("Native Kokoro synthesis complete job=\(jobID?.uuidString ?? "none", privacy: .public) chars=\(text.count) elapsedMs=\(elapsedMs)")
            return SpeechGenerationResult(
                audioData: Self.wavData(samples: samples, sampleRate: Self.sampleRate),
                latencyMs: elapsedMs,
                charCount: text.count
            )
        } catch let error as AlkiSpeakError {
            throw error
        } catch is CancellationError {
            throw AlkiSpeakError.generation(
                code: "cancelled",
                title: "Speech Request Cancelled",
                message: "The native Kokoro request was cancelled before completion.",
                recoverySuggestion: "Start a new generation request when ready."
            )
        } catch {
            throw AlkiSpeakError.generation(
                code: "native-kokoro.failed",
                title: "Native Kokoro Failed",
                message: "Native Kokoro couldn't speak this text: \(error.localizedDescription)",
                recoverySuggestion: "Check the voice, or turn native Kokoro off and on again in Settings to reload it.",
                underlyingError: error
            )
        }
    }

    static func stripPrefix(_ voiceID: String) -> String {
        voiceID.hasPrefix(idPrefix) ? String(voiceID.dropFirst(idPrefix.count)) : voiceID
    }

    static func isNativeKokoroVoice(_ voiceID: String) -> Bool {
        voiceID.hasPrefix(idPrefix)
    }

    // MARK: - Audio

    static let sampleRate = 24_000

    /// Kokoro voice IDs start with a language letter (`af_heart`, `ff_siwis`,
    /// `jf_alpha`…). speech-swift picks its phonemizer from `language` rather
    /// than the voice, so the two must agree.
    static func language(forVoice voice: String) -> String {
        switch voice.first {
        case "e": return "es"
        case "f": return "fr"
        case "h": return "hi"
        case "i": return "it"
        case "j": return "ja"
        case "p": return "pt"
        case "z": return "zh"
        default: return "en"
        }
    }

    /// Wraps mono float samples in a 16-bit PCM WAV, the format the clip
    /// store and player already handle for Kokoro.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                 // fmt chunk size
        append(UInt16(1))                  // PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))     // byte rate
        append(UInt16(2))                  // block align
        append(UInt16(16))                 // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

/// Owns the model and serializes access to it: speech-swift's `synthesize`
/// is synchronous and its model type isn't thread-safe.
private actor NativeKokoroEngine {
    private let loadModel: @Sendable () async throws -> NativeKokoroSynthesizing
    private var model: NativeKokoroSynthesizing?
    private var loading: Task<NativeKokoroSynthesizing, Error>?

    init(loadModel: @escaping @Sendable () async throws -> NativeKokoroSynthesizing) {
        self.loadModel = loadModel
    }

    var isLoaded: Bool { model != nil }

    func voices() async throws -> [String] {
        try await loadedModel().availableVoices.sorted()
    }

    func synthesize(text: String, voice: String, language: String) async throws -> [Float] {
        let model = try await loadedModel()
        guard model.availableVoices.contains(voice) else {
            throw AlkiSpeakError.generation(
                code: "native-kokoro.voice-missing",
                title: "Native Kokoro Voice Missing",
                message: "Native Kokoro has no voice named \(voice).",
                recoverySuggestion: "Pick another Kokoro (Native) voice."
            )
        }
        return try model.synthesize(text: text, voice: voice, language: language, speed: 1.0)
    }

    /// One load at a time; a failed load is retried on the next request.
    private func loadedModel() async throws -> NativeKokoroSynthesizing {
        if let model { return model }
        if let loading { return try await loading.value }
        let task = Task { try await loadModel() }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        model = loaded
        return loaded
    }
}
