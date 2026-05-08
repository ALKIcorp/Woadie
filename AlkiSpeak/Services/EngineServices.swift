import Foundation
import Darwin
import os

struct EngineTimeoutPolicy: Hashable {
    var requestTimeout: TimeInterval
    var resourceTimeout: TimeInterval
    var startupTimeout: TimeInterval
    var healthCheckTimeout: TimeInterval

    static let live = EngineTimeoutPolicy(
        requestTimeout: AppConfig.requestTimeoutSeconds,
        resourceTimeout: AppConfig.resourceTimeoutSeconds,
        startupTimeout: AppConfig.engineStartupTimeoutSeconds,
        healthCheckTimeout: AppConfig.healthCheckTimeoutSeconds
    )
}

struct EngineRequestPolicy: Hashable {
    var maxDirectCharacters: Int
    var maxSegmentCharacters: Int

    static let live = EngineRequestPolicy(
        maxDirectCharacters: AppConfig.maxDirectRequestCharacters,
        maxSegmentCharacters: AppConfig.maxSegmentCharacters
    )

    func segments(for text: String) -> [SpeechSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxDirectCharacters else {
            return [SpeechSegment(index: 0, text: trimmed)]
        }

        var result: [SpeechSegment] = []
        var buffer = ""
        var index = 0

        for sentence in trimmed.split(whereSeparator: \.isNewline).flatMap({ line in
            line.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        }) {
            let candidate = buffer.isEmpty ? sentence : buffer + ". " + sentence
            if candidate.count <= maxSegmentCharacters {
                buffer = candidate
            } else {
                if !buffer.isEmpty {
                    result.append(SpeechSegment(index: index, text: buffer.trimmingCharacters(in: .whitespacesAndNewlines)))
                    index += 1
                }
                buffer = String(sentence.prefix(maxSegmentCharacters))
                let remainder = sentence.dropFirst(maxSegmentCharacters)
                if !remainder.isEmpty {
                    var remaining = String(remainder)
                    while remaining.count > maxSegmentCharacters {
                        result.append(SpeechSegment(index: index, text: String(remaining.prefix(maxSegmentCharacters))))
                        index += 1
                        remaining = String(remaining.dropFirst(maxSegmentCharacters))
                    }
                    buffer = remaining
                }
            }
        }

        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(SpeechSegment(index: index, text: buffer.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return result.isEmpty ? [SpeechSegment(index: 0, text: trimmed)] : result
    }
}

final class ProcessEngineSupervisor: EngineSupervising {
    private let logger = Logger(subsystem: "com.alki.Woadie", category: "EngineSupervisor")
    private let queue = DispatchQueue(label: "com.alki.Woadie.engine-supervisor")
    private let timeoutPolicy: EngineTimeoutPolicy
    private var process: Process?
    private var isStopping = false
    private var healthTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var adoptedProcessIdentifier: Int32?
    private var state: EngineHealthSummary = .stopped

    var onHealthChanged: ((EngineHealthSummary) -> Void)?
    var onIssue: ((EngineIssue) -> Void)?

    init(timeoutPolicy: EngineTimeoutPolicy = .live) {
        self.timeoutPolicy = timeoutPolicy
    }

    var isRunning: Bool {
        queue.sync { process?.isRunning == true || adoptedProcessIdentifier != nil }
    }

    var processIdentifier: Int32? {
        queue.sync { process?.processIdentifier ?? adoptedProcessIdentifier }
    }

    var healthSummary: EngineHealthSummary {
        queue.sync { state }
    }

    func start() throws {
        restartTask?.cancel()
        try launchProcess(resetRetryCount: true)
    }

    func stop() {
        restartTask?.cancel()
        startupTask?.cancel()
        healthTask?.cancel()

        let stopped = queue.sync { () -> EngineHealthSummary in
            isStopping = true
            process?.terminate()
            if let adoptedProcessIdentifier {
                _ = runKill(signal: "-TERM", pids: [adoptedProcessIdentifier])
            }
            process = nil
            adoptedProcessIdentifier = nil
            state.status = .stopped
            state.pid = nil
            state.startedAt = nil
            state.activeJobID = nil
            state.consecutiveHealthFailures = 0
            return state
        }
        logger.info("Engine stopped by app lifecycle")
        onHealthChanged?(stopped)
    }

    func noteRequestStarted(jobID: UUID) {
        publish { summary in
            summary.activeJobID = jobID
            summary.status = .busy
        }
    }

    func noteRequestFinished(jobID: UUID) {
        publish { summary in
            if summary.activeJobID == jobID {
                summary.activeJobID = nil
                summary.status = summary.latestIssue == nil ? .idle : .degraded
            }
        }
    }

    func findListeningPidsOnEnginePort() -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = [
            "-tiTCP:\(AppConfig.enginePort)",
            "-sTCP:LISTEN"
        ]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return []
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func terminatePortUsers(_ pids: [Int32]) async {
        guard !pids.isEmpty else { return }
        _ = runKill(signal: "-TERM", pids: pids)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if findListeningPidsOnEnginePort().isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        _ = runKill(signal: "-KILL", pids: pids)
    }

    private func launchProcess(resetRetryCount: Bool) throws {
        let alreadyRunning = queue.sync { process?.isRunning == true || adoptedProcessIdentifier != nil || state.status == .starting }
        guard !alreadyRunning else { return }

        if resetRetryCount {
            establishCleanSlate()
        }

        let portUsers = findListeningPidsOnEnginePort()
        if !portUsers.isEmpty {
            if isLikelyRecoverableEngineOwner(portUsers: portUsers) {
                record(
                    EngineIssue(
                        code: "engine.reclaiming-orphan",
                        title: "Clearing Previous Engine",
                        description: "A previous local engine was still bound to port \(AppConfig.enginePort) after the app quit.",
                        probableCause: "The app was force quit, so macOS did not deliver the normal termination callback. The supervisor is clearing it before launch.",
                        subsystem: "engine.lifecycle",
                        context: ["port": "\(AppConfig.enginePort)", "pids": portUsers.map(String.init).joined(separator: ",")]
                    ),
                    status: .retrying,
                    notifyUser: false
                )
                reclaimPortUsers(portUsers)
            } else {
                let issue = EngineIssue(
                    code: "engine.port-in-use",
                    title: "Engine Port In Use",
                    description: "Port \(AppConfig.enginePort) is already owned by another non-engine process.",
                    probableCause: "Another local service is listening on the Kokoro port.",
                    subsystem: "engine.lifecycle",
                    context: [
                        "port": "\(AppConfig.enginePort)",
                        "pids": portUsers.map(String.init).joined(separator: ","),
                        "commands": portUsers.map { processCommandLine(for: $0) }.joined(separator: "\n")
                    ]
                )
                record(issue, status: .failed)
                throw AlkiSpeakError.engine(
                    code: "port-in-use",
                    title: issue.title,
                    message: issue.description,
                    recoverySuggestion: issue.probableCause,
                    context: issue.context
                )
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: AppConfig.kokoroPath)
            .appendingPathComponent(".venv/bin/python")
        proc.currentDirectoryURL = URL(fileURLWithPath: AppConfig.kokoroPath)
        proc.arguments = [
            "-m",
            "uvicorn",
            "kokoro_server:app",
            "--host",
            "127.0.0.1",
            "--port",
            "\(AppConfig.enginePort)"
        ]

        let stderr = Pipe()
        proc.standardError = stderr
        proc.standardOutput = Pipe()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.logger.error("Engine stderr: \(text, privacy: .public)")
        }

        proc.terminationHandler = { [weak self] process in
            self?.handleTermination(statusCode: process.terminationStatus)
        }

        let prelaunchSummary = queue.sync { () -> EngineHealthSummary in
            if resetRetryCount {
                state.retryCount = 0
                state.recentIssues = []
                state.latestIssue = nil
            }
            isStopping = false
            process = proc
            adoptedProcessIdentifier = nil
            state.status = .starting
            state.pid = nil
            state.startedAt = Date()
            state.port = AppConfig.enginePort
            state.baseURL = AppConfig.serverBaseURL
            state.lastHealthCheckAt = nil
            state.lastSuccessfulHealthCheckAt = nil
            state.consecutiveHealthFailures = 0
            return state
        }
        onHealthChanged?(prelaunchSummary)

        do {
            try proc.run()
        } catch {
            queue.sync {
                if process === proc {
                    process = nil
                    state.pid = nil
                }
            }
            let issue = EngineIssue(
                code: "engine.launch-failed",
                title: "Engine Launch Failed",
                description: "The local Kokoro process could not be started.",
                probableCause: "The Kokoro checkout, virtual environment, or uvicorn command is unavailable.",
                subsystem: "engine.lifecycle",
                rawError: error.localizedDescription
            )
            record(issue, status: .failed)
            throw error
        }

        let summary = queue.sync { () -> EngineHealthSummary in
            guard process === proc, state.status == .starting else {
                return state
            }
            state.pid = proc.processIdentifier
            return state
        }

        logger.info("Engine launched pid=\(proc.processIdentifier) port=\(AppConfig.enginePort)")
        onHealthChanged?(summary)
        startMonitoring()
    }

    private func startMonitoring() {
        startupTask?.cancel()
        healthTask?.cancel()

        startupTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeoutPolicy.startupTimeout * 1_000_000_000))
            await self.handleStartupDeadline()
        }

        healthTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performHealthCheck()
                try? await Task.sleep(nanoseconds: UInt64(AppConfig.healthCheckIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func performHealthCheck() async {
        guard isRunning else {
            let shouldRecover = queue.sync {
                (state.status == .starting || state.status == .retrying) && restartTask == nil
            }
            if shouldRecover {
                handleStartupProcessUnavailable(rawError: "The engine process is not running while startup is pending.")
            }
            return
        }
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutPolicy.healthCheckTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
                && ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true)
            if ok {
                startupTask?.cancel()
                publish { summary in
                    if summary.activeJobID != nil {
                        summary.status = .busy
                    } else if summary.status == .starting || summary.status == .retrying {
                        summary.status = .running
                    } else {
                        summary.status = .idle
                    }
                    summary.lastHealthCheckAt = Date()
                    summary.lastSuccessfulHealthCheckAt = Date()
                    summary.consecutiveHealthFailures = 0
                    summary.latestIssue = nil
                }
            } else {
                handleHealthFailure(rawError: "Health endpoint did not return ok=true")
            }
        } catch {
            handleHealthFailure(rawError: error.localizedDescription)
        }
    }

    private func handleHealthFailure(rawError: String) {
        let portUsers = findListeningPidsOnEnginePort()
        let adoptedPID = queue.sync { adoptedProcessIdentifier }
        let adoptedProcessDisappeared = adoptedPID.map { !processExists(pid: $0) } ?? false
        if portUsers.isEmpty || adoptedProcessDisappeared {
            let issue = EngineIssue(
                code: "engine.listener-missing",
                title: "Engine Listener Missing",
                description: "The local engine is no longer listening on port \(AppConfig.enginePort).",
                probableCause: "A previously adopted engine exited after a force quit or was killed outside the app.",
                subsystem: "engine.lifecycle",
                retryCount: healthSummary.retryCount,
                rawError: rawError,
                context: [
                    "port": "\(AppConfig.enginePort)",
                    "adoptedPID": adoptedPID.map(String.init) ?? ""
                ]
            )
            record(issue, status: .retrying, notifyUser: false) { summary in
                summary.pid = nil
                summary.activeJobID = nil
                summary.consecutiveHealthFailures = 0
            }
            forceTerminateForRecovery()
            scheduleRestart(cause: issue)
            return
        }

        let isStillStarting = queue.sync { state.status == .starting || state.status == .retrying }
        if isStillStarting {
            let failureCount = queue.sync { state.consecutiveHealthFailures + 1 }
            publish { summary in
                summary.lastHealthCheckAt = Date()
                summary.consecutiveHealthFailures = failureCount
            }
            let shouldTimeoutStartup = queue.sync {
                state.status == .starting
                    && restartTask == nil
                    && failureCount >= startupHealthFailureLimit
            }
            if shouldTimeoutStartup {
                handleStartupHealthFailuresExceeded(failureCount: failureCount, rawError: rawError)
            }
            return
        }

        let failureCount = queue.sync { state.consecutiveHealthFailures + 1 }
        let status: EngineStatus = failureCount >= 3 ? .stalled : .degraded
        let issue = EngineIssue(
            code: failureCount >= 3 ? "engine.health-stalled" : "engine.health-degraded",
            title: failureCount >= 3 ? "Engine Health Check Stalled" : "Engine Health Check Failed",
            description: "The local engine did not respond correctly to a health check.",
            probableCause: "The server is overloaded, still warming up, or stopped responding on localhost.",
            subsystem: "engine.health",
            retryCount: healthSummary.retryCount,
            rawError: rawError,
            context: ["failureCount": "\(failureCount)", "port": "\(AppConfig.enginePort)"]
        )
        record(issue, status: status) { summary in
            summary.lastHealthCheckAt = Date()
            summary.consecutiveHealthFailures = failureCount
        }

        if failureCount >= 3 {
            forceTerminateForRecovery()
            scheduleRestart(cause: issue)
        }
    }

