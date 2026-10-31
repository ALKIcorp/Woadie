import Foundation
import SwiftUI

enum AppAppearance: String, Codable, CaseIterable, Hashable {
    static let defaultsKey = "AlkiSpeak.appearance"

    case light
    case dark
    case system

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var label: String {
        rawValue.capitalized
    }

    static func load(from defaults: UserDefaults = .standard) -> AppAppearance {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .system
        }
        return appearance
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum AppMode: String, Codable, CaseIterable, Hashable {
    case quick
    case pro
}

enum LogMode: String, Codable, CaseIterable, Hashable {
    case auto
    case manual
}

enum EngineStatus: String, Codable, Hashable {
    case starting
    case running
    case idle
    case busy
    case degraded
    case retrying
    case timedOut
    case stalled
    case stopped
    case failed

    var label: String {
        switch self {
        case .starting: return "STARTING"
        case .running: return "RUNNING"
        case .idle: return "IDLE"
        case .busy: return "BUSY"
        case .degraded: return "DEGRADED"
        case .retrying: return "RETRYING"
        case .timedOut: return "TIMED OUT"
        case .stalled: return "STALLED"
        case .stopped: return "STOPPED"
        case .failed: return "FAILED"
        }
    }

    var color: Color {
        switch self {
        case .running, .idle:
            return .green
        case .starting, .busy, .retrying:
            return .orange
        case .degraded, .timedOut, .stalled:
            return .yellow
        case .stopped:
            return .secondary
        case .failed:
            return .red
        }
    }

    var isAvailableForRemoteSpeech: Bool {
        switch self {
        case .running, .idle, .busy, .degraded:
            return true
        case .starting, .retrying, .timedOut, .stalled, .stopped, .failed:
            return false
        }
    }

    var isProcessExpectedAlive: Bool {
        switch self {
        case .starting, .running, .idle, .busy, .degraded, .retrying:
            return true
        case .timedOut, .stalled, .stopped, .failed:
            return false
        }
    }
}

struct EngineIssue: Identifiable, Codable, Hashable {
    var id: UUID
    var code: String
    var title: String
    var description: String
    var probableCause: String
    var subsystem: String
    var timestamp: Date
    var retryCount: Int
    var jobID: UUID?
    var rawError: String?
    var context: [String: String]

    init(
        id: UUID = UUID(),
        code: String,
        title: String,
        description: String,
        probableCause: String,
        subsystem: String,
        timestamp: Date = Date(),
        retryCount: Int = 0,
        jobID: UUID? = nil,
        rawError: String? = nil,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.description = description
        self.probableCause = probableCause
        self.subsystem = subsystem
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.jobID = jobID
        self.rawError = rawError
        self.context = context
    }
}

struct EngineHealthSummary: Codable, Hashable {
    var status: EngineStatus
    var pid: Int32?
    var port: Int
    var baseURL: URL
    var startedAt: Date?
    var lastHealthCheckAt: Date?
    var lastSuccessfulHealthCheckAt: Date?
    var retryCount: Int
    var consecutiveHealthFailures: Int
    var activeJobID: UUID?
    var latestIssue: EngineIssue?
    var recentIssues: [EngineIssue]

    static let stopped = EngineHealthSummary(
        status: .stopped,
        pid: nil,
        port: AppConfig.enginePort,
        baseURL: AppConfig.serverBaseURL,
        startedAt: nil,
        lastHealthCheckAt: nil,
        lastSuccessfulHealthCheckAt: nil,
        retryCount: 0,
        consecutiveHealthFailures: 0,
        activeJobID: nil,
        latestIssue: nil,
        recentIssues: []
    )
}

struct EngineDiagnostic: Identifiable, Codable, Hashable {
    enum Severity: String, Codable, Hashable {
        case info
        case warning
        case error
    }

    var id: UUID
    var timestamp: Date
    var severity: Severity
    var code: String
    var message: String
    var context: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: Severity,
        code: String,
        message: String,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.code = code
        self.message = message
        self.context = context
    }
}

struct WorkspaceSession: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var rootURL: URL?
    var selectedVoiceID: String

    init(
        id: UUID = UUID(),
        name: String = "Default Workspace",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rootURL: URL? = nil,
        selectedVoiceID: String = AppConfig.defaultVoice
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rootURL = rootURL
        self.selectedVoiceID = selectedVoiceID
    }
}

