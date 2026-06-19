import AVFoundation
import XCTest
import SwiftData
@testable import Woadie

final class EngineSupervisorTests: XCTestCase {
    @available(macOS 26.0, *)
    func testGlassSurfacesAlwaysUseActiveMaterialAppearance() {
        XCTAssertEqual(GlassActivityPolicy.materialAppearance, .active)
    }

    func testWindowChromeIsNotReappliedDuringActivationChanges() {
        XCTAssertFalse(WindowChromePolicy.reappliesDuringActivationChanges)
    }

    func testAppearanceDefaultsToSystemAndPersistsSelection() {
        let suiteName = "AppearanceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppAppearance.load(from: defaults), .system)

        AppAppearance.dark.save(to: defaults)

        XCTAssertEqual(AppAppearance.load(from: defaults), .dark)
    }

    @MainActor
    func testSpeechEntryArchiveRoundTripCopiesAudioAndPreservesMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = support.appendingPathComponent("Woadie/Clips/source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceAudio = sourceDirectory.appendingPathComponent("clip.wav")
        try Data("audio".utf8).write(to: sourceAudio)

        let entry = SpeechEntry(
            textContent: "Archive me",
            voice: "af_heart",
            segmentRelativePaths: ["Woadie/Clips/source/clip.wav"],
            segmentDurations: [1.25],
            totalDurationSeconds: 1.25,
            stats: QueryStats(
                tokenCount: 2,
                generationTimeSeconds: 0.5,
                fileSizeBytes: 5,
                characterCount: 10,
                segmentCount: 1,
                resourceBefore: .empty,
                resourceAfter: .empty
            )
        )
        let service = SpeechEntryArchiveService(fileManager: .default, applicationSupportDirectory: support)

        let exported = try service.export(entry: entry, to: exports)
        let imported = try service.importEntry(from: exported)

        XCTAssertEqual(imported.textContent, entry.textContent)
        XCTAssertEqual(imported.voice, entry.voice)
        XCTAssertEqual(imported.segmentDurations, [1.25])
        XCTAssertEqual(imported.stats.characterCount, 10)
        XCTAssertEqual(imported.segmentRelativePaths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(imported.segmentRelativePaths[0]).path))
    }

    @MainActor
    func testSpeechEntryArchiveRejectsMissingSegmentBeforeImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let archive = root.appendingPathComponent("SpeechExport_Test", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = SpeechEntryArchiveManifest(
            id: UUID(),
            createdAt: Date(),
            textContent: "Missing",
            voice: "af_heart",
            model: "Kokoro",
            audioPaths: ["segment_000.wav"],
            segmentDurations: [1],
            totalDurationSeconds: 1,
            stats: .empty,
            appMode: .pro
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
        let service = SpeechEntryArchiveService(fileManager: .default, applicationSupportDirectory: support)

        XCTAssertThrowsError(try service.importEntry(from: archive)) {
            XCTAssertEqual(($0 as? SpeechEntryArchiveError), .missingAudioFile("segment_000.wav"))
        }
    }

    func testEngineErrorDescriptionsAreHumanReadable() {
        XCTAssertEqual(EngineError.exitCode(9).errorDescription, "Kokoro exited unexpectedly with code 9.")
        XCTAssertEqual(EngineError.portConflict.errorDescription, "Port 7777 is already in use by another process.")
        XCTAssertEqual(EngineError.venvMissing.errorDescription, "The Kokoro Python virtual environment is missing.")
    }

    func testEngineStateProvidesDescriptiveStatusText() {
        XCTAssertEqual(EngineState.starting.statusText, "Starting Engine…")
        XCTAssertEqual(EngineState.ready.statusText, "Engine Ready")
        XCTAssertEqual(EngineState.degraded(reason: "health check timed out").statusText, "Degraded — health check timed out")
        XCTAssertEqual(EngineState.unreachable.statusText, "Cannot reach localhost:7777")
        XCTAssertEqual(
            EngineState.stopped(error: .exitCode(2)).statusText,
            "Engine Stopped — Kokoro exited unexpectedly with code 2."
        )
    }

    func testTTSRequestTimeoutIsThreeMinutes() {
        XCTAssertEqual(AppConfig.requestTimeoutSeconds, 180)
    }

    func testSentenceBatcherKeepsShortInputWhole() {
        XCTAssertEqual(TextBatcher.segments(for: "Short text."), ["Short text."])
    }

    func testSentenceBatcherSplitsAtSentenceBoundaryAfterTarget() {
        let first = String(repeating: "A", count: 205) + "."
        let second = String(repeating: "B", count: 80) + "."

        XCTAssertEqual(TextBatcher.segments(for: "\(first) \(second)"), [first, second])
    }

    func testSentenceBatcherDoesNotSplitDecimalsAbbreviationsOrEllipsis() {
        let prefix = String(repeating: "A", count: 195)
        let text = "\(prefix) Dr. Smith measured 3.14 units... Then the final sentence ends here. Next sentence."
        let segments = TextBatcher.segments(for: text)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].contains("Dr. Smith"))
        XCTAssertTrue(segments[0].contains("3.14 units..."))
        XCTAssertTrue(segments[0].hasSuffix("here."))
    }

    func testSentenceBatcherHardCutsAt250WhenNoBoundaryExistsBy300() {
        let text = String(repeating: "x", count: 620)
        let segments = TextBatcher.segments(for: text)

        XCTAssertEqual(segments.map(\.count), [250, 250, 120])
    }

    func testRequestPolicyNeverCreatesSegmentOver250Characters() {
        let segments = EngineRequestPolicy.live.segments(for: String(repeating: "Long text without punctuation ", count: 40))

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 250 })
    }

    func testTTSQueueProcessesStrictlySequentiallyAndPublishesReadyURLs() async {
        let queue = TTSQueue()
        await queue.enqueue(["One.", "Two.", "Three."])
        let recorder = QueueRecorder()

        await queue.process(
            generate: { segment in
                await recorder.started(segment.index)
                try? await Task.sleep(nanoseconds: 10_000_000)
                await recorder.finished(segment.index)
                return GeneratedSegment(
                    audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"),
                    durationSeconds: nil
                )
            },
            onReady: { segment in
                await recorder.ready(segment.index)
            }
        )

        let events = await recorder.events
        XCTAssertEqual(
            events,
            ["start-0", "finish-0", "ready-0", "start-1", "finish-1", "ready-1", "start-2", "finish-2", "ready-2"]
        )
        let snapshot = await queue.snapshot()
        let isProcessing = await queue.processing
        XCTAssertFalse(isProcessing)
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertTrue(snapshot.allSatisfy {
            if case .ready = $0.status { return true }
            return false
        })
    }

    func testPlaybackTimelineUsesActualDurationsForBufferedSegmentsAndEstimatesTheRest() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 300, 150])
        timeline.markReady(index: 0, duration: 1.2)
        timeline.markReady(index: 1, duration: 2.4)

        XCTAssertEqual(timeline.bufferedDuration, 3.6, accuracy: 0.001)
        XCTAssertEqual(timeline.totalDuration, 4.6, accuracy: 0.001)
    }

    func testPlaybackTimelineResolvesGlobalTimeToSegmentLocalTime() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 150, 150])
        timeline.markReady(index: 0, duration: 1.25)
        timeline.markReady(index: 1, duration: 2.0)

        let target = timeline.location(for: 2.75)
        XCTAssertEqual(target?.segmentIndex, 1)
        XCTAssertEqual(target?.localTime ?? -1, 1.5, accuracy: 0.001)
    }

    func testPlaybackTimelineRejectsUnbufferedSeek() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 150])
        timeline.markReady(index: 0, duration: 1)

        XCTAssertNil(timeline.location(for: 1.01))
        XCTAssertNotNil(timeline.location(for: 1.0))
    }

    func testVoiceCyclingWrapsInBothDirections() {
        let voices = ["a", "b", "c"]

        XCTAssertEqual(VoiceCycler.next(current: "c", in: voices, offset: 1), "a")
        XCTAssertEqual(VoiceCycler.next(current: "a", in: voices, offset: -1), "c")
    }

    @MainActor
    func testSpeakCanRetryAfterPlaybackFailure() {
        let store = AppStore()
        store.composerText = "Try again"
        store.engineStatus = .running
        store.playback.state = .failed
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))

        XCTAssertTrue(model.canSpeak)
    }

    @MainActor
    func testPlaybackControlTogglesCachedAudioWithoutGeneratingAgain() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        store.playback.state = .playing
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                playbackCoordinator: playback
            )
        )

        model.togglePlayback()

        XCTAssertEqual(playback.toggleCallCount, 1)
    }

    @MainActor
    func testSelectedTextServiceProviderSpeaksPasteboardString() async {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "apple:test"
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech
            )
        )
        let provider = SelectedTextServiceProvider(model: model)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Read this from another app.", forType: .string)
        var serviceError: NSString?

        provider.speakSelection(pasteboard, userData: nil, error: &serviceError)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(serviceError)
        XCTAssertEqual(localSpeech.spokenTexts, ["Read this from another app."])
        XCTAssertEqual(store.composerText, "Read this from another app.")
    }

    @MainActor
    func testFinishedPlaybackRetainsClipForReplayAndUnblocksSpeak() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        store.composerText = "Generate another clip"
        store.engineStatus = .running
        store.playback = PlaybackSnapshot(
            state: .playing,
            activeJobID: UUID(),
            activeLogEntryID: UUID(),
            currentSegmentID: UUID(),
            elapsedTime: 1,
            duration: 1,
            bufferedDuration: 1,
            statusMessage: nil
        )
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                playbackCoordinator: playback
            )
        )

        playback.finish()

        XCTAssertEqual(store.playback.state, .stopped)
        XCTAssertNotNil(store.playback.activeLogEntryID)
        XCTAssertEqual(store.playback.elapsedTime, 0)
        XCTAssertTrue(model.canSpeak)
    }

    func testQueuePlaybackAppendsSegmentsAndPublishesCumulativeBuffer() throws {
        let firstURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.2)
        let secondURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.3)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let coordinator = AVAudioPlaybackCoordinator()
        var snapshots: [PlaybackTransportSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        coordinator.prepare(characterCounts: [30, 45])
        try coordinator.append(audioURL: firstURL, segmentID: UUID(), index: 0)
        try coordinator.append(audioURL: secondURL, segmentID: UUID(), index: 1)

        XCTAssertEqual(snapshots.last?.bufferedDuration ?? 0, 0.5, accuracy: 0.02)
        coordinator.stop()
    }

    func testQueuePlaybackRejectsInconsistentSegmentFormat() throws {
        let firstURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.1)
        let secondURL = try makeTestAudioFile(sampleRate: 44_100, duration: 0.1)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let coordinator = AVAudioPlaybackCoordinator()
        coordinator.prepare(characterCounts: [15, 15])
        try coordinator.append(audioURL: firstURL, segmentID: UUID(), index: 0)

        XCTAssertThrowsError(try coordinator.append(audioURL: secondURL, segmentID: UUID(), index: 1)) {
            XCTAssertEqual(($0 as? AlkiSpeakError)?.code, "playback.inconsistent-audio-format")
        }
        coordinator.stop()
    }

    private func makeTestAudioFile(sampleRate: Double, duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?.pointee {
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.04) * 0.1
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testStartupSuccessStateCanRepresentRunningEngine() {
        var summary = EngineHealthSummary.stopped
        summary.status = .running
        summary.pid = 42
        summary.startedAt = Date()
        summary.lastSuccessfulHealthCheckAt = Date()

        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.pid, 42)
        XCTAssertTrue(summary.status.isAvailableForRemoteSpeech)
    }

    func testStartupTimeoutCapturesStableDiagnosticFields() {
        let issue = EngineIssue(
            code: "engine.startup-timeout",
            title: "Engine Startup Timed Out",
            description: "The engine process started but did not become healthy.",
            probableCause: "Model loading is stuck or dependencies are missing.",
            subsystem: "engine.lifecycle",
            retryCount: 1,
            rawError: "deadline exceeded"
        )

        XCTAssertEqual(issue.code, "engine.startup-timeout")
        XCTAssertEqual(issue.subsystem, "engine.lifecycle")
        XCTAssertEqual(issue.retryCount, 1)
        XCTAssertEqual(issue.rawError, "deadline exceeded")
    }

    func testCrashDetectionStateSupportsControlledRestart() {
        var summary = EngineHealthSummary.stopped
        let issue = EngineIssue(
            code: "engine.unexpected-termination",
            title: "Engine Process Exited",
            description: "The local engine exited unexpectedly.",
            probableCause: "The server crashed or was killed externally.",
            subsystem: "engine.lifecycle",
            retryCount: 1
        )

        summary.status = .retrying
        summary.retryCount = 1
        summary.latestIssue = issue
        summary.recentIssues = [issue]

        XCTAssertEqual(summary.status, .retrying)
        XCTAssertEqual(summary.latestIssue?.code, "engine.unexpected-termination")
        XCTAssertLessThanOrEqual(summary.retryCount, AppConfig.maxEngineRestartAttempts)
    }

    func testShutdownOnAppTerminationStateIsStopped() {
        let supervisor = ProcessEngineSupervisor()

        supervisor.stop()

        XCTAssertEqual(supervisor.healthSummary.status, .stopped)
        XCTAssertNil(supervisor.processIdentifier)
        XCTAssertFalse(supervisor.isRunning)
    }

    func testLargeRequestIsReroutedIntoSegments() {
        let policy = EngineRequestPolicy(maxDirectCharacters: 20, maxSegmentCharacters: 12)
        let segments = policy.segments(for: "This is a long pasted request. It needs safe routing.")

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 250 })
    }

    func testDirectOversizedRequestIsRejectedBeforeNetworkUse() async {
        let service = KokoroSpeechGenerationService()
        let oversized = String(repeating: "A", count: AppConfig.maxDirectRequestCharacters + 1)

        do {
            _ = try await service.synthesize(text: oversized, voice: AppConfig.defaultVoice, jobID: UUID())
            XCTFail("Expected oversized direct request to fail before URLSession work.")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.oversized-direct-request")
            XCTAssertEqual(error.context["limit"], "\(AppConfig.maxDirectRequestCharacters)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testAppStartupDelegatesPortRecoveryToSupervisorWithoutShowingAlert() async {
        let supervisor = FakeEngineSupervisor()
        supervisor.portUsers = [123]
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(supervisor.startCalled)
        XCTAssertFalse(store.showPortInUseAlert)
        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }

    @MainActor
    func testStartEngineIgnoresDuplicateRequestWhileStarting() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        model.startEngine()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(supervisor.startCallCount, 1)
        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }

    @MainActor
    func testStopEngineIgnoresLateStartingCallback() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        model.stopEngine()

        var staleSummary = EngineHealthSummary.stopped
        staleSummary.status = .starting
        supervisor.emit(staleSummary)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.engineStatus, .stopped)
    }

    @MainActor
    func testStartEngineIgnoresLateStoppedCallbackWhileStartIsActive() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        supervisor.emit(.stopped)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }
}