    private func handleStartupDeadline() async {
        let shouldFail = queue.sync {
            state.status == .starting && state.lastSuccessfulHealthCheckAt == nil
        }
        guard shouldFail else { return }
        let issue = EngineIssue(
            code: "engine.startup-timeout",
            title: "Engine Startup Timed Out",
            description: "The engine process started but did not become healthy within \(Int(timeoutPolicy.startupTimeout)) seconds.",
            probableCause: "Model loading is stuck, dependencies are missing, or the server is blocked during startup.",
            subsystem: "engine.lifecycle",
            retryCount: healthSummary.retryCount,
            context: ["timeoutSeconds": "\(timeoutPolicy.startupTimeout)"]
        )
        record(issue, status: .timedOut)
        forceTerminateForRecovery()
        scheduleRestart(cause: issue)
    }

    private var startupHealthFailureLimit: Int {
        max(1, Int(ceil(timeoutPolicy.startupTimeout / AppConfig.healthCheckIntervalSeconds)))
    }

    private func handleStartupHealthFailuresExceeded(failureCount: Int, rawError: String) {
        let issue = EngineIssue(
            code: "engine.startup-health-timeout",
            title: "Engine Startup Health Timed Out",
            description: "The engine did not pass a health check after \(failureCount) startup attempts.",
            probableCause: "The server process is alive but not serving healthy responses on localhost.",
            subsystem: "engine.health",
            retryCount: healthSummary.retryCount,
            rawError: rawError,
            context: [
                "failureCount": "\(failureCount)",
                "port": "\(AppConfig.enginePort)",
                "timeoutSeconds": "\(timeoutPolicy.startupTimeout)"
            ]
        )
        record(issue, status: .timedOut)
        forceTerminateForRecovery()
        scheduleRestart(cause: issue)
    }