struct SpeechSegment: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case pending
        case generating
        case ready
        case failed
    }

    var id: UUID
    var index: Int
    var text: String
    var status: Status
    var audioURL: URL?
    var error: AlkiSpeakError?
    /// Read from the clip when playback queues it, so it isn't parsed again.
    var durationSeconds: Double?

    init(
        id: UUID = UUID(),
        index: Int,
        text: String,
        status: Status = .pending,
        audioURL: URL? = nil,
        error: AlkiSpeakError? = nil
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.status = status
        self.audioURL = audioURL
        self.error = error
    }
}

struct SpeechJob: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case queued
        case generating
        case playing
        case completed
        case failed
        case cancelled
    }

    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var text: String
    var voiceID: String
    var segments: [SpeechSegment]
    var status: Status
    var logEntryID: UUID?
    var error: AlkiSpeakError?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        text: String,
        voiceID: String,
        segments: [SpeechSegment],
        status: Status = .queued,
        logEntryID: UUID? = nil,
        error: AlkiSpeakError? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.voiceID = voiceID
        self.segments = segments
        self.status = status
        self.logEntryID = logEntryID
        self.error = error
    }
}

struct PlaybackSnapshot: Codable, Hashable {
    enum State: String, Codable, Hashable {
        case idle
        case preparing
        case playing
        case paused
        case stopped
        case failed

        var blocksNewSpeech: Bool {
            self == .preparing || self == .playing
        }
    }

    var state: State
    var activeJobID: UUID?
    var activeLogEntryID: UUID?
    var currentSegmentID: UUID?
    var elapsedTime: TimeInterval
    var duration: TimeInterval?
    var bufferedDuration: TimeInterval
    var statusMessage: String?

    static let idle = PlaybackSnapshot(
        state: .idle,
        activeJobID: nil,
        activeLogEntryID: nil,
        currentSegmentID: nil,
        elapsedTime: 0,
        duration: nil,
        bufferedDuration: 0,
        statusMessage: nil
    )
}

struct PlaybackLocation: Equatable {
    let segmentIndex: Int
    let localTime: TimeInterval
}

struct PlaybackTimeline: Equatable {
    private(set) var durations: [TimeInterval?]
    private let estimates: [TimeInterval]

    init(segmentCharacterCounts: [Int]) {
        durations = Array(repeating: nil, count: segmentCharacterCounts.count)
        estimates = segmentCharacterCounts.map { max(TimeInterval($0) / 150.0, 0.1) }
    }

    mutating func markReady(index: Int, duration: TimeInterval) {
        guard durations.indices.contains(index), duration.isFinite, duration > 0 else { return }
        durations[index] = duration
    }

    var bufferedDuration: TimeInterval {
        var total: TimeInterval = 0
        for duration in durations {
            guard let duration else { break }
            total += duration
        }
        return total
    }

    var totalDuration: TimeInterval {
        zip(durations, estimates).reduce(0) { $0 + ($1.0 ?? $1.1) }
    }

    func location(for globalTime: TimeInterval) -> PlaybackLocation? {
        let target = max(0, globalTime)
        guard target <= bufferedDuration + 0.000_1 else { return nil }
        var start: TimeInterval = 0
        for (index, duration) in durations.enumerated() {
            guard let duration else { break }
            let end = start + duration
            if target <= end || index == durations.count - 1 {
                return PlaybackLocation(segmentIndex: index, localTime: min(max(0, target - start), duration))
            }
            start = end
        }
        return nil
    }

    func globalTime(segmentIndex: Int, localTime: TimeInterval) -> TimeInterval {
        durations.prefix(segmentIndex).compactMap { $0 }.reduce(0, +) + max(0, localTime)
    }
}

/// How the read-along view follows playback.
enum ReadAlongMode: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case sentence = "Sentence"
    case word = "Word"

    static let defaultsKey = "AlkiSpeak.readAlong"
    var id: Self { self }

    static func load(from defaults: UserDefaults = .standard) -> ReadAlongMode {
        defaults.string(forKey: defaultsKey).flatMap(ReadAlongMode.init(rawValue:)) ?? .sentence
    }
}

/// Maps playback time to a place in the spoken text and back. Offsets are
/// UTF-16, matching `NSString` and `AVSpeechSynthesizer`'s ranges. Within a
/// segment, time is spread over its characters, which tracks speech closely
/// enough to follow along.
enum ReadAlong {
    struct Segment: Equatable {
        let length: Int
        /// Known once the clip is queued; estimated until then.
        let duration: TimeInterval?

        var effectiveDuration: TimeInterval { duration ?? ReadAlong.estimatedDuration(length: length) }
    }

