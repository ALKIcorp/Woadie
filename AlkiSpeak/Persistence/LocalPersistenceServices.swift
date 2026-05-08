import Foundation

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