    private func handleStartupProcessUnavailable(rawError: String) {
        let issue = EngineIssue(
            code: "engine.startup-process-exited",
            title: "Engine Startup Exited",
            description: "The engine process exited before it became healthy.",
            probableCause: "The Kokoro startup command failed, dependencies are missing, or the process was killed during clean-slate recovery.",
            subsystem: "engine.lifecycle",
            retryCount: healthSummary.retryCount,
            rawError: rawError,
            context: ["port": "\(AppConfig.enginePort)"]
        )
        record(issue, status: .retrying, notifyUser: false) { summary in
            summary.pid = nil
            summary.activeJobID = nil
            summary.consecutiveHealthFailures = 0
        }
        forceTerminateForRecovery()
        scheduleRestart(cause: issue)
    }

    private func handleTermination(statusCode: Int32) {
        let shouldIgnoreRecoveryExit = queue.sync {
            process == nil && (state.status == .retrying || state.status == .timedOut || state.status == .stalled)
        }
        if shouldIgnoreRecoveryExit {
            return
        }

        let intentional = queue.sync { isStopping }
        if intentional {
            let stopped = queue.sync { () -> EngineHealthSummary in
                isStopping = false
                process = nil
                adoptedProcessIdentifier = nil
                state.status = .stopped
                state.pid = nil
                return state
            }
            onHealthChanged?(stopped)
            return
        }

        let issue = EngineIssue(
            code: "engine.unexpected-termination",
            title: "Engine Process Exited",
            description: "The local engine exited unexpectedly with status \(statusCode).",
            probableCause: "The server crashed, was killed externally, or failed while handling a request.",
            subsystem: "engine.lifecycle",
            retryCount: healthSummary.retryCount,
            rawError: "terminationStatus=\(statusCode)"
        )
        record(issue, status: .retrying) { summary in
            summary.pid = nil
            summary.activeJobID = nil
        }
        scheduleRestart(cause: issue)
    }