    /// Roughly 15 characters a second.
    static func estimatedDuration(length: Int) -> TimeInterval { max(Double(length) / 15, 0.1) }

    /// The words or sentences of `text`, as ranges.
    static func units(in text: String, mode: ReadAlongMode) -> [NSRange] {
        let pattern: String
        switch mode {
        case .off: return []
        case .word: pattern = #"\S+"#
        case .sentence: pattern = #"[^.!?…\n]+(?:[.!?…]+["”’)\]]*)?\s*"#
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
            .map { range in
                // Trailing spaces belong to the gap, not the highlight.
                let piece = (text as NSString).substring(with: range) as NSString
                var length = range.length
                while length > 0, let scalar = Unicode.Scalar(piece.character(at: length - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    length -= 1
                }
                return NSRange(location: range.location, length: length)
            }
            .filter { $0.length > 0 }
    }

    /// Which segment, and how far into it, `elapsed` seconds of playback is.
    static func position(elapsed: TimeInterval, segments: [Segment]) -> (segment: Int, offset: Int)? {
        guard !segments.isEmpty else { return nil }
        var start: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            let duration = segment.effectiveDuration
            if elapsed < start + duration || index == segments.count - 1 {
                let fraction = min(max((elapsed - start) / duration, 0), 1)
                return (index, min(Int(fraction * Double(segment.length)), max(segment.length - 1, 0)))
            }
            start += duration
        }
        return nil
    }

    /// When playback reaches `offset` in segment `index`, for click-to-seek.
    static func time(segment index: Int, offset: Int, segments: [Segment]) -> TimeInterval {
        guard segments.indices.contains(index) else { return 0 }
        let before = segments.prefix(index).reduce(0) { $0 + $1.effectiveDuration }
        let segment = segments[index]
        guard segment.length > 0 else { return before }
        return before + segment.effectiveDuration * Double(offset) / Double(segment.length)
    }

    /// The unit containing `offset`, or the last one starting before it.
    static func unit(containing offset: Int, in units: [NSRange]) -> NSRange? {
        units.last { $0.location <= offset }
    }

    /// Splits long text into passages of about `limit` characters at sentence
    /// ends, so a whole book isn't shown at once.
    static func passages(in text: String, limit: Int = 280) -> [NSRange] {
        var result: [NSRange] = []
        var current: NSRange?
        for sentence in units(in: text, mode: .sentence) {
            if var open = current {
                let end = sentence.location + sentence.length
                if end - open.location <= limit {
                    open.length = end - open.location
                    current = open
                    continue
                }
                result.append(open)
            }
            current = sentence
        }
        if let current { result.append(current) }
        return result
    }
}

enum VoiceCycler {
    static func next(current: String, in voices: [String], offset: Int) -> String? {
        guard !voices.isEmpty else { return nil }
        let currentIndex = voices.firstIndex(of: current) ?? 0
        let index = (currentIndex + offset % voices.count + voices.count) % voices.count
        return voices[index]
    }
}

struct ResourceSnapshot: Codable, Hashable {
    var capturedAt: Date
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var engineProcessID: Int32?
    var port: Int

    static let empty = ResourceSnapshot(
        capturedAt: Date(),
        cpuPercent: nil,
        memoryBytes: nil,
        engineProcessID: nil,
        port: AppConfig.enginePort
    )
}

struct SavedSpeechPackage: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var workspaceID: UUID
    var jobs: [SpeechJob]
    var logEntries: [SavedLogEntry]
    var packageURL: URL?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        workspaceID: UUID,
        jobs: [SpeechJob],
        logEntries: [SavedLogEntry],
        packageURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.workspaceID = workspaceID
        self.jobs = jobs
        self.logEntries = logEntries
        self.packageURL = packageURL
    }
}

struct SavedLogEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var timestamp: Date
    var isUser: Bool
    var jobID: UUID?
    var segments: [SpeechSegment]

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        isUser: Bool,
        jobID: UUID? = nil,
        segments: [SpeechSegment] = []
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isUser = isUser
        self.jobID = jobID
        self.segments = segments
    }
}

/// Where a voice comes from. `api` is modeled now so the dropdown and app
/// state can group it, but its synthesis path is intentionally not wired up
/// in this pass (`isSynthesisSupported == false`).
enum VoiceSource: String, Codable, Hashable, CaseIterable {
    case apple
    case kokoro
    case kokoroNative
    case edge
    case api

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .kokoro: return "Kokoro"
        case .kokoroNative: return "Kokoro (Native)"
        case .edge: return "Edge"
        case .api: return "Cloud"
        }
    }

    var isSynthesisSupported: Bool {
        switch self {
        case .apple, .kokoro, .kokoroNative, .edge, .api: return true
        }
    }
}