private actor QueueRecorder {
    private(set) var events: [String] = []

    func started(_ index: Int) {
        events.append("start-\(index)")
    }

    func finished(_ index: Int) {
        events.append("finish-\(index)")
    }

    func ready(_ index: Int) {
        events.append("ready-\(index)")
    }
}

private final class FakeEngineSupervisor: EngineSupervising {
    var isRunning = false
    var processIdentifier: Int32?
    var engineState: EngineState = .unreachable
    var healthSummary: EngineHealthSummary = .stopped
    var onEngineStateChanged: ((EngineState) -> Void)?
    var onHealthChanged: ((EngineHealthSummary) -> Void)?
    var onIssue: ((EngineIssue) -> Void)?
    var portUsers: [Int32] = []
    var startCalled = false
    var startCallCount = 0

    func start() throws {
        startCalled = true
        startCallCount += 1
    }

    func restart() throws {
        startCalled = true
        startCallCount += 1
    }

    func emit(_ summary: EngineHealthSummary) {
        healthSummary = summary
        processIdentifier = summary.pid
        isRunning = summary.pid != nil
        onHealthChanged?(summary)
    }

    func stop() {}
    func noteRequestStarted(jobID: UUID) {}
    func noteRequestFinished(jobID: UUID) {}
    func findListeningPidsOnEnginePort() -> [Int32] { portUsers }
    func terminatePortUsers(_ pids: [Int32]) async {}
}

