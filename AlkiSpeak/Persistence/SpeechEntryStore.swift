import Foundation
import SwiftData

@MainActor
final class SpeechEntryStore {
    static let legacyKeyPrefix = "AlkiSpeak.savedLogs."

    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        container: ModelContainer? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        self.container = try container ?? ModelContainer(for: SpeechEntry.self)
        context = ModelContext(self.container)
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func fetchAll() throws -> [SpeechEntry] {
        var descriptor = FetchDescriptor<SpeechEntry>()
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func insert(_ entry: SpeechEntry) throws {
        context.insert(entry)
        try context.save()
    }

    func save() throws {
        try context.save()
    }

    /// Renames a saved entry's display name without touching its transcript text.
    /// An empty/whitespace name clears the override so it falls back to the text.
    func rename(_ entry: SpeechEntry, to displayName: String?) throws {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.displayName = (trimmed?.isEmpty == false) ? trimmed : nil
        try context.save()
    }

    func delete(_ entry: SpeechEntry) throws {
        for path in entry.segmentRelativePaths {
            let url = try absoluteURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        context.delete(entry)
        try context.save()
    }

    func relativePath(for url: URL) throws -> String {
        let base = try applicationSupportDirectory()
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return String(path.dropFirst(basePath.count + 1))
    }

    func absoluteURL(for relativePath: String) throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(relativePath)
    }

    @discardableResult
    func migrateLegacyHistoryIfNeeded() throws -> Int {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.legacyKeyPrefix) }
        var migrated = 0
        for key in keys {
            guard let data = defaults.data(forKey: key) else { continue }
            let records: [LegacySpeechRecord]
            do {
                records = try JSONDecoder().decode([LegacySpeechRecord].self, from: data)
            } catch {
                NSLog("[Woadie][Migration] Kept legacy key %@ because decoding failed: %@", key, error.localizedDescription)
                continue
            }
            for record in records {
                let urls = record.segments.compactMap(\.audioURL)
                let paths = urls.compactMap { try? relativePath(for: $0) }
                let entry = SpeechEntry(
                    id: record.id,
                    createdAt: record.timestamp,
                    textContent: record.text,
                    voice: AppConfig.defaultVoice,
                    segmentRelativePaths: paths,
                    stats: QueryStats(
                        tokenCount: max(1, record.text.count / 4),
                        generationTimeSeconds: 0,
                        fileSizeBytes: fileSize(paths: paths),
                        characterCount: record.text.count,
                        segmentCount: record.segments.count,
                        resourceBefore: .empty,
                        resourceAfter: .empty
                    )
                )
                context.insert(entry)
                migrated += 1
            }
            do {
                try context.save()
                defaults.removeObject(forKey: key)
                NSLog("[Woadie][Migration] Migrated %ld legacy speech records from %@", records.count, key)
            } catch {
                context.rollback()
                throw error
            }
        }
        return migrated
    }

    /// Root folder that holds generated/imported clips, created on demand.
    func clipsRootURL() throws -> URL {
        let directory = try applicationSupportDirectory().appendingPathComponent("Woadie", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Relative paths of every `.wav` clip currently on disk under `Woadie/`.
    func clipsOnDisk() throws -> Set<String> {
        let root = try clipsRootURL()
        let base = try applicationSupportDirectory().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "wav" {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base + "/") {
                paths.insert(String(path.dropFirst(base.count + 1)))
            }
        }
        return paths
    }

    /// Deletes clip files that no saved entry references. Returns the count removed.
    @discardableResult
    func cleanupOrphanClips() throws -> Int {
        let referenced = Set(try fetchAll().flatMap { $0.segmentRelativePaths })
        let orphans = ClipInventory.orphanedClipPaths(onDisk: try clipsOnDisk(), referenced: referenced)
        var removed = 0
        for path in orphans {
            let url = try absoluteURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    private func fileSize(paths: [String]) -> Int64 {
        paths.reduce(0) { total, path in
            guard let url = try? absoluteURL(for: path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else { return total }
            return total + size.int64Value
        }
    }

    private func applicationSupportDirectory() throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