    private func forceTerminateForRecovery() {
        queue.sync {
            isStopping = false
            process?.terminate()
            process = nil
            adoptedProcessIdentifier = nil
            state.pid = nil
        }
    }

    private func scheduleRestart(cause: EngineIssue) {
        restartTask?.cancel()

        let nextRetry = queue.sync { state.retryCount + 1 }
        guard nextRetry <= AppConfig.maxEngineRestartAttempts else {
            let issue = EngineIssue(
                code: "engine.restart-limit",
                title: "Engine Restart Limit Reached",
                description: "The engine failed repeatedly and automatic recovery has stopped.",
                probableCause: "The engine is crashing consistently. Inspect Kokoro startup logs before retrying.",
                subsystem: "engine.lifecycle",
                retryCount: nextRetry,
                rawError: cause.rawError
            )
            record(issue, status: .failed)
            return
        }

        publish { summary in
            summary.status = .retrying
            summary.retryCount = nextRetry
        }

        let delay = min(pow(2.0, Double(nextRetry - 1)), 10.0)
        logger.warning("Scheduling engine restart attempt=\(nextRetry) delay=\(delay, privacy: .public)s")
        restartTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            do {
                self.establishCleanSlate()
                try self.launchProcess(resetRetryCount: false)
            } catch {
                let issue = EngineIssue(
                    code: "engine.restart-failed",
                    title: "Engine Restart Failed",
                    description: "A controlled engine restart attempt failed.",
                    probableCause: "The Kokoro process cannot bind the port or launch from its configured path.",
                    subsystem: "engine.lifecycle",
                    retryCount: nextRetry,
                    rawError: error.localizedDescription
                )
                self.record(issue, status: .retrying)
                self.scheduleRestart(cause: issue)
            }
        }
    }

    private func record(
        _ issue: EngineIssue,
        status: EngineStatus,
        notifyUser: Bool = true,
        mutate: ((inout EngineHealthSummary) -> Void)? = nil
    ) {
        logger.error("\(issue.code, privacy: .public): \(issue.description, privacy: .public)")
        let summary = queue.sync { () -> EngineHealthSummary in
            state.status = status
            state.latestIssue = issue
            state.recentIssues.insert(issue, at: 0)
            if state.recentIssues.count > AppConfig.maxBufferedDiagnostics {
                state.recentIssues.removeLast(state.recentIssues.count - AppConfig.maxBufferedDiagnostics)
            }
            mutate?(&state)
            return state
        }
        if notifyUser {
            onIssue?(issue)
        }
        onHealthChanged?(summary)
    }

    private func publish(_ mutate: (inout EngineHealthSummary) -> Void) {
        let summary = queue.sync { () -> EngineHealthSummary in
            mutate(&state)
            return state
        }
        onHealthChanged?(summary)
    }

    private func runKill(signal: String, pids: [Int32]) -> Bool {
        guard !pids.isEmpty else { return true }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/kill")
        proc.arguments = [signal] + pids.map { String($0) }
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func canAdoptRunningEngine(portUsers: [Int32]) -> Bool {
        guard isLikelyRecoverableEngineOwner(portUsers: portUsers) else { return false }
        return checkHealthSynchronously(timeout: timeoutPolicy.healthCheckTimeout)
    }

    private func adoptExistingEngine(portUsers: [Int32], resetRetryCount: Bool) {
        let pid = portUsers.first
        let summary = queue.sync { () -> EngineHealthSummary in
            if resetRetryCount {
                state.retryCount = 0
            }
            process = nil
            adoptedProcessIdentifier = pid
            isStopping = false
            state.status = .running
            state.pid = pid
            state.startedAt = state.startedAt ?? Date()
            state.port = AppConfig.enginePort
            state.baseURL = AppConfig.serverBaseURL
            state.lastHealthCheckAt = Date()
            state.lastSuccessfulHealthCheckAt = Date()
            state.consecutiveHealthFailures = 0
            state.latestIssue = nil
            return state
        }
        logger.info("Adopted existing engine pid=\(pid ?? -1) port=\(AppConfig.enginePort)")
        onHealthChanged?(summary)
        startMonitoring()
    }

    private func reclaimPortUsers(_ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        _ = runKill(signal: "-TERM", pids: pids)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if findListeningPidsOnEnginePort().isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = runKill(signal: "-KILL", pids: pids)
    }

    private func establishCleanSlate() {
        let pids = recoverableEngineProcessIDs()
        guard !pids.isEmpty else { return }

        logger.info("Establishing clean engine slate pids=\(pids.map(String.init).joined(separator: ","), privacy: .public)")
        _ = runKill(signal: "-TERM", pids: pids)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if recoverableEngineProcessIDs().isEmpty && findListeningPidsOnEnginePort().isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let remaining = recoverableEngineProcessIDs()
        if !remaining.isEmpty {
            _ = runKill(signal: "-KILL", pids: remaining)
        }

        queue.sync {
            process = nil
            adoptedProcessIdentifier = nil
            isStopping = false
            state.pid = nil
            state.activeJobID = nil
            state.consecutiveHealthFailures = 0
        }
    }

    private func recoverableEngineProcessIDs() -> [Int32] {
        let currentPID = getpid()
        var pids = Set(
            findListeningPidsOnEnginePort().filter { pid in
                pid != currentPID && isRecoverableEngineCommand(processCommandLine(for: pid))
            }
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["ax", "-o", "pid=,command="]
        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return Array(pids)
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return Array(pids) }

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstSpace = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let pidText = trimmed[..<firstSpace]
            let command = trimmed[firstSpace...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(pidText), pid != currentPID else { continue }
            if isRecoverableEngineCommand(command) {
                pids.insert(pid)
            }
        }

        return Array(pids)
    }

    private func isLikelyRecoverableEngineOwner(portUsers: [Int32]) -> Bool {
        portUsers.contains { pid in
            isRecoverableEngineCommand(processCommandLine(for: pid))
        }
    }

    private func isRecoverableEngineCommand(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        let kokoroPath = AppConfig.kokoroPath.lowercased()
        return lowercased.contains("kokoro_server")
            || (lowercased.contains("uvicorn") && lowercased.contains("kokoro"))
            || (lowercased.contains(kokoroPath) && lowercased.contains("python"))
    }

    private func processCommandLine(for pid: Int32) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "command="]
        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return ""
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func processExists(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func checkHealthSynchronously(timeout: TimeInterval) -> Bool {
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var isHealthy = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard
                let data,
                let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }
            isHealthy = (object["ok"] as? Bool) == true
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return false
        }
        return isHealthy
    }
}