private final class FakeSpeechGenerating: SpeechGenerating {
    func checkHealth() async -> Bool { false }
    func fetchVoices() async throws -> [String] { [] }
    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        SpeechGenerationResult(audioData: Data(), latencyMs: nil, charCount: text.count)
    }
}

private final class FakePlaybackCoordinating: PlaybackCoordinating {
    var onSnapshotChanged: ((PlaybackTransportSnapshot) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var toggleCallCount = 0
    func prepare(characterCounts: [Int]) {}
    func append(audioURL: URL, segmentID: UUID, index: Int) throws {}
    func finishEnqueuing() {}
    func seek(to globalTime: TimeInterval) -> Bool { false }
    func togglePlayback() { toggleCallCount += 1 }
    func stop() {}

    func finish() {
        onFinished?()
    }
}

private final class FakeLocalSpeechSynthesizing: LocalSpeechSynthesizing {
    var voiceOptions: [VoiceOption] = [VoiceOption(id: "apple:test", label: "Apple Test", isLocal: true)]
    private(set) var spokenTexts: [String] = []
    func refreshVoices() {}
    func speak(text: String, voiceID: String) throws {
        spokenTexts.append(text)
    }
    func stop() {}
}

private final class FakeTelemetryCapturing: TelemetryCapturing {
    func capture(engineProcessID: Int32?) -> ResourceSnapshot { .empty }
}

private final class FakeWorkspaceStore: ActiveWorkspacePersisting {
    func loadActiveWorkspace() throws -> WorkspaceSession? { nil }
    func saveActiveWorkspace(_ workspace: WorkspaceSession) throws {}
}

private final class FakeLogStore: SavedLogPersisting {
    func loadLogs(for workspaceID: UUID) throws -> [SavedLogEntry] { [] }
    func saveLog(_ entry: SavedLogEntry, workspaceID: UUID) throws {}
    func replaceLogs(_ entries: [SavedLogEntry], workspaceID: UUID) throws {}
}

private final class FakeClipStore: SegmentedClipStoring {
    func writeClip(data: Data, segmentID: UUID, workspaceID: UUID) throws -> URL {
        URL(fileURLWithPath: "/tmp/\(segmentID.uuidString).wav")
    }

