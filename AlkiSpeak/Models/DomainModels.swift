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

/// Where a voice comes from. Edge and API are modeled now so the dropdown and
/// app state can group them, but their synthesis paths are intentionally not
/// wired up in this pass (`isSynthesisSupported == false`).
enum VoiceSource: String, Codable, Hashable, CaseIterable {
    case apple
    case kokoro
    case edge
    case api

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .kokoro: return "Kokoro"
        case .edge: return "Edge"
        case .api: return "Cloud API"
        }
    }

    var isSynthesisSupported: Bool {
        switch self {
        case .apple, .kokoro: return true
        case .edge, .api: return false
        }
    }
}

struct VoiceOption: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let source: VoiceSource
    let isAvailable: Bool

    /// Apple voices synthesize locally; everything else routes through a server.
    var isLocal: Bool { source == .apple }

    init(id: String, label: String, source: VoiceSource, isAvailable: Bool = true) {
        self.id = id
        self.label = label
        self.source = source
        self.isAvailable = isAvailable
    }

    /// Convenience initializer preserving the original `isLocal` call sites.
    init(id: String, label: String, isLocal: Bool) {
        self.init(id: id, label: label, source: isLocal ? .apple : .kokoro, isAvailable: true)
    }
}

enum VoiceGrouping {
    static let favoritesSectionID = "favorites"

    /// Order in which provider sections appear after the synthetic Favorites group.
    static let sourceOrder: [VoiceSource] = [.apple, .kokoro, .edge, .api]

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let voices: [VoiceOption]
    }

    /// Builds the `Favorites`, then per-source sections. Favorited voices appear
    /// both in the Favorites group and in their own provider section. Empty
    /// sections are omitted so unsupported providers stay hidden until populated.
    static func sections(voices: [VoiceOption], favorites: Set<String>) -> [Section] {
        var result: [Section] = []
        let favoriteVoices = voices.filter { favorites.contains($0.id) }
        if !favoriteVoices.isEmpty {
            result.append(Section(id: favoritesSectionID, title: "Favorites", voices: favoriteVoices))
        }
        for source in sourceOrder {
            let group = voices.filter { $0.source == source }
            if !group.isEmpty {
                result.append(Section(id: source.rawValue, title: source.title, voices: group))
            }
        }
        return result
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

    static let speedDefaultsKey = "AlkiSpeak.playback.speed"
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

    static func load(from defaults: UserDefaults = .standard) -> PlaybackTuning {
        let speed = defaults.object(forKey: speedDefaultsKey) as? Double ?? PlaybackTuning.default.speed
        let pitch = defaults.object(forKey: pitchDefaultsKey) as? Double ?? PlaybackTuning.default.pitch
        return PlaybackTuning(speed: speed, pitch: pitch)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(speed, forKey: PlaybackTuning.speedDefaultsKey)
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
