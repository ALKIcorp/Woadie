import Foundation

/// The Python Kokoro engine's lifecycle: starting it and waiting until it
/// answers, stopping and restarting it, putting it to sleep when unused and
/// waking it for a request, and turning supervisor health reports into
/// engine status in the store.
@MainActor
final class KokoroEngineController {
    private let store: AppStore
    private let dependencies: AppDependencies
    private let diagnostics: SpeechDiagnostics
    /// Whether the selected voice runs on this engine.
    private let selectedVoiceUsesEngine: () -> Bool
    private let fetchVoices: () async -> Void
    private let stopPlayback: () -> Void
    private let trace: (String) -> Void

    private var startTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    /// Stopped for being idle (or never started for this voice), as opposed
    /// to stopped by the user.
    private(set) var isSleeping = false

    /// How long the engine may sit unused before it stops, freeing PyTorch
    /// and the model. Shorter when no Kokoro voice is selected.
    static let idleTimeout: TimeInterval = 3 * 60
    static let unselectedTimeout: TimeInterval = 30

    init(
        store: AppStore,
        dependencies: AppDependencies,
        diagnostics: SpeechDiagnostics,
        selectedVoiceUsesEngine: @escaping () -> Bool,
        fetchVoices: @escaping () async -> Void,
        stopPlayback: @escaping () -> Void,
        trace: @escaping (String) -> Void
    ) {
        self.store = store
        self.dependencies = dependencies
        self.diagnostics = diagnostics
        self.selectedVoiceUsesEngine = selectedVoiceUsesEngine
        self.fetchVoices = fetchVoices
        self.stopPlayback = stopPlayback
        self.trace = trace
    }

    private var status: EngineStatus { store.engineStatus }

    var isStarting: Bool { startTask != nil }

    /// The engine is off because the selected voice doesn't use it, or it
    /// went unused long enough to be stopped. It starts again when a Kokoro
    /// voice is picked or Generate is pressed.
    var isOnStandby: Bool {
        status == .stopped && startTask == nil && (!selectedVoiceUsesEngine() || isSleeping)
    }

    // MARK: Sleep and wake