enum AppleVoiceQuality: String, Codable, Hashable {
    case highest
    case medium
    case low
}

struct VoiceOption: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let source: VoiceSource
    let isAvailable: Bool
    let appleQuality: AppleVoiceQuality?
    /// What the picker shows: a plain name ("Heart") and a short tag
    /// ("Kokoro · American English · Female") instead of the raw label.
    let name: String
    let detail: String
    /// Runs on this Mac (free and private) rather than through an online service.
    let isOnDevice: Bool

    /// Apple voices synthesize locally; everything else routes through a server.
    var isLocal: Bool { source == .apple }

    init(
        id: String,
        label: String,
        source: VoiceSource,
        isAvailable: Bool = true,
        appleQuality: AppleVoiceQuality? = nil,
        name: String? = nil,
        detail: String? = nil,
        isOnDevice: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.isAvailable = isAvailable
        self.appleQuality = appleQuality
        let derived = VoiceNaming.describe(id: id, label: label, source: source, appleQuality: appleQuality)
        self.name = name ?? derived.name
        self.detail = detail ?? derived.detail
        self.isOnDevice = isOnDevice ?? (source != .edge && source != .api)
    }

    /// Convenience initializer preserving the original `isLocal` call sites.
    init(id: String, label: String, isLocal: Bool) {
        self.init(id: id, label: label, source: isLocal ? .apple : .kokoro, isAvailable: true, appleQuality: nil)
    }
}

