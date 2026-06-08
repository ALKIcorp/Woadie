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

    static let empty = QueryStats(
        tokenCount: nil,
        generationTimeSeconds: 0,
        fileSizeBytes: 0,
        characterCount: 0,
        segmentCount: 0,
        resourceBefore: .empty,
        resourceAfter: .empty
    )
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
        appMode: AppMode = .pro
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
    }
}

struct LegacySpeechRecord: Codable {
    var id: UUID
    var text: String
    var timestamp: Date
    var segments: [SpeechSegment]
}