private final class EngineTaskMetricsDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var collectedMetrics: URLSessionTaskMetrics?

    var metrics: URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return collectedMetrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        collectedMetrics = metrics
        lock.unlock()
    }
}

final class KokoroSpeechGenerationService: SpeechGenerating {
    private let logger = Logger(subsystem: "com.alki.Woadie", category: "KokoroHTTP")
    private let timeoutPolicy: EngineTimeoutPolicy

    init(timeoutPolicy: EngineTimeoutPolicy = .live) {
        self.timeoutPolicy = timeoutPolicy
    }

    func checkHealth() async -> Bool {
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutPolicy.healthCheckTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (object?["ok"] as? Bool) == true
        } catch {
            return false
        }
    }

    func fetchVoices() async throws -> [String] {
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("voices"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutPolicy.resourceTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AlkiSpeakError.engine(
                code: "voices.http",
                title: "Voice Fetch Failed",
                message: "Failed to fetch Kokoro voices.",
                recoverySuggestion: "Confirm the local Kokoro server is running and try refreshing voices."
            )
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["voices"] as? [String] ?? []
    }

    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        if text.count > AppConfig.maxDirectRequestCharacters {
            throw AlkiSpeakError.generation(
                code: "oversized-direct-request",
                title: "Text Too Large For One Request",
                message: "Large text must be processed through segmented generation instead of a single engine request.",
                recoverySuggestion: "Split the text into smaller segments and retry.",
                context: ["characterCount": "\(text.count)", "limit": "\(AppConfig.maxDirectRequestCharacters)"]
            )
        }

        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutPolicy.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice": voice,
            "rate": AppConfig.defaultRate
        ])

        let metricsDelegate = EngineTaskMetricsDelegate()
        let startedAt = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: metricsDelegate)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let http = response as? HTTPURLResponse else {
                throw AlkiSpeakError.generation(
                    code: "missing-http-response",
                    title: "No Server Response",
                    message: "The speech request did not return an HTTP response.",
                    recoverySuggestion: "Restart the engine and try again.",
                    context: requestContext(jobID: jobID, elapsedMs: elapsedMs, metrics: metricsDelegate.metrics)
                )
            }
            guard http.statusCode == 200 else {
                throw AlkiSpeakError.generation(
                    code: "http-\(http.statusCode)",
                    title: "Speech Request Failed",
                    message: "The speech server returned \(http.statusCode).",
                    recoverySuggestion: "Check the text and selected voice, then try again.",
                    context: requestContext(jobID: jobID, elapsedMs: elapsedMs, metrics: metricsDelegate.metrics).merging([
                        "statusCode": "\(http.statusCode)"
                    ]) { current, _ in current }
                )
            }

            logger.info("Synthesis complete job=\(jobID?.uuidString ?? "none", privacy: .public) chars=\(text.count) elapsedMs=\(elapsedMs)")
            return SpeechGenerationResult(
                audioData: data,
                latencyMs: http.value(forHTTPHeaderField: "X-Gen-ms").flatMap(Int.init) ?? elapsedMs,
                charCount: http.value(forHTTPHeaderField: "X-Char-Count").flatMap(Int.init) ?? text.count
            )
        } catch is CancellationError {
            throw AlkiSpeakError.generation(
                code: "cancelled",
                title: "Speech Request Cancelled",
                message: "The speech request was cancelled before completion.",
                recoverySuggestion: "Start a new generation request when ready.",
                context: requestContext(jobID: jobID, elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000), metrics: metricsDelegate.metrics)
            )
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            throw AlkiSpeakError.generation(
                code: "request-failed",
                title: "Speech Request Failed",
                message: "The local engine request failed after \(elapsedMs) ms.",
                recoverySuggestion: "Check engine health and retry after the supervisor recovers.",
                underlyingError: error,
                context: requestContext(jobID: jobID, elapsedMs: elapsedMs, metrics: metricsDelegate.metrics)
            )
        }
    }

    private func requestContext(jobID: UUID?, elapsedMs: Int, metrics: URLSessionTaskMetrics?) -> [String: String] {
        var context: [String: String] = [
            "elapsedMs": "\(elapsedMs)",
            "timeoutSeconds": "\(timeoutPolicy.requestTimeout)"
        ]
        if let jobID {
            context["jobID"] = jobID.uuidString
        }
        if let transaction = metrics?.transactionMetrics.last {
            context["networkProtocol"] = transaction.networkProtocolName ?? "unknown"
            context["reusedConnection"] = "\(transaction.isReusedConnection)"
            if let status = transaction.response as? HTTPURLResponse {
                context["metricsStatusCode"] = "\(status.statusCode)"
            }
        }
        return context
    }
}