/// Turns raw voice IDs and labels ("Apple - Samantha [en-US]", "af_heart",
/// "edge:en-US-AriaNeural") into a plain name and a short descriptive tag.
enum VoiceNaming {
    static func describe(id: String, label: String, source: VoiceSource, appleQuality: AppleVoiceQuality?) -> (name: String, detail: String) {
        switch source {
        case .apple:
            var name = label.removingPrefix("Apple - ")
            var locale: String?
            if let open = name.lastIndex(of: "["), name.hasSuffix("]") {
                locale = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let quality: String? = switch appleQuality {
            case .highest: "Premium"
            case .medium: "Enhanced"
            case .low, nil: nil
            }
            return (name, (["Apple", locale, quality].compactMap { $0 }).joined(separator: " · "))
        case .kokoro, .kokoroNative:
            let raw = NativeKokoroSpeechService.stripPrefix(id)
            let base = kokoro(raw)
            let engine = source == .kokoroNative ? "Kokoro (Neural Engine)" : "Kokoro"
            return (base.name, ([engine] + base.traits).joined(separator: " · "))
        case .edge:
            let raw = EdgeSpeechGenerationService.stripPrefix(id)
            let parts = raw.split(separator: "-").map(String.init)
            guard parts.count >= 3 else { return (raw, "Microsoft Edge") }
            var name = parts[2...].joined(separator: "-")
            for suffix in ["MultilingualNeural", "Neural"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
            return (name, "Microsoft Edge · \(parts[0])-\(parts[1])")
        case .api:
            return (label.removingPrefix("Cloud - ").removingSuffix(" (local)"), "Online")
        }
    }

    /// A one-line introduction in the voice's own language, for previews.
    static func sampleText(for voice: VoiceOption) -> String {
        let name = voice.name
        switch languageCode(for: voice) {
        case "es": return "Hola, soy \(name). Así suena mi voz."
        case "fr": return "Bonjour, je suis \(name). Voici ma voix."
        case "it": return "Ciao, sono \(name). Questa è la mia voce."
        case "pt": return "Olá, eu sou \(name). Esta é a minha voz."
        case "de": return "Hallo, ich bin \(name). So klingt meine Stimme."
        case "ja": return "こんにちは、\(name)です。これが私の声です。"
        case "zh": return "你好，我是\(name)。这就是我的声音。"
        case "hi": return "नमस्ते, मैं \(name) हूँ। मेरी आवाज़ ऐसी है।"
        default: return "Hi, I'm \(name). This is how I sound."
        }
    }

    /// The two-letter language of a voice, when its ID or label says.
    static func languageCode(for voice: VoiceOption) -> String? {
        switch voice.source {
        case .kokoro, .kokoroNative:
            let raw = NativeKokoroSpeechService.stripPrefix(voice.id)
            let codes: [Character: String] = ["a": "en", "b": "en", "e": "es", "f": "fr", "h": "hi", "i": "it", "j": "ja", "p": "pt", "z": "zh"]
            return raw.first.flatMap { codes[$0] }
        case .edge:
            return EdgeSpeechGenerationService.stripPrefix(voice.id).split(separator: "-").first.map(String.init)
        case .apple:
            guard let open = voice.label.lastIndex(of: "[") else { return nil }
            return String(voice.label[voice.label.index(after: open)...].prefix(2))
        case .api:
            return nil
        }
    }

    /// Kokoro IDs are `<language><gender>_<name>`, e.g. `af_heart`, `bm_george`.
    static func kokoro(_ id: String) -> (name: String, traits: [String]) {
        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count == 2 else { return (id, []) }
        let language: String? = switch parts[0].first {
        case "a": "American English"
        case "b": "British English"
        case "e": "Spanish"
        case "f": "French"
        case "h": "Hindi"
        case "i": "Italian"
        case "j": "Japanese"
        case "p": "Portuguese"
        case "z": "Mandarin"
        default: nil
        }
        let gender: String? = switch parts[0].last {
        case "f": "Female"
        case "m": "Male"
        default: nil
        }
        let name = parts[1].split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return (name, [language, gender].compactMap { $0 })
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

/// A mix of Kokoro voices saved as a voice of its own. The Python Kokoro
/// engine reads the ID ("af_bella*0.60,am_michael*0.40") and mixes the
/// voices' style tensors by weight.
struct KokoroBlend: Codable, Identifiable, Hashable {
    struct Part: Codable, Hashable {
        var voice: String
        var weight: Double
    }

    static let defaultsKey = "AlkiSpeak.kokoroBlends"

    var id = UUID()
    var name: String
    var parts: [Part]

    var voiceID: String {
        parts.map { "\($0.voice)*" + String(format: "%.2f", $0.weight) }.joined(separator: ",")
    }

    /// "Kokoro blend · Bella 60% + Michael 40%"
    var detail: String {
        let total = parts.reduce(0) { $0 + $1.weight }
        let mix = parts.map { part in
            "\(VoiceNaming.kokoro(part.voice).name) \(Int((part.weight / max(total, 0.0001) * 100).rounded()))%"
        }
        return "Kokoro blend · " + mix.joined(separator: " + ")
    }

    static func isBlend(_ voiceID: String) -> Bool { voiceID.contains("*") }

    static func load(from defaults: UserDefaults = .standard) -> [KokoroBlend] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([KokoroBlend].self, from: $0) } ?? []
    }

    static func save(_ blends: [KokoroBlend], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(blends), forKey: defaultsKey)
    }
}

/// Groups voices the way people choose them: favorites and recent first, then
/// what runs on this Mac (free, private) versus online services. Apple's
/// novelty and low-quality voices sit in their own section at the end.
enum VoiceGrouping {
    static let favoritesSectionID = "favorites"
    static let recentSectionID = "recent"
    static let onDeviceSectionID = "on-device"
    static let onlineSectionID = "online"
    static let moreAppleSectionID = "apple-more"
    static let recentLimit = 5

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let voices: [VoiceOption]
    }

