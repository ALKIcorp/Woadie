import AppKit
import AVFoundation
import Foundation

/// The speech log and everything that reads or writes saved clips: import and
/// export, saving or sharing what's playing, replaying an entry, and the
/// storage inventory. `AppModel` forwards to it so views keep one entry point.
@MainActor
final class HistoryController {
    private let store: AppStore
    private let dependencies: AppDependencies
    private let record: (AlkiSpeakError) -> Void

    init(store: AppStore, dependencies: AppDependencies, record: @escaping (AlkiSpeakError) -> Void) {
        self.store = store
        self.dependencies = dependencies
        self.record = record
    }

    // MARK: Log entries

    func loadSpeechEntries() {
        do {
            _ = try dependencies.speechEntryStore.migrateLegacyHistoryIfNeeded()
            store.speechEntries = try dependencies.speechEntryStore.fetchAll()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.load", title: "Log Load Failed", message: error.localizedDescription, recoverySuggestion: "The legacy data was preserved. Restart and try again."))
        }
    }

    func exportEntry(_ entry: SpeechEntry) {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Location"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let exportedURL = try dependencies.speechEntryArchiveService.export(entry: entry, to: destination)
            store.userMessage = "Exported \(exportedURL.lastPathComponent)"
        } catch {
            record(AlkiSpeakError(
                code: "archive.export",
                title: "Export Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Choose another destination and try again."
            ))
        }
    }

    func importSpeechEntry() {
        let panel = NSOpenPanel()
        panel.title = "Import Speech Entry"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let entry = try dependencies.speechEntryArchiveService.importEntry(from: source)
            try dependencies.speechEntryStore.insert(entry)
            loadSpeechEntries()
            store.selectedLogEntryID = entry.id
            store.appMode = .pro
            store.userMessage = "Imported \(source.lastPathComponent)"
        } catch {
            record(AlkiSpeakError(
                code: "archive.import",
                title: "Import Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Select a complete AlkiSpeak export folder."
            ))
        }
    }

    func delete(_ entry: SpeechEntry) {
        do {
            try dependencies.speechEntryStore.delete(entry)
            if store.selectedLogEntryID == entry.id {
                store.selectedLogEntryID = nil
            }
            loadSpeechEntries()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.delete", title: "Delete Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    func rename(_ entry: SpeechEntry, to displayName: String?) {
        do {
            try dependencies.speechEntryStore.rename(entry, to: displayName)
            loadSpeechEntries()
        } catch {
            record(AlkiSpeakError(code: "persistence.log.rename", title: "Rename Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    /// Queues a saved entry's clips on the player, ready to play, as the
    /// active job. The caller stops whatever was playing first.
    func loadForPlayback(_ entry: SpeechEntry) {
        let urls = entry.segmentRelativePaths.compactMap { try? dependencies.speechEntryStore.absoluteURL(for: $0) }
        let segments = urls.enumerated().map { index, url in
            SpeechSegment(index: index, text: "", status: .ready, audioURL: url)
        }
        let job = SpeechJob(text: entry.textContent, voiceID: entry.voice, segments: segments, status: .completed, logEntryID: entry.id)
        store.speechJobs.insert(job, at: 0)
        dependencies.playbackCoordinator.prepare(characterCounts: Array(repeating: 1, count: urls.count))
        for (index, url) in urls.enumerated() {
            try? dependencies.playbackCoordinator.append(audioURL: url, segmentID: segments[index].id, index: index)
        }
        dependencies.playbackCoordinator.finishEnqueuing()
        store.playback.activeJobID = job.id
        store.playback.activeLogEntryID = entry.id
        store.playback.duration = entry.totalDurationSeconds
        store.playback.bufferedDuration = entry.totalDurationSeconds
    }

    /// Saves a finished job to the log, unless it's already there.
    func saveEntry(for job: SpeechJob, generationSeconds: Double, resourceBefore: SystemResourceSnapshot) {
        guard !store.speechEntries.contains(where: { $0.id == job.logEntryID }) else { return }
        let readySegments = job.segments.filter { $0.audioURL != nil }
        let urls = readySegments.compactMap(\.audioURL)
        let knownDurations = readySegments.compactMap(\.durationSeconds)
        let paths = urls.compactMap { try? dependencies.speechEntryStore.relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        let fileSize = urls.reduce(Int64(0)) {
            $0 + Int64((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        Task {
            let after = await SystemResourceMonitor.shared.snapshot()
            // Durations come from playback; only parse files it never opened.
            let durations = knownDurations.count == urls.count ? knownDurations : await Self.audioDurations(urls)
            let entry = SpeechEntry(
                id: job.logEntryID ?? UUID(),
                textContent: job.text,
                voice: job.voiceID,
                segmentRelativePaths: paths,
                segmentDurations: durations,
                totalDurationSeconds: durations.reduce(0, +),
                stats: QueryStats(
                    tokenCount: max(1, job.text.count / 4),
                    generationTimeSeconds: abs(generationSeconds),
                    fileSizeBytes: fileSize,
                    characterCount: job.text.count,
                    segmentCount: job.segments.count,
                    resourceBefore: resourceBefore,
                    resourceAfter: after,
                    resourceUsage: store.lastQueryResourceUsage
                ),
                appMode: .pro
            )
            do {
                try dependencies.speechEntryStore.insert(entry)
                loadSpeechEntries()
            } catch {
                record(AlkiSpeakError(code: "persistence.log.save", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try Add to Log again."))
            }
        }
    }

    private static func audioDurations(_ urls: [URL]) async -> [Double] {
        var values: [Double] = []
        for url in urls {
            values.append((try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0)
        }
        return values
    }

    // MARK: Saving and sharing what's playing

    /// The playing job's clips, when every segment has audio.
    private func completeActiveJob() -> SpeechJob? {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID }),
              job.status != .failed,
              !job.segments.isEmpty,
              job.segments.allSatisfy({ $0.audioURL != nil })
        else { return nil }
        return job
    }

    private func activeJobClipURLs() -> [URL] {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return [] }
        return job.segments.compactMap(\.audioURL)
    }

    /// Writes the playing clip to Downloads; `onSaved` runs after it lands.
    func savePlaybackToDownloads(onSaved: @escaping (SpeechJob) -> Void) {
        guard let job = completeActiveJob() else { return }
        let urls = job.segments.compactMap(\.audioURL)
        guard !urls.isEmpty,
              let downloads = try? FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
              )
        else { return }
        let destination = downloads.appendingPathComponent(Self.defaultClipFilename())

        Task {
            do {
                let savedURL = try await Self.exportPlaybackAudio(urls: urls, to: destination)
                onSaved(job)
                store.userMessage = "Saved \(savedURL.lastPathComponent) to Downloads."
            } catch {
                record(AlkiSpeakError(code: "playback.savedefault", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try Save As instead."))
            }
        }
    }

    func savePlaybackAs() {
        let urls = activeJobClipURLs()
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.title = "Save Audio As..."
            panel.prompt = "Save"
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = Self.defaultClipFilename()

            guard panel.runModal() == .OK, let destination = panel.url else { return }

            Task {
                do {
                    let savedURL = try await Self.exportPlaybackAudio(urls: urls, to: destination)
                    self.store.userMessage = "Saved \(savedURL.lastPathComponent)"
                } catch {
                    self.record(AlkiSpeakError(code: "playback.saveas", title: "Save Failed", message: error.localizedDescription, recoverySuggestion: "Try a different location."))
                }
            }
        }
    }

    func sharePlaybackAudio(from anchorRect: CGRect) {
        let urls = activeJobClipURLs()
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            guard let mainWindow = NSApp.windows.first(where: { $0.isKeyWindow }),
                  let contentView = mainWindow.contentView
            else { return }
            let picker = NSSharingServicePicker(items: urls)
            let rect: NSRect = anchorRect == .zero
                ? contentView.bounds
                : NSRect(
                    x: anchorRect.minX,
                    y: contentView.bounds.height - anchorRect.maxY,
                    width: anchorRect.width,
                    height: anchorRect.height
                )
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    private static func defaultClipFilename() -> String {
        "AlkiSpeak_Clip_\(Int(Date().timeIntervalSince1970)).wav"
    }

    private static func exportPlaybackAudio(urls: [URL], to destination: URL) async throws -> URL {
        if urls.count == 1 {
            try FileManager.default.copyItem(at: urls[0], to: destination)
            return destination
        }

        let composition = AVMutableComposition()
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
                try compositionAudioTrack?.insertTimeRange(timeRange, of: track, at: insertTime)
                insertTime = CMTimeAdd(insertTime, timeRange.duration)
            }
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            try FileManager.default.copyItem(at: urls[0], to: destination)
            return destination
        }
        let outputURL = destination.deletingPathExtension().appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }

    // MARK: Storage inventory

    var clipInventory: [ClipInventoryItem] {
        ClipInventory.items(from: store.speechEntries)
    }

    func cleanupOrphanClips() {
        do {
            let removed = try dependencies.speechEntryStore.cleanupOrphanClips()
            store.userMessage = removed == 0 ? "No orphaned clips found." : "Removed \(removed) orphaned clip\(removed == 1 ? "" : "s")."
        } catch {
            record(AlkiSpeakError(code: "persistence.clips.cleanup", title: "Cleanup Failed", message: error.localizedDescription, recoverySuggestion: "Try again."))
        }
    }

    func openClipsFolder() {
        guard let url = try? dependencies.speechEntryStore.clipsRootURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showClipInFinder(_ item: ClipInventoryItem) {
        let urls = item.segmentRelativePaths.compactMap { try? dependencies.speechEntryStore.absoluteURL(for: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyClipText(_ item: ClipInventoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    func deleteClip(_ item: ClipInventoryItem) {
        guard let entry = store.speechEntries.first(where: { $0.id == item.id }) else { return }
        delete(entry)
    }
}
