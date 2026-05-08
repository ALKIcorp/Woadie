import XCTest
@testable import Woadie

final class EngineSupervisorTests: XCTestCase {
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
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 12 })
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
    func testAppStartupDelegatesPortRecoveryToSupervisorWithoutShowingAlert() {
        let supervisor = FakeEngineSupervisor()
        supervisor.portUsers = [123]
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()

        XCTAssertTrue(supervisor.startCalled)
        XCTAssertFalse(store.showPortInUseAlert)
        XCTAssertEqual(store.engineStatus, .starting)
    }
}

private final class FakeEngineSupervisor: EngineSupervising {
    var isRunning = false
    var processIdentifier: Int32?
    var healthSummary: EngineHealthSummary = .stopped
    var onHealthChanged: ((EngineHealthSummary) -> Void)?
    var onIssue: ((EngineIssue) -> Void)?
    var portUsers: [Int32] = []
    var startCalled = false

    func start() throws {
        startCalled = true
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