    /// Favorited and recent voices also appear in their own section below.
    /// Empty sections are omitted.
    static func sections(voices: [VoiceOption], favorites: Set<String>, recent: [String] = []) -> [Section] {
        var result: [Section] = []
        let favoriteVoices = voices.filter { favorites.contains($0.id) }
        if !favoriteVoices.isEmpty {
            result.append(Section(id: favoritesSectionID, title: "Favorites", voices: favoriteVoices))
        }
        let byID = Dictionary(voices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recentVoices = recent.compactMap { byID[$0] }.prefix(recentLimit)
        if !recentVoices.isEmpty {
            result.append(Section(id: recentSectionID, title: "Recent", voices: Array(recentVoices)))
        }
        let isMoreApple: (VoiceOption) -> Bool = { $0.source == .apple && $0.appleQuality == .low }
        // Voices you added yourself, then neural voices, then Apple's best.
        let rank: (VoiceOption) -> Int = { voice in
            switch voice.source {
            case .api: return 0
            case .kokoroNative: return 1
            case .kokoro: return 2
            case .apple: return voice.appleQuality == .highest ? 3 : voice.appleQuality == .medium ? 4 : 5
            case .edge: return 6
            }
        }
        let onDevice = voices.filter { $0.isOnDevice && !isMoreApple($0) }
        if !onDevice.isEmpty {
            result.append(Section(id: onDeviceSectionID, title: "On this Mac", voices: stableSorted(onDevice, by: rank)))
        }
        let online = voices.filter { !$0.isOnDevice }
        if !online.isEmpty {
            result.append(Section(id: onlineSectionID, title: "Online", voices: stableSorted(online, by: rank)))
        }
        let moreApple = voices.filter(isMoreApple)
        if !moreApple.isEmpty {
            result.append(Section(id: moreAppleSectionID, title: "More Apple voices", voices: moreApple))
        }
        return result
    }

    private static func stableSorted(_ voices: [VoiceOption], by rank: (VoiceOption) -> Int) -> [VoiceOption] {
        voices.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Voices whose name, tag or label contains every word of `query`.
    static func search(_ voices: [VoiceOption], query: String) -> [VoiceOption] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return voices }
        return voices.filter { voice in
            let haystack = "\(voice.name) \(voice.detail) \(voice.label)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

enum VoiceSelection {
    /// Preserves the user's current voice whenever it still exists in the catalog
    /// — even if it is temporarily unavailable — so a transient empty voice list
    /// never silently swaps the selection. Falls back to the first available
    /// voice, then any voice, then the provided default.
    static func resolved(current: String, in voices: [VoiceOption], fallback: String) -> String {
        if voices.contains(where: { $0.id == current }) {
            return current
        }
        if let firstAvailable = voices.first(where: { $0.isAvailable }) {
            return firstAvailable.id
        }
        return voices.first?.id ?? fallback
    }
}

/// Listen-only playback tuning. Applied to the audio graph so speed and pitch
/// change what the user hears without ever rewriting the generated clips.
struct PlaybackTuning: Codable, Hashable {
    static let speedRange: ClosedRange<Double> = 0.65...1.75
    static let pitchRange: ClosedRange<Double> = -6...6
    static let `default` = PlaybackTuning(speed: 1.0, pitch: 0)

    /// Speed is no longer saved; these keys only get cleaned up. A remembered
    /// speed kept reopening the app at whatever the knob was last left at
    /// (often its 1.75x maximum).
    static let legacySpeedDefaultsKeys = ["AlkiSpeak.playback.speed", "AlkiSpeak.playback.speed_v2"]
    static let pitchDefaultsKey = "AlkiSpeak.playback.pitch"

    let speed: Double
    let pitch: Double

    init(speed: Double, pitch: Double) {
        self.speed = PlaybackTuning.speedRange.clampingValue(speed)
        self.pitch = PlaybackTuning.pitchRange.clampingValue(pitch)
    }

    var isDefault: Bool { self == PlaybackTuning.default }

    func withSpeed(_ value: Double) -> PlaybackTuning { PlaybackTuning(speed: value, pitch: pitch) }
    func withPitch(_ value: Double) -> PlaybackTuning { PlaybackTuning(speed: speed, pitch: value) }

    /// Every launch starts at 1x speed; only pitch carries over.
    static func load(from defaults: UserDefaults = .standard) -> PlaybackTuning {
        legacySpeedDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
        let pitch = defaults.object(forKey: pitchDefaultsKey) as? Double ?? PlaybackTuning.default.pitch
        return PlaybackTuning(speed: PlaybackTuning.default.speed, pitch: pitch)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(pitch, forKey: PlaybackTuning.pitchDefaultsKey)
    }
}

extension ClosedRange where Bound == Double {
    func clampingValue(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

struct DashboardTelemetry: Codable, Hashable {
    var lastLatencyMs: Int?
    var lastCharCount: Int?
    var resourceSnapshot: ResourceSnapshot
    var generatedJobCount: Int
    var failedJobCount: Int

    static let empty = DashboardTelemetry(
        lastLatencyMs: nil,
        lastCharCount: nil,
        resourceSnapshot: .empty,
        generatedJobCount: 0,
        failedJobCount: 0
    )
}

struct PersistenceSnapshot: Codable, Hashable {
    enum State: String, Codable, Hashable {
        case idle
        case saving
        case exporting
        case importing
        case failed
    }

    var state: State
    var lastSavedAt: Date?
    var lastExportURL: URL?
    var error: AlkiSpeakError?

    static let idle = PersistenceSnapshot(
        state: .idle,
        lastSavedAt: nil,
        lastExportURL: nil,
        error: nil
    )
}