    func removeClip(segmentID: UUID, workspaceID: UUID) throws {}
}

private final class FakePackageStore: SpeechPackageImportExporting {
    func exportPackage(_ package: SavedSpeechPackage) throws -> URL {
        URL(fileURLWithPath: "/tmp/\(package.id.uuidString).alkispeak")
    }

    func importPackage(from url: URL) throws -> SavedSpeechPackage {
        SavedSpeechPackage(name: "Test", workspaceID: UUID(), jobs: [], logEntries: [])
    }
}

@MainActor
private extension AppDependencies {
    static func test(
        engineSupervisor: EngineSupervising,
        playbackCoordinator: PlaybackCoordinating = FakePlaybackCoordinating(),
        localSpeechService: LocalSpeechSynthesizing = FakeLocalSpeechSynthesizing()
    ) -> AppDependencies {
        AppDependencies(
            engineSupervisor: engineSupervisor,
            generationService: FakeSpeechGenerating(),
            playbackCoordinator: playbackCoordinator,
            localSpeechService: localSpeechService,
            telemetryService: FakeTelemetryCapturing(),
            workspaceStore: FakeWorkspaceStore(),
            logStore: FakeLogStore(),
            clipStore: FakeClipStore(),
            packageStore: FakePackageStore(),
            speechEntryStore: try! SpeechEntryStore(
                container: ModelContainer(
                    for: SpeechEntry.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            ),
            speechEntryArchiveService: SpeechEntryArchiveService()
        )
    }
}
