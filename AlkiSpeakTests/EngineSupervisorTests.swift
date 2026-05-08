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
}
