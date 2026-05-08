import Foundation

protocol ActiveWorkspacePersisting: AnyObject {
    func loadActiveWorkspace() throws -> WorkspaceSession?
    func saveActiveWorkspace(_ workspace: WorkspaceSession) throws
}

protocol SavedLogPersisting: AnyObject {
    func loadLogs(for workspaceID: UUID) throws -> [SavedLogEntry]
    func saveLog(_ entry: SavedLogEntry, workspaceID: UUID) throws
    func replaceLogs(_ entries: [SavedLogEntry], workspaceID: UUID) throws
}

protocol SegmentedClipStoring: AnyObject {
    func writeClip(data: Data, segmentID: UUID, workspaceID: UUID) throws -> URL
    func removeClip(segmentID: UUID, workspaceID: UUID) throws
}

protocol SpeechPackageImportExporting: AnyObject {
    func exportPackage(_ package: SavedSpeechPackage) throws -> URL
    func importPackage(from url: URL) throws -> SavedSpeechPackage
}
