import Foundation

protocol EngineSupervising: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32? { get }
    var engineState: EngineState { get }
    var healthSummary: EngineHealthSummary { get }
    var onEngineStateChanged: ((EngineState) -> Void)? { get set }
    var onHealthChanged: ((EngineHealthSummary) -> Void)? { get set }
    var onIssue: ((EngineIssue) -> Void)? { get set }
    func start() throws
    func restart() throws
    func stop()
    func noteRequestStarted(jobID: UUID)
    func noteRequestFinished(jobID: UUID)
    func findListeningPidsOnEnginePort() -> [Int32]
    func terminatePortUsers(_ pids: [Int32]) async
}

protocol SpeechGenerating: AnyObject {
    func checkHealth() async -> Bool
    func fetchVoices() async throws -> [String]
    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult
}

struct SpeechGenerationResult: Hashable {
    let audioData: Data
    let latencyMs: Int?
    let charCount: Int?
}

protocol SpeechQueueing: AnyObject {
    func enqueue(text: String, voiceID: String) -> SpeechJob
    func cancel(jobID: UUID)
}

protocol PlaybackCoordinating: AnyObject {
    var onSnapshotChanged: ((PlaybackTransportSnapshot) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func prepare(characterCounts: [Int])
    func append(audioURL: URL, segmentID: UUID, index: Int) throws
    func finishEnqueuing()
    func seek(to globalTime: TimeInterval) -> Bool
    func stop()
}

struct PlaybackTransportSnapshot {
    var state: PlaybackSnapshot.State
    var currentSegmentID: UUID?
    var elapsedTime: TimeInterval
    var bufferedDuration: TimeInterval
    var totalDuration: TimeInterval
    var fftMagnitudes: [Float]
}

protocol LocalSpeechSynthesizing: AnyObject {
    var voiceOptions: [VoiceOption] { get }
    func refreshVoices()
    func speak(text: String, voiceID: String) throws
    func stop()
}

protocol TelemetryCapturing: AnyObject {
    func capture(engineProcessID: Int32?) -> ResourceSnapshot
}
