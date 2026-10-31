import Foundation

/// Performance diagnostics and per-request resource sampling: which phase the
/// app is in, the idle sampler, and the timing and CPU/RAM figures saved with
/// each log entry. `baseContext` supplies the app state stamped on every event.
@MainActor
final class SpeechDiagnostics {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let baseContext: () -> [String: String]

    private var phase: PerformanceDiagnosticPhase = .idle
    private var activeJobID: UUID?
    private var idleSamplingTask: Task<Void, Never>?

    private var queryStartedAt: ContinuousClock.Instant?
    private(set) var resourceBefore: SystemResourceSnapshot = .empty
    private var resourceUsageAccumulator = QueryResourceUsageAccumulator()
    private var resourceSamplingGeneration: UInt64 = 0
    private var resourceSamplingTask: Task<Void, Never>?

    init(dependencies: AppDependencies, store: AppStore, baseContext: @escaping () -> [String: String]) {
        self.dependencies = dependencies
        self.store = store
        self.baseContext = baseContext
    }

    deinit {
        idleSamplingTask?.cancel()
        resourceSamplingTask?.cancel()
    }

    var isResourceSamplingActive: Bool { resourceSamplingTask != nil }

    /// Seconds since the current request started, or 0 without one.
    var generationSeconds: Double {
        let elapsed = queryStartedAt.map { $0.duration(to: ContinuousClock.now) } ?? .zero
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    static func voiceSource(for voiceID: String) -> String {
        if voiceID.hasPrefix("apple:") { return "apple" }
        if voiceID.hasPrefix(EdgeSpeechGenerationService.idPrefix) { return "edge" }
        if CloudSpeechGenerationService.isCloudVoice(voiceID) { return "cloud" }
        if NativeKokoroSpeechService.isNativeKokoroVoice(voiceID) { return "kokoro-native" }
        return "kokoro"
    }

    // MARK: Session and markers

    func startSession() {
        dependencies.performanceDiagnostics.startSession(
            context: [
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                "diagnosticLog": dependencies.performanceDiagnostics.logURL.path,
                "diagnosticSummary": dependencies.performanceDiagnostics.summaryURL.path
            ]
        )
        recordMarker(phase: .idle, message: "AppModel initialized.", jobID: nil)
    }

    func startIdleSampling() {
        idleSamplingTask?.cancel()
        let interval = UInt64(AppConfig.performanceDiagnosticIdleSampleIntervalSeconds * 1_000_000_000)
        idleSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let system = await SystemResourceMonitor.shared.snapshot()
                await MainActor.run {
                    self?.recordSample(system: system, context: ["source": "app-sampler"])
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// A one-off event in the given phase, for the given job (or none).
    func recordMarker(phase markerPhase: PerformanceDiagnosticPhase, message: String, jobID: UUID?, context extra: [String: String] = [:]) {
        dependencies.performanceDiagnostics.recordMarker(
            phase: markerPhase,
            message: message,
            jobID: jobID,
            context: context(extra)
        )
    }

    /// A one-off event for the current phase and job, optionally overriding the phase.
    func recordMarkerForActiveJob(phase markerPhase: PerformanceDiagnosticPhase? = nil, message: String, context extra: [String: String] = [:]) {
        recordMarker(phase: markerPhase ?? phase, message: message, jobID: activeJobID, context: extra)
    }

    func setPhase(_ newPhase: PerformanceDiagnosticPhase, jobID: UUID?, message: String, context extra: [String: String] = [:]) {
        phase = newPhase
        activeJobID = jobID
        recordMarker(phase: newPhase, message: message, jobID: jobID, context: extra)
    }

    func finishJob(message: String) {
        guard activeJobID != nil || phase != .idle else { return }
        recordMarkerForActiveJob(phase: .idle, message: message)
        phase = .idle
        activeJobID = nil
    }

    private func recordSample(system: SystemResourceSnapshot, context extra: [String: String]) {
        let process = dependencies.telemetryService.capture(
            engineProcessID: dependencies.engineSupervisor.processIdentifier
        )
        dependencies.performanceDiagnostics.recordSample(
            phase: phase,
            jobID: activeJobID,
            system: system,
            process: process,
            context: context(extra)
        )
    }

    private func context(_ extra: [String: String]) -> [String: String] {
        var context = baseContext()
        extra.forEach { context[$0.key] = $0.value }
        return context
    }

    // MARK: Per-request sampling

    /// Starts timing a request and sampling CPU/RAM once a second until
    /// `finishResourceSampling`.
    func startQuery() {
        queryStartedAt = ContinuousClock.now
        Task { resourceBefore = await SystemResourceMonitor.shared.snapshot() }
        resourceSamplingTask?.cancel()
        resourceSamplingGeneration &+= 1
        let generation = resourceSamplingGeneration
        resourceUsageAccumulator.reset()
        resourceSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await SystemResourceMonitor.shared.snapshot()
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self, self.resourceSamplingGeneration == generation else { return }
                    self.resourceUsageAccumulator.record(snapshot)
                    self.recordSample(system: snapshot, context: ["source": "query-sampler"])
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @discardableResult
    func finishResourceSampling() -> QueryResourceUsage? {
        resourceSamplingTask?.cancel()
        resourceSamplingTask = nil
        resourceSamplingGeneration &+= 1
        guard let usage = resourceUsageAccumulator.usage else { return nil }
        resourceUsageAccumulator.reset()
        store.lastQueryResourceUsage = usage
        recordMarkerForActiveJob(message: "Query resource sampling finished.", context: [
            "sampleCount": "\(usage.sampleCount)",
            "averageCPUPercent": String(format: "%.1f", usage.averageCPUPercent),
            "averageRAMUsedMB": String(format: "%.0f", usage.averageRAMUsedMB),
            "peakRAMUsedMB": String(format: "%.0f", usage.peakRAMUsedMB)
        ])
        return usage
    }
}
