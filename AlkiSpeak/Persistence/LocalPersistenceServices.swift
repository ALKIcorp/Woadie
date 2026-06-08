import Foundation

struct SpeechEntryArchiveManifest: Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var textContent: String
    var voice: String
    var model: String
    var audioPaths: [String]
    var segmentDurations: [Double]
    var totalDurationSeconds: Double
    var stats: QueryStats
    var appMode: AppMode
}

enum SpeechEntryArchiveError: Error, Equatable, LocalizedError {
    case invalidManifest
    case missingAudioFile(String)
    case invalidAudioPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The selected folder does not contain a valid manifest.json."
        case .missingAudioFile(let path):
            "The archive is missing \(path)."
        case .invalidAudioPath(let path):
            "The archive contains an invalid audio path: \(path)."
        }
    }
}

final class SpeechEntryArchiveService {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func export(entry: SpeechEntry, to destinationDirectory: URL) throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let exportDirectory = destinationDirectory.appendingPathComponent(
            "SpeechExport_\(Self.timestampFormatter.string(from: Date()))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: false)

        var audioPaths: [String] = []
        for (index, relativePath) in entry.segmentRelativePaths.enumerated() {
            let sourceURL = applicationSupportDirectory.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw SpeechEntryArchiveError.missingAudioFile(relativePath)
            }
            let filename = String(format: "segment_%03d.wav", index)
            try fileManager.copyItem(at: sourceURL, to: exportDirectory.appendingPathComponent(filename))
            audioPaths.append(filename)
        }

        let manifest = SpeechEntryArchiveManifest(
            id: entry.id,
            createdAt: entry.createdAt,
            textContent: entry.textContent,
            voice: entry.voice,
            model: entry.model,
            audioPaths: audioPaths,
            segmentDurations: entry.segmentDurations,
            totalDurationSeconds: entry.totalDurationSeconds,
            stats: entry.stats,
            appMode: entry.appMode
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: exportDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return exportDirectory
    }

    @MainActor
    func importEntry(from archiveDirectory: URL) throws -> SpeechEntry {
        let manifestURL = archiveDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw SpeechEntryArchiveError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(
            SpeechEntryArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        ) else {
            throw SpeechEntryArchiveError.invalidManifest
        }

        let sourceURLs = try manifest.audioPaths.map { path -> URL in
            guard URL(fileURLWithPath: path).lastPathComponent == path else {
                throw SpeechEntryArchiveError.invalidAudioPath(path)
            }
            let url = archiveDirectory.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SpeechEntryArchiveError.missingAudioFile(path)
            }
            return url
        }

        let importedID = UUID()
        let importDirectory = applicationSupportDirectory
            .appendingPathComponent("Woadie", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(importedID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)

        do {
            let relativePaths = try sourceURLs.enumerated().map { index, sourceURL in
                let filename = String(format: "segment_%03d.wav", index)
                let destinationURL = importDirectory.appendingPathComponent(filename)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return "Woadie/Imports/\(importedID.uuidString)/\(filename)"
            }
            return SpeechEntry(
                id: importedID,
                createdAt: manifest.createdAt,
                textContent: manifest.textContent,
                voice: manifest.voice,
                model: manifest.model,
                segmentRelativePaths: relativePaths,
                segmentDurations: manifest.segmentDurations,
                totalDurationSeconds: manifest.totalDurationSeconds,
                stats: manifest.stats,
                appMode: manifest.appMode
            )
        } catch {
            try? fileManager.removeItem(at: importDirectory)
            throw error
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()
}

final class UserDefaultsWorkspaceStore: ActiveWorkspacePersisting {
    private let key = "AlkiSpeak.activeWorkspace"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadActiveWorkspace() throws -> WorkspaceSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(WorkspaceSession.self, from: data)
    }

    func saveActiveWorkspace(_ workspace: WorkspaceSession) throws {
        let data = try JSONEncoder().encode(workspace)
        defaults.set(data, forKey: key)
    }
}

final class UserDefaultsSavedLogStore: SavedLogPersisting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLogs(for workspaceID: UUID) throws -> [SavedLogEntry] {
        guard let data = defaults.data(forKey: key(for: workspaceID)) else { return [] }
        return try JSONDecoder().decode([SavedLogEntry].self, from: data)
    }

    func saveLog(_ entry: SavedLogEntry, workspaceID: UUID) throws {
        var entries = try loadLogs(for: workspaceID)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        try replaceLogs(entries, workspaceID: workspaceID)
    }

    func replaceLogs(_ entries: [SavedLogEntry], workspaceID: UUID) throws {
        let data = try JSONEncoder().encode(entries)
        defaults.set(data, forKey: key(for: workspaceID))
    }

    private func key(for workspaceID: UUID) -> String {
        "AlkiSpeak.savedLogs.\(workspaceID.uuidString)"
    }
}

final class FileSegmentedClipStore: SegmentedClipStoring {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func writeClip(data: Data, segmentID: UUID, workspaceID: UUID) throws -> URL {
        let directory = try clipsDirectory(workspaceID: workspaceID)
        let url = directory.appendingPathComponent("\(segmentID.uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeClip(segmentID: UUID, workspaceID: UUID) throws {
        let url = try clipsDirectory(workspaceID: workspaceID).appendingPathComponent("\(segmentID.uuidString).wav")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func clipsDirectory(workspaceID: UUID) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Woadie", isDirectory: true)
            .appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent(workspaceID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class FileSpeechPackageStore: SpeechPackageImportExporting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func exportPackage(_ package: SavedSpeechPackage) throws -> URL {
        let directory = try packagesDirectory()
        let safeName = package.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safeName)-\(package.id.uuidString).woadiepackage")
        let data = try JSONEncoder().encode(package)
        try data.write(to: url, options: .atomic)
        return url
    }

    func importPackage(from url: URL) throws -> SavedSpeechPackage {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SavedSpeechPackage.self, from: data)
    }

    private func packagesDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Woadie", isDirectory: true)
            .appendingPathComponent("Packages", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
