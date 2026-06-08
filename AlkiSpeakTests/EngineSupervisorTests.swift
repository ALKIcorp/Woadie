import XCTest
@testable import Woadie

final class EngineSupervisorTests: XCTestCase {
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
    func play(audioData: Data) throws {}
    func playToCompletion(audioData: Data) async throws {}
    func stop() {}
}

private final class FakeLocalSpeechSynthesizing: LocalSpeechSynthesizing {
    var voiceOptions: [VoiceOption] = [VoiceOption(id: "apple:test", label: "Apple Test", isLocal: true)]
    func refreshVoices() {}
    func speak(text: String, voiceID: String) throws {}
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
    static func test(engineSupervisor: EngineSupervising) -> AppDependencies {
        AppDependencies(
            engineSupervisor: engineSupervisor,
            generationService: FakeSpeechGenerating(),
            playbackCoordinator: FakePlaybackCoordinating(),
            localSpeechService: FakeLocalSpeechSynthesizing(),
            telemetryService: FakeTelemetryCapturing(),
            workspaceStore: FakeWorkspaceStore(),
            logStore: FakeLogStore(),
            clipStore: FakeClipStore(),
            packageStore: FakePackageStore()
        )
    }
}