    func scheduleIdleStop() {
        idleTask?.cancel()
        guard !AppConfig.isRunningUnitTests else { return }
        let timeout = selectedVoiceUsesEngine() ? Self.idleTimeout : Self.unselectedTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopIfIdle()
        }
    }

    func cancelIdleStop() {
        idleTask?.cancel()
    }

    /// Marks a stopped engine as asleep, so the next request starts it.
    func markSleeping() {
        isSleeping = true
    }

    /// Starts the engine after an idle stop and waits until it answers.
    func wake() async throws {
        guard !status.isAvailableForRemoteSpeech else { return }
        store.playback.statusMessage = "Starting Kokoro…"
        defer { store.playback.statusMessage = nil }
        if startTask == nil {
            start()
        }
        await startTask?.value
        try Task.checkCancellation()
        guard status.isAvailableForRemoteSpeech else {
            throw AlkiSpeakError.engine(
                code: "wake-failed",
                title: "Kokoro Didn't Start",
                message: "The Kokoro engine didn't come back up for this request.",
                recoverySuggestion: "Press Generate again, or restart the engine."
            )
        }
    }

    /// Stops the engine to free its memory (a native Kokoro voice took over,
    /// or it went unused), unless it is still generating. Finished clips play
    /// without it.
    func stopIfIdle() {
        let supervisor = dependencies.engineSupervisor
        guard status.isProcessExpectedAlive || supervisor.isRunning,
              supervisor.healthSummary.activeJobID == nil
        else { return }
        trace("stopping idle Python Kokoro engine")
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        idleTask?.cancel()
        supervisor.stop()
        isSleeping = true
        store.engineStatus = .stopped
    }

    // MARK: Start, stop, restart

    func start() {
        trace("startEngine requested currentStatus=\(status.rawValue) supervisorRunning=\(dependencies.engineSupervisor.isRunning) pid=\(dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil")")
        guard !status.isProcessExpectedAlive && !dependencies.engineSupervisor.isRunning else {
            trace("startEngine ignored because engine is already expected alive or supervisor reports running")
            return
        }
        diagnostics.recordMarker(phase: .engineStart, message: "Engine start requested.", jobID: nil)
        startTask?.cancel()
        startGeneration &+= 1
        let generation = startGeneration
        isSleeping = false
        store.clearErrorMessage()
        store.engineStatus = .starting
        trace("engineStatus set to starting")

        let supervisor = dependencies.engineSupervisor
        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.startGeneration == generation {
                    self.startTask = nil
                }
            }
            do {
                trace("detached supervisor.start beginning")
                try await Task.detached(priority: .userInitiated) {
                    try supervisor.start()
                }.value
                guard self.startGeneration == generation, !Task.isCancelled else {
                    trace("supervisor.start completed after cancellation; ignoring result")
                    return
                }
                trace("detached supervisor.start completed pid=\(supervisor.processIdentifier.map(String.init) ?? "nil") healthStatus=\(supervisor.healthSummary.status.rawValue)")
                refreshTelemetry()
            } catch {
                guard self.startGeneration == generation else {
                    trace("supervisor.start error belongs to an old start generation; ignoring error=\(String(describing: error))")
                    return
                }
                if error is CancellationError || Task.isCancelled {
                    trace("supervisor.start cancelled")
                    if store.engineStatus == .starting || store.engineStatus == .retrying {
                        store.engineStatus = .stopped
                    }
                    return
                }
                trace("supervisor.start failed error=\(String(describing: error))")
                if let appError = error as? AlkiSpeakError, appError.code == "engine.port-in-use" {
                    let pids = await Task.detached(priority: .userInitiated) {
                        supervisor.findListeningPidsOnEnginePort()
                    }.value
                    trace("port-in-use surfaced pids=\(pids.map(String.init).joined(separator: ","))")
                    store.portInUsePids = pids
                    store.showPortInUseAlert = true
                    store.record(appError)
                } else {
                    store.record(
                        .engine(
                            code: "start-failed",
                            title: "Engine Start Failed",
                            message: "Failed to start the speech engine.",
                            recoverySuggestion: "Verify the Kokoro checkout and virtual environment path, then try again.",
                            underlyingError: error
                        )
                    )
                }
                store.engineStatus = .failed
                trace("engineStatus set to failed after start error")
                return
            }
            // Poll health at 250 ms — mirrors the original waitForHealth() pattern from
            // 999d859 — so both auto-launch on init AND manual stop→start transitions
            // snap the UI out of "Starting..." as soon as the engine is reachable.
            await waitUntilReady(generation: generation)
        }
    }

    func stop() {
        trace("stopEngine requested currentStatus=\(status.rawValue) supervisorRunning=\(dependencies.engineSupervisor.isRunning) pid=\(dependencies.engineSupervisor.processIdentifier.map(String.init) ?? "nil")")
        diagnostics.recordMarkerForActiveJob(phase: .engineStop, message: "Engine stop requested.")
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        store.clearErrorMessage()
        stopPlayback()
        idleTask?.cancel()
        isSleeping = false
        dependencies.engineSupervisor.stop()
        store.engineStatus = .stopped
        trace("engineStatus set to stopped")
        refreshTelemetry()
    }

    func restart() {
        trace("restartEngine requested")
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        stopPlayback()
        store.clearErrorMessage()
        store.engineStatus = .starting
        let generation = startGeneration

        let supervisor = dependencies.engineSupervisor
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try supervisor.restart()
                }.value
                await waitUntilReady(generation: generation)
            } catch {
                store.engineStatus = .failed
                store.record(Self.normalizeEngineError(error))
            }
        }
    }

    func toggle() {
        trace("toggleEngine status=\(status.rawValue) processExpectedAlive=\(status.isProcessExpectedAlive) supervisorRunning=\(dependencies.engineSupervisor.isRunning)")
        if status.isProcessExpectedAlive || dependencies.engineSupervisor.isRunning {
            stop()
        } else {
            start()
        }
    }

    /// Frees the engine port from whatever else is listening on it, then starts.
    func takeOverPortAndStart() {
        Task {
            await dependencies.engineSupervisor.terminatePortUsers(store.portInUsePids)
            store.portInUsePids = []
            store.showPortInUseAlert = false
            start()
        }
    }

    func refreshTelemetry() {
        store.dashboardTelemetry.resourceSnapshot = dependencies.telemetryService.capture(
            engineProcessID: dependencies.engineSupervisor.processIdentifier
        )
    }

    private func waitUntilReady(generation: UInt64) async {
        let deadline = Date().addingTimeInterval(min(AppConfig.engineStartupTimeoutSeconds, 120))
        var attempt = 0
        trace("waitForEngineReady started deadline=\(deadline) baseURL=\(AppConfig.serverBaseURL.absoluteString)")
        while Date() < deadline {
            guard startGeneration == generation, !Task.isCancelled else {
                trace("waitForEngineReady cancelled startGeneration=\(generation)")
                return
            }
            attempt += 1
            if await dependencies.generationService.checkHealth() {
                guard startGeneration == generation, !Task.isCancelled else {
                    trace("waitForEngineReady health ok after cancellation; ignoring")
                    return
                }
                trace("waitForEngineReady health ok attempt=\(attempt)")
                // Immediately update status when the engine becomes reachable, matching the
                // original waitForHealth() from 999d859. Without this the UI can sit at
                // "Starting..." for up to 5 s waiting for the supervisor's health-check cycle.
                if store.engineStatus == .starting || store.engineStatus == .retrying {
                    store.engineStatus = .running
                    trace("engineStatus set to running after health ok")
                }
                await fetchVoices()
                refreshTelemetry()
                scheduleIdleStop()
                return
            }
            trace("waitForEngineReady health not ready attempt=\(attempt) status=\(store.engineStatus.rawValue)")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refreshTelemetry()
        trace("waitForEngineReady deadline reached attempts=\(attempt)")
        guard startGeneration == generation, !Task.isCancelled else {
            trace("waitForEngineReady deadline reached after cancellation; ignoring")
            return
        }
        if !(await dependencies.generationService.checkHealth()) {
            store.userMessage =
                "Could not reach the Kokoro engine at \(AppConfig.serverBaseURL.absoluteString). "
                + "Verify \(AppConfig.kokoroPath) contains kokoro_server.py and .venv/bin/python3. "
                + "Expected command: python -m uvicorn kokoro_server:app --host 127.0.0.1 --port \(AppConfig.enginePort) --timeout-keep-alive 120 --timeout-graceful-shutdown 30 --log-level warning --log-config kokoro-log-config.json"
            trace("waitForEngineReady final health failed; userMessage updated")
        }
    }

    // MARK: Supervisor reports

    func wireSupervisorCallbacks() {
        dependencies.engineSupervisor.onHealthChanged = { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                self.trace("onHealthChanged status=\(summary.status.rawValue) pid=\(summary.pid.map(String.init) ?? "nil") retry=\(summary.retryCount) failures=\(summary.consecutiveHealthFailures) latestIssue=\(summary.latestIssue?.code ?? "nil")")
                guard self.shouldApply(summary) else {
                    self.trace("ignored stale engine health status=\(summary.status.rawValue) currentStatus=\(self.store.engineStatus.rawValue)")
                    return
                }
                let wasReady = self.store.engineStatus == .idle || self.store.engineStatus == .running
                // Each 5 s health check only bumps its timestamps, which no
                // view shows; assigning the summary anyway would republish
                // the store and redraw the window every check.
                if !summary.matchesIgnoringCheckTimes(self.store.engineHealth) {
                    self.store.engineHealth = summary
                }
                if summary.status != self.store.engineStatus {
                    self.store.engineStatus = summary.status
                    self.refreshTelemetry()
                }
                if summary.status == .idle || summary.status == .running {
                    if self.store.lastError?.code.hasPrefix("engine.") == true {
                        self.store.clearErrorMessage()
                    }
                    // Health checks repeat every few seconds; the voice lists
                    // (Edge's comes over the internet) only need fetching when
                    // the engine becomes ready, not on every check.
                    if !wasReady {
                        await self.fetchVoices()
                    }
                }
            }
        }

        dependencies.engineSupervisor.onIssue = { [weak self] issue in
            Task { @MainActor in
                guard let self else { return }
                self.trace("onIssue code=\(issue.code) title=\(issue.title) rawError=\(issue.rawError ?? "nil") context=\(issue.context)")
                self.store.playback = .idle
                self.store.record(issue)
            }
        }
    }

    private func shouldApply(_ summary: EngineHealthSummary) -> Bool {
        switch summary.status {
        case .starting, .retrying:
            return store.engineStatus != .stopped || startTask != nil
        case .stopped:
            return !(startTask != nil && (store.engineStatus == .starting || store.engineStatus == .retrying))
        case .running, .idle, .busy, .degraded, .timedOut, .stalled, .failed:
            return true
        }
    }

    private static func normalizeEngineError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .engine(
            code: "unknown",
            title: "Engine Error",
            message: error.localizedDescription,
            recoverySuggestion: "Retry the operation or restart the engine.",
            underlyingError: error
        )
    }
}

private extension EngineHealthSummary {
    /// Equal apart from the health-check timestamps, which change on every
    /// check but aren't shown anywhere.
    func matchesIgnoringCheckTimes(_ other: EngineHealthSummary) -> Bool {
        var lhs = self
        var rhs = other
        lhs.lastHealthCheckAt = nil
        lhs.lastSuccessfulHealthCheckAt = nil
        rhs.lastHealthCheckAt = nil
        rhs.lastSuccessfulHealthCheckAt = nil
        return lhs == rhs
    }
}
