import Foundation
import SwiftData

struct QueryStats: Codable, Hashable {
    var tokenCount: Int?
    var generationTimeSeconds: Double
    var fileSizeBytes: Int64
    var characterCount: Int
    var segmentCount: Int
    var resourceBefore: SystemResourceSnapshot
    var resourceAfter: SystemResourceSnapshot
    /// Averaged CPU/RAM usage sampled across the whole query. Optional so older
    /// persisted stats (written before this field existed) keep decoding.
    var resourceUsage: QueryResourceUsage?

    static let empty = QueryStats(
        tokenCount: nil,
        generationTimeSeconds: 0,
        fileSizeBytes: 0,
        characterCount: 0,
        segmentCount: 0,
        resourceBefore: .empty,
        resourceAfter: .empty
    )

    init(
        tokenCount: Int?,
        generationTimeSeconds: Double,
        fileSizeBytes: Int64,
        characterCount: Int,
        segmentCount: Int,
        resourceBefore: SystemResourceSnapshot,
        resourceAfter: SystemResourceSnapshot,
        resourceUsage: QueryResourceUsage? = nil
    ) {
        self.tokenCount = tokenCount
        self.generationTimeSeconds = generationTimeSeconds
        self.fileSizeBytes = fileSizeBytes
        self.characterCount = characterCount
        self.segmentCount = segmentCount
        self.resourceBefore = resourceBefore
        self.resourceAfter = resourceAfter
        self.resourceUsage = resourceUsage
    }
}

/// Query-wide CPU/RAM averages used by the playback panel tiles and the stats card.
struct QueryResourceUsage: Codable, Hashable {
    var sampleCount: Int
    var averageCPUPercent: Double
    var averageRAMUsedMB: Double
    var peakRAMUsedMB: Double

    static let empty = QueryResourceUsage(
        sampleCount: 0,
        averageCPUPercent: 0,
        averageRAMUsedMB: 0,
        peakRAMUsedMB: 0
    )

    init(sampleCount: Int, averageCPUPercent: Double, averageRAMUsedMB: Double, peakRAMUsedMB: Double) {
        self.sampleCount = sampleCount
        self.averageCPUPercent = averageCPUPercent
        self.averageRAMUsedMB = averageRAMUsedMB
        self.peakRAMUsedMB = peakRAMUsedMB
    }

    /// Averages a series of resource samples taken during a query. Returns `nil`
    /// when no samples were collected so callers can leave usage unset.
    init?(samples: [SystemResourceSnapshot]) {
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        self.init(
            sampleCount: samples.count,
            averageCPUPercent: samples.reduce(0) { $0 + $1.cpuPercent } / count,
            averageRAMUsedMB: samples.reduce(0) { $0 + $1.ramUsedMB } / count,
            peakRAMUsedMB: samples.map(\.ramUsedMB).max() ?? 0
        )
    }
}

struct SystemResourceSnapshot: Codable, Hashable {
    var cpuPercent: Double
    var ramUsedMB: Double
    var ramAvailableMB: Double

    static let empty = SystemResourceSnapshot(cpuPercent: 0, ramUsedMB: 0, ramAvailableMB: 0)
}

@Model
final class SpeechEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var textContent: String
    var voice: String
    var model: String
    var segmentRelativePaths: [String]
    var segmentDurations: [Double]
    var totalDurationSeconds: Double
    var stats: QueryStats
    var appMode: AppMode
    /// Optional user-facing name for storage/rename. Falls back to `textContent`
    /// for display; renaming never mutates the transcript text.
    var displayName: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        textContent: String,
        voice: String,
        model: String = "Kokoro",
        segmentRelativePaths: [String] = [],
        segmentDurations: [Double] = [],
        totalDurationSeconds: Double = 0,
        stats: QueryStats = .empty,
        appMode: AppMode = .pro,
        displayName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.textContent = textContent
        self.voice = voice
        self.model = model
        self.segmentRelativePaths = segmentRelativePaths
        self.segmentDurations = segmentDurations
        self.totalDurationSeconds = totalDurationSeconds
        self.stats = stats
        self.appMode = appMode
        self.displayName = displayName
    }

    /// Name to show in storage views, falling back to the transcript text.
    var resolvedDisplayName: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        return textContent
    }
}

struct LegacySpeechRecord: Codable {
    var id: UUID
    var text: String
    var timestamp: Date
    var segments: [SpeechSegment]
}
