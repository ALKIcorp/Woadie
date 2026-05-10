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
    /// True while a `scheduleRestart` task is sleeping or running `launchProcess`; avoids stale `restartTask` (completed tasks stay non-nil) blocking `performHealthCheck` recovery.
    private var restartWorkActive = false
    /// Bumps when scheduling or cancelling restart work so a cancelled task’s `defer` cannot clear `restartWorkActive` for a newer restart wave.
    private var restartGeneration: UInt64 = 0
    /// Bumps when a launch is superseded by stop or a newer launch request.
    private var launchGeneration: UInt64 = 0
    private var adoptedProcessIdentifier: Int32?
    private var adoptedProcessOwnership: EngineProcessOwnership = .none
    private var state: EngineHealthSummary = .stopped

    var onHealthChanged: ((EngineHealthSummary) -> Void)?
    var onIssue: ((EngineIssue) -> Void)?

    private enum EngineProcessOwnership {
        case none
        case external
        case launchedByApp
    }

    init(timeoutPolicy: EngineTimeoutPolicy = .live) {
        self.timeoutPolicy = timeoutPolicy
        consoleTrace("init requestTimeout=\(timeoutPolicy.requestTimeout) resourceTimeout=\(timeoutPolicy.resourceTimeout) startupTimeout=\(timeoutPolicy.startupTimeout) healthTimeout=\(timeoutPolicy.healthCheckTimeout)")
    }

    private func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        let text = "[Woadie][EngineSupervisor][\(function):\(line)] \(message)"
        NSLog("%@", text)
    }

    private enum EngineLaunchError: LocalizedError {
        case terminalOpenFailed(Int32)
        case terminalPIDUnavailable

        var errorDescription: String? {
            switch self {
            case .terminalOpenFailed(let status):
                return "Terminal failed to open the Kokoro launch script. open exited with status \(status)."
            case .terminalPIDUnavailable:
                return "Terminal opened the Kokoro launch script, but the engine PID was not written."
            }
        }
    }

    private static func resolveKokoroPythonExecutable(root: URL) -> String? {
        let fm = FileManager.default
        for name in ["python3", "python"] {
            let path = root.appendingPathComponent(".venv/bin/\(name)").path
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func terminalLaunchFiles(kokoroRoot: URL) throws -> (script: URL, pidFile: URL, logFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoadieEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            script: directory.appendingPathComponent("start-kokoro-engine.command"),
            pidFile: directory.appendingPathComponent("start-kokoro-engine.pid"),
            logFile: directory.appendingPathComponent("kokoro-engine.log")
        )
    }

    private static func writeTerminalLaunchScript(kokoroRoot: URL, pythonExecutable: String) throws -> (script: URL, pidFile: URL, logFile: URL) {
        let files = try terminalLaunchFiles(kokoroRoot: kokoroRoot)
        try? FileManager.default.removeItem(at: files.pidFile)

        let script = """
        #!/bin/zsh
        cd \(shellQuoted(kokoroRoot.path)) || exit 1
        export PYTHONUNBUFFERED=1
        : > \(shellQuoted(files.logFile.path))
        exec > >(tee -a \(shellQuoted(files.logFile.path))) 2>&1
        echo $$ > \(shellQuoted(files.pidFile.path))
        echo "Starting Kokoro engine at \(AppConfig.serverBaseURL.absoluteString)"
        echo "Working directory: \(kokoroRoot.path)"
        echo "Log file: \(files.logFile.path)"
        echo "Command: \(pythonExecutable) -m uvicorn kokoro_server:app --host 127.0.0.1 --port \(AppConfig.enginePort)"
        exec \(shellQuoted(pythonExecutable)) -m uvicorn kokoro_server:app --host 127.0.0.1 --port \(AppConfig.enginePort)
        """

        try script.write(to: files.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.script.path)
        return files
    }

    var isRunning: Bool {
        queue.sync {
            if process?.isRunning == true {
                return true
            }
            if let adoptedProcessIdentifier {
                return processExists(pid: adoptedProcessIdentifier)
            }
            return false
        }
    }

    var processIdentifier: Int32? {
        queue.sync {
            if let pid = process?.processIdentifier {
                return pid
            }
            guard let adoptedProcessIdentifier, processExists(pid: adoptedProcessIdentifier) else {
                return nil
            }
            return adoptedProcessIdentifier
        }
    }

    var healthSummary: EngineHealthSummary {
        queue.sync { state }
    }

    func start() throws {
        consoleTrace("start() called currentStatus=\(healthSummary.status.rawValue) pid=\(processIdentifier.map(String.init) ?? "nil") isRunning=\(isRunning)")
        restartTask?.cancel()
        let generation = queue.sync { () -> UInt64 in
            restartGeneration &+= 1
            launchGeneration &+= 1
            restartWorkActive = false
            return launchGeneration
        }
        consoleTrace("restart task cancelled generation advanced")
        try launchProcess(resetRetryCount: true, generation: generation)
    }

    func stop() {
        consoleTrace("stop() called currentStatus=\(healthSummary.status.rawValue) pid=\(processIdentifier.map(String.init) ?? "nil") isRunning=\(isRunning)")
        restartTask?.cancel()
        startupTask?.cancel()
        healthTask?.cancel()
        queue.sync {
            restartGeneration &+= 1
            launchGeneration &+= 1
            restartWorkActive = false
        }
        consoleTrace("monitoring tasks cancelled generation advanced")

        let pidToTerminate = queue.sync { () -> Int32? in
            isStopping = true
            process?.terminate()
            let pid = adoptedProcessOwnership == .launchedByApp ? adoptedProcessIdentifier : nil
            if let adoptedProcessIdentifier, adoptedProcessOwnership == .external {
                consoleTrace("stop() detaching from external adopted pid=\(adoptedProcessIdentifier)")
            }
            process = nil
            adoptedProcessIdentifier = nil
            adoptedProcessOwnership = .none
            state.status = .stopped
            state.pid = nil
            state.startedAt = nil
            state.activeJobID = nil
            state.consecutiveHealthFailures = 0
            return pid
        }
        if let pidToTerminate {
            consoleTrace("stop() terminating app-launched pid=\(pidToTerminate)")
            _ = runKill(signal: "-TERM", pids: [pidToTerminate])
        }
        let stopped = queue.sync { () -> EngineHealthSummary in
            state
        }
        logger.info("Engine stopped by app lifecycle")
        consoleTrace("stop() completed status=\(stopped.status.rawValue)")
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
        consoleTrace("findListeningPidsOnEnginePort running lsof port=\(AppConfig.enginePort)")
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
            consoleTrace("findListeningPidsOnEnginePort lsof failed error=\(error.localizedDescription)")
            return []
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        consoleTrace("findListeningPidsOnEnginePort status=\(proc.terminationStatus) pids=\(pids.map(String.init).joined(separator: ",")) raw=\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return pids
    }

    func terminatePortUsers(_ pids: [Int32]) async {
        consoleTrace("terminatePortUsers pids=\(pids.map(String.init).joined(separator: ","))")
        guard !pids.isEmpty else { return }
        _ = runKill(signal: "-TERM", pids: pids)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if findListeningPidsOnEnginePort().isEmpty {
                consoleTrace("terminatePortUsers port vacant after TERM")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        consoleTrace("terminatePortUsers escalating to KILL pids=\(pids.map(String.init).joined(separator: ","))")
        _ = runKill(signal: "-KILL", pids: pids)
        waitUntilEnginePortVacant(timeout: 4.0)
    }

    /// After SIGKILL or racey teardown, the listener PID can linger briefly; wait before spawning a replacement.
    private func waitUntilEnginePortVacant(timeout: TimeInterval) {
        consoleTrace("waitUntilEnginePortVacant timeout=\(timeout)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if findListeningPidsOnEnginePort().isEmpty {
                consoleTrace("waitUntilEnginePortVacant port is vacant")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        consoleTrace("waitUntilEnginePortVacant timed out; port still occupied")
    }

    /// Slow cold/warm servers can miss a 3s probe; allow resource timeout when deciding adopt vs reclaim.
    private var launchPortHealthProbeTimeout: TimeInterval {
        max(timeoutPolicy.healthCheckTimeout, timeoutPolicy.resourceTimeout)
    }

    private func isCurrentLaunchGeneration(_ generation: UInt64) -> Bool {
        queue.sync { launchGeneration == generation }
    }

    private func ensureCurrentLaunchGeneration(_ generation: UInt64, context: String) throws {
        guard isCurrentLaunchGeneration(generation) else {
            consoleTrace("launch generation cancelled context=\(context) generation=\(generation)")
            throw CancellationError()
        }
    }

    private func launchProcess(resetRetryCount: Bool, generation: UInt64) throws {
        try ensureCurrentLaunchGeneration(generation, context: "launchProcess entry")
        let launchState = queue.sync {
            (
                processRunning: process?.isRunning == true,
                adoptedPID: adoptedProcessIdentifier,
                status: state.status,
                retryCount: state.retryCount
            )
        }
        consoleTrace("launchProcess resetRetryCount=\(resetRetryCount) processRunning=\(launchState.processRunning) adoptedPID=\(launchState.adoptedPID.map(String.init) ?? "nil") status=\(launchState.status.rawValue) retry=\(launchState.retryCount)")
        let alreadyRunning = launchState.processRunning || launchState.adoptedPID != nil || launchState.status == .starting
        guard !alreadyRunning else {
            consoleTrace("launchProcess returning early because engine is already running/starting")
            return
        }

        if try adoptHealthyExistingEngineIfAvailable(resetRetryCount: resetRetryCount, generation: generation) {
            return
        }
        try ensureCurrentLaunchGeneration(generation, context: "before clean slate")

        if resetRetryCount {
            consoleTrace("launchProcess establishing clean slate")
            establishCleanSlate()
            try ensureCurrentLaunchGeneration(generation, context: "after clean slate")
        }

        let portUsers = findListeningPidsOnEnginePort()
        consoleTrace("launchProcess initial portUsers=\(portUsers.map(String.init).joined(separator: ","))")
        if !portUsers.isEmpty {
            if checkHealthSynchronously(timeout: launchPortHealthProbeTimeout) {
                try ensureCurrentLaunchGeneration(generation, context: "before adopting existing listener")
                consoleTrace("launchProcess health check proved existing listener is usable; adopting")
                // Command-line heuristics can miss a Kokoro listener (truncated ps, wrapper binary, etc.);
                // health proves our configured endpoint is alive, so reconnect instead of reclaiming it.
                let listeners = findListeningPidsOnEnginePort()
                if !listeners.isEmpty {
                    consoleTrace("launchProcess adopting listeners=\(listeners.map(String.init).joined(separator: ","))")
                    adoptExistingEngine(portUsers: listeners, resetRetryCount: resetRetryCount, ownership: .external)
                    return
                }
            } else if isLikelyRecoverableEngineOwner(portUsers: portUsers) {
                try ensureCurrentLaunchGeneration(generation, context: "before reclaiming recoverable owner")
                consoleTrace("launchProcess found recoverable engine owner; reclaiming pids=\(portUsers.map(String.init).joined(separator: ","))")
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
            }
            try ensureCurrentLaunchGeneration(generation, context: "after initial port handling")

            var stillBlocked = findListeningPidsOnEnginePort()
            consoleTrace("launchProcess post-reclaim stillBlocked=\(stillBlocked.map(String.init).joined(separator: ","))")
            if !stillBlocked.isEmpty {
                // Last resort: port is reserved but we could not classify or reach health (stale process, stuck server, lsof/ps mismatch). Clear listeners for this configured port once, then spawn.
                record(
                    EngineIssue(
                        code: "engine.reclaiming-port-occupant",
                        title: "Reclaiming Engine Port",
                        description: "Port \(AppConfig.enginePort) was still in use before launch; stopping listeners so the supervised engine can bind.",
                        probableCause: "A prior run left a process on this port that did not match recovery heuristics or did not answer health checks in time.",
                        subsystem: "engine.lifecycle",
                        context: [
                            "port": "\(AppConfig.enginePort)",
                            "pids": stillBlocked.map(String.init).joined(separator: ","),
                            "commands": stillBlocked.map { processCommandLine(for: $0) }.joined(separator: "\n")
                        ]
                    ),
                    status: .retrying,
                    notifyUser: false
                )
                reclaimPortUsers(stillBlocked)
                waitUntilEnginePortVacant(timeout: 5.0)
                try ensureCurrentLaunchGeneration(generation, context: "after forced port reclaim")
                stillBlocked = findListeningPidsOnEnginePort()
                consoleTrace("launchProcess after forced reclaim stillBlocked=\(stillBlocked.map(String.init).joined(separator: ","))")
            }
            if !stillBlocked.isEmpty {
                consoleTrace("launchProcess failing because port remains blocked")
                let issue = EngineIssue(
                    code: "engine.port-in-use",
                    title: "Engine Port In Use",
                    description: "Port \(AppConfig.enginePort) is still blocked after reclaim attempts.",
                    probableCause: "Another process is listening on the Kokoro port and did not exit after termination signals.",
                    subsystem: "engine.lifecycle",
                    context: [
                        "port": "\(AppConfig.enginePort)",
                        "pids": stillBlocked.map(String.init).joined(separator: ","),
                        "commands": stillBlocked.map { processCommandLine(for: $0) }.joined(separator: "\n")
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

        try ensureCurrentLaunchGeneration(generation, context: "before validating launch files")
        let kokoroRoot = URL(fileURLWithPath: AppConfig.kokoroPath, isDirectory: true)
        let fm = FileManager.default
        let serverPy = kokoroRoot.appendingPathComponent("kokoro_server.py").path
        consoleTrace("launchProcess validating kokoroRoot=\(kokoroRoot.path) serverPy=\(serverPy)")
        guard fm.fileExists(atPath: serverPy) else {
            consoleTrace("launchProcess missing kokoro_server.py expected=\(serverPy)")
            let issue = EngineIssue(
                code: "engine.missing-checkout",
                title: "Kokoro Directory Invalid",
                description: "Could not find kokoro_server.py under \(AppConfig.kokoroPath).",
                probableCause: "The path is wrong for this Mac, or the repo lives elsewhere. Set KOKORO_HOME or move the checkout.",
                subsystem: "engine.lifecycle",
                context: ["expected": serverPy]
            )
            record(issue, status: .failed)
            throw AlkiSpeakError.engine(
                code: "missing-checkout",
                title: issue.title,
                message: issue.description,
                recoverySuggestion: issue.probableCause,
                context: issue.context
            )
        }

        guard let pythonExecutable = Self.resolveKokoroPythonExecutable(root: kokoroRoot) else {
            consoleTrace("launchProcess missing executable .venv/bin/python3 or python under \(kokoroRoot.path)")
            let issue = EngineIssue(
                code: "engine.missing-venv",
                title: "Python Virtualenv Missing",
                description: "Could not find an executable at .venv/bin/python3 (or python) under \(AppConfig.kokoroPath).",
                probableCause: "Create a venv in that directory, or fix KOKORO_HOME so it points at the folder that contains kokoro_server.py and .venv.",
                subsystem: "engine.lifecycle"
            )
            record(issue, status: .failed)
            throw AlkiSpeakError.engine(
                code: "missing-venv",
                title: issue.title,
                message: issue.description,
                recoverySuggestion: issue.probableCause
            )
        }
        consoleTrace("launchProcess resolved pythonExecutable=\(pythonExecutable)")

        try ensureCurrentLaunchGeneration(generation, context: "before writing Terminal launch script")
        let launchFiles: (script: URL, pidFile: URL, logFile: URL)
        do {
            launchFiles = try Self.writeTerminalLaunchScript(kokoroRoot: kokoroRoot, pythonExecutable: pythonExecutable)
            consoleTrace("launchProcess wrote Terminal launch script=\(launchFiles.script.path) pidFile=\(launchFiles.pidFile.path) logFile=\(launchFiles.logFile.path)")
        } catch {
            consoleTrace("launchProcess failed writing Terminal launch script error=\(error.localizedDescription)")
            let issue = EngineIssue(
                code: "engine.launch-script-failed",
                title: "Engine Launch Script Failed",
                description: "Could not create the Terminal command file used to start Kokoro.",
                probableCause: "The app could not write to its temporary directory.",
                subsystem: "engine.lifecycle",
                rawError: error.localizedDescription
            )
            record(issue, status: .failed)
            throw error
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", launchFiles.script.path]
        consoleTrace("launchProcess opening Terminal via /usr/bin/open args=\(proc.arguments?.joined(separator: " ") ?? "")")

        try ensureCurrentLaunchGeneration(generation, context: "before Terminal open")
        let prelaunchSummary = queue.sync { () -> EngineHealthSummary in
            if resetRetryCount {
                state.retryCount = 0
                state.recentIssues = []
                state.latestIssue = nil
            }
            isStopping = false
            process = nil
            adoptedProcessIdentifier = nil
            adoptedProcessOwnership = .none
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
        consoleTrace("launchProcess state set to starting before Terminal open")
        onHealthChanged?(prelaunchSummary)

        do {
            try proc.run()
            proc.waitUntilExit()
            consoleTrace("launchProcess /usr/bin/open exited status=\(proc.terminationStatus)")
            guard proc.terminationStatus == 0 else {
                throw EngineLaunchError.terminalOpenFailed(proc.terminationStatus)
            }
            try ensureCurrentLaunchGeneration(generation, context: "after Terminal open")
        } catch {
            if error is CancellationError {
                throw error
            }
            consoleTrace("launchProcess Terminal open failed error=\(error.localizedDescription)")
            queue.sync {
                process = nil
                adoptedProcessIdentifier = nil
                state.pid = nil
            }
            let issue = EngineIssue(
                code: "engine.launch-failed",
                title: "Engine Launch Failed",
                description: "The Terminal command used to start Kokoro could not be opened.",
                probableCause: "Terminal.app is unavailable or macOS refused to open the generated .command file.",
                subsystem: "engine.lifecycle",
                rawError: error.localizedDescription
            )
            record(issue, status: .failed)
            throw error
        }

        guard let terminalEnginePID = try waitForTerminalEnginePID(pidFile: launchFiles.pidFile, timeout: 5.0, generation: generation) else {
            consoleTrace("launchProcess failed waiting for Terminal engine PID pidFile=\(launchFiles.pidFile.path)")
            let issue = EngineIssue(
                code: "engine.launch-pid-missing",
                title: "Engine PID Missing",
                description: "Terminal opened, but the Kokoro launch script did not report a process ID.",
                probableCause: "Terminal did not execute the generated .command file.",
                subsystem: "engine.lifecycle",
                context: ["script": launchFiles.script.path, "pidFile": launchFiles.pidFile.path, "logFile": launchFiles.logFile.path]
            )
            record(issue, status: .failed)
            throw EngineLaunchError.terminalPIDUnavailable
        }
        consoleTrace("launchProcess Terminal engine PID detected pid=\(terminalEnginePID)")

        let summary = queue.sync { () -> EngineHealthSummary in
            guard state.status == .starting else {
                return state
            }
            adoptedProcessIdentifier = terminalEnginePID
            adoptedProcessOwnership = .launchedByApp
            state.pid = terminalEnginePID
            return state
        }

        logger.info("Engine launched in Terminal pid=\(terminalEnginePID) port=\(AppConfig.enginePort)")
        consoleTrace("launchProcess completed; monitoring will start pid=\(terminalEnginePID)")
        onHealthChanged?(summary)
        startMonitoring()
    }

    private func adoptHealthyExistingEngineIfAvailable(resetRetryCount: Bool, generation: UInt64) throws -> Bool {
        let portUsers = findListeningPidsOnEnginePort()
        guard !portUsers.isEmpty else { return false }
        consoleTrace("launchProcess pre-clean-slate portUsers=\(portUsers.map(String.init).joined(separator: ","))")

        guard checkHealthSynchronously(timeout: launchPortHealthProbeTimeout) else {
            return false
        }
        try ensureCurrentLaunchGeneration(generation, context: "before pre-clean-slate adopt")

        let listeners = findListeningPidsOnEnginePort()
        guard !listeners.isEmpty else { return false }
        consoleTrace("launchProcess adopting healthy existing engine before cleanup listeners=\(listeners.map(String.init).joined(separator: ","))")
        adoptExistingEngine(portUsers: listeners, resetRetryCount: resetRetryCount, ownership: .external)
        return true
    }

    private func waitForTerminalEnginePID(pidFile: URL, timeout: TimeInterval, generation: UInt64) throws -> Int32? {
        consoleTrace("waitForTerminalEnginePID pidFile=\(pidFile.path) timeout=\(timeout)")
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        var launchWasCancelled = false
        while Date() < deadline {
            attempt += 1
            if !isCurrentLaunchGeneration(generation) {
                launchWasCancelled = true
            }
            if
                let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                processExists(pid: pid)
            {
                if launchWasCancelled {
                    consoleTrace("waitForTerminalEnginePID found pid=\(pid) after cancellation; terminating")
                    _ = runKill(signal: "-TERM", pids: [pid])
                    throw CancellationError()
                }
                consoleTrace("waitForTerminalEnginePID found pid=\(pid) attempt=\(attempt)")
                return pid
            }
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                consoleTrace("waitForTerminalEnginePID attempt=\(attempt) pidFileText=\(text.trimmingCharacters(in: .whitespacesAndNewlines)) processExists=false")
            } else {
                consoleTrace("waitForTerminalEnginePID attempt=\(attempt) pidFile not readable yet")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if launchWasCancelled {
            consoleTrace("waitForTerminalEnginePID timed out after cancellation attempts=\(attempt)")
            throw CancellationError()
        }
        consoleTrace("waitForTerminalEnginePID timed out attempts=\(attempt)")
        return nil
    }

    private func startMonitoring() {
        consoleTrace("startMonitoring cancelling old tasks and starting new health loop")
        startupTask?.cancel()
        healthTask?.cancel()

        startupTask = Task { [weak self] in
            guard let self else { return }
            self.consoleTrace("startup deadline task sleeping timeout=\(self.timeoutPolicy.startupTimeout)")
            do {
                try await Task.sleep(nanoseconds: UInt64(self.timeoutPolicy.startupTimeout * 1_000_000_000))
            } catch {
                self.consoleTrace("startup deadline task cancelled before timeout")
                return
            }
            await self.handleStartupDeadline()
        }

        healthTask = Task { [weak self] in
            guard let self else { return }
            self.consoleTrace("health task loop started interval=\(AppConfig.healthCheckIntervalSeconds)")
            while !Task.isCancelled {
                await self.performHealthCheck()
                try? await Task.sleep(nanoseconds: UInt64(AppConfig.healthCheckIntervalSeconds * 1_000_000_000))
            }
            self.consoleTrace("health task loop ended")
        }
    }

    private func performHealthCheck() async {
        consoleTrace("performHealthCheck started isRunning=\(isRunning) pid=\(processIdentifier.map(String.init) ?? "nil")")
        guard isRunning else {
            let shouldRecover = queue.sync {
                (state.status == .starting || state.status == .retrying) && !restartWorkActive
            }
            consoleTrace("performHealthCheck not running shouldRecover=\(shouldRecover)")
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
            consoleTrace("performHealthCheck responseStatus=\((response as? HTTPURLResponse)?.statusCode ?? -1) ok=\(ok) bytes=\(data.count)")
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
            consoleTrace("performHealthCheck request failed error=\(error.localizedDescription)")
            handleHealthFailure(rawError: error.localizedDescription)
        }
    }

    private func handleHealthFailure(rawError: String) {
        consoleTrace("handleHealthFailure rawError=\(rawError)")
        let isStillStarting = queue.sync { state.status == .starting || state.status == .retrying }
        if isStillStarting {
            let failureCount = queue.sync { state.consecutiveHealthFailures + 1 }
            consoleTrace("handleHealthFailure still starting/retrying failureCount=\(failureCount)")
            publish { summary in
                summary.lastHealthCheckAt = Date()
                summary.consecutiveHealthFailures = failureCount
            }
            return
        }

        let portUsers = findListeningPidsOnEnginePort()
        let adoptedPID = queue.sync { adoptedProcessIdentifier }
        let adoptedProcessDisappeared = adoptedPID.map { !processExists(pid: $0) } ?? false
        consoleTrace("handleHealthFailure portUsers=\(portUsers.map(String.init).joined(separator: ",")) adoptedPID=\(adoptedPID.map(String.init) ?? "nil") adoptedDisappeared=\(adoptedProcessDisappeared)")
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

        let failureCount = queue.sync { state.consecutiveHealthFailures + 1 }
        let status: EngineStatus = failureCount >= 3 ? .stalled : .degraded
        consoleTrace("handleHealthFailure marking status=\(status.rawValue) failureCount=\(failureCount)")
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
            consoleTrace("handleHealthFailure failureCount >= 3; forcing recovery restart")
            forceTerminateForRecovery()
            scheduleRestart(cause: issue)
        }
    }

    private func handleStartupDeadline() async {
        consoleTrace("handleStartupDeadline fired")
        let shouldFail = queue.sync {
            state.status == .starting && state.lastSuccessfulHealthCheckAt == nil
        }
        guard shouldFail else {
            consoleTrace("handleStartupDeadline ignored because startup already succeeded or status changed")
            return
        }
        consoleTrace("handleStartupDeadline failing startup")
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

    private func handleStartupProcessUnavailable(rawError: String) {
        consoleTrace("handleStartupProcessUnavailable rawError=\(rawError)")
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
        consoleTrace("handleTermination statusCode=\(statusCode)")
        let shouldIgnoreRecoveryExit = queue.sync {
            process == nil && (state.status == .retrying || state.status == .timedOut || state.status == .stalled)
        }
        if shouldIgnoreRecoveryExit {
            consoleTrace("handleTermination ignoring recovery exit")
            return
        }

        let intentional = queue.sync { isStopping }
        if intentional {
            consoleTrace("handleTermination intentional stop")
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

        consoleTrace("handleTermination unexpected exit; scheduling restart")
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
        consoleTrace("forceTerminateForRecovery called")
        let adoptedPID = queue.sync { () -> Int32? in
            isStopping = false
            process?.terminate()
            process = nil
            let pid = adoptedProcessOwnership == .launchedByApp ? adoptedProcessIdentifier : nil
            if let adoptedProcessIdentifier, adoptedProcessOwnership == .external {
                consoleTrace("forceTerminateForRecovery detaching from external adopted pid=\(adoptedProcessIdentifier)")
            }
            adoptedProcessIdentifier = nil
            adoptedProcessOwnership = .none
            state.pid = nil
            return pid
        }
        if let adoptedPID {
            consoleTrace("forceTerminateForRecovery terminating adoptedPID=\(adoptedPID)")
            _ = runKill(signal: "-TERM", pids: [adoptedPID])
        } else {
            consoleTrace("forceTerminateForRecovery no adoptedPID to terminate")
        }
    }

    private func scheduleRestart(cause: EngineIssue) {
        consoleTrace("scheduleRestart cause=\(cause.code) rawError=\(cause.rawError ?? "nil")")
        restartTask?.cancel()

        let nextRetry = queue.sync { state.retryCount + 1 }
        guard nextRetry <= AppConfig.maxEngineRestartAttempts else {
            consoleTrace("scheduleRestart hit retry limit nextRetry=\(nextRetry)")
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
        consoleTrace("scheduleRestart attempt=\(nextRetry) delay=\(delay)")
        let wave = queue.sync {
            restartGeneration &+= 1
            return restartGeneration
        }
        restartTask = Task { [weak self] in
            guard let self else { return }
            self.consoleTrace("restartTask started wave=\(wave)")
            self.queue.sync {
                if self.restartGeneration == wave {
                    self.restartWorkActive = true
                }
            }
            defer {
                self.queue.sync {
                    if self.restartGeneration == wave {
                        self.restartWorkActive = false
                    }
                }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                self.consoleTrace("restartTask cancelled before launch wave=\(wave)")
                return
            }
            do {
                guard self.queue.sync(execute: { self.restartGeneration == wave }) else {
                    self.consoleTrace("restartTask generation superseded before launch wave=\(wave)")
                    return
                }
                let launchWave = self.queue.sync { () -> UInt64 in
                    self.launchGeneration &+= 1
                    return self.launchGeneration
                }
                self.consoleTrace("restartTask attempting clean slate and launch wave=\(wave)")
                self.establishCleanSlate()
                try self.launchProcess(resetRetryCount: false, generation: launchWave)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.consoleTrace("restartTask launch cancelled")
                    return
                }
                self.consoleTrace("restartTask launch failed error=\(error.localizedDescription)")
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
        consoleTrace("record issue=\(issue.code) status=\(status.rawValue) notifyUser=\(notifyUser) rawError=\(issue.rawError ?? "nil") context=\(issue.context)")
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
        consoleTrace("publish status=\(summary.status.rawValue) pid=\(summary.pid.map(String.init) ?? "nil") retry=\(summary.retryCount) failures=\(summary.consecutiveHealthFailures) latestIssue=\(summary.latestIssue?.code ?? "nil")")
        onHealthChanged?(summary)
    }

    private func runKill(signal: String, pids: [Int32]) -> Bool {
        consoleTrace("runKill signal=\(signal) pids=\(pids.map(String.init).joined(separator: ","))")
        guard !pids.isEmpty else { return true }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/kill")
        proc.arguments = [signal] + pids.map { String($0) }
        do {
            try proc.run()
            proc.waitUntilExit()
            consoleTrace("runKill completed status=\(proc.terminationStatus)")
            return proc.terminationStatus == 0
        } catch {
            consoleTrace("runKill failed error=\(error.localizedDescription)")
            return false
        }
    }

    private func canAdoptRunningEngine(portUsers: [Int32]) -> Bool {
        consoleTrace("canAdoptRunningEngine portUsers=\(portUsers.map(String.init).joined(separator: ","))")
        guard isLikelyRecoverableEngineOwner(portUsers: portUsers) else { return false }
        return checkHealthSynchronously(timeout: timeoutPolicy.healthCheckTimeout)
    }

    private func adoptExistingEngine(portUsers: [Int32], resetRetryCount: Bool, ownership: EngineProcessOwnership) {
        consoleTrace("adoptExistingEngine portUsers=\(portUsers.map(String.init).joined(separator: ",")) resetRetryCount=\(resetRetryCount) ownership=\(ownership)")
        let pid = portUsers.first
        let summary = queue.sync { () -> EngineHealthSummary in
            if resetRetryCount {
                state.retryCount = 0
                state.recentIssues = []
                state.latestIssue = nil
            }
            process = nil
            adoptedProcessIdentifier = pid
            adoptedProcessOwnership = ownership
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
        consoleTrace("adoptExistingEngine completed pid=\(pid.map(String.init) ?? "nil")")
        onHealthChanged?(summary)
        startMonitoring()
    }

    private func reclaimPortUsers(_ pids: [Int32]) {
        consoleTrace("reclaimPortUsers pids=\(pids.map(String.init).joined(separator: ","))")
        guard !pids.isEmpty else { return }
        _ = runKill(signal: "-TERM", pids: pids)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if findListeningPidsOnEnginePort().isEmpty {
                consoleTrace("reclaimPortUsers port vacant after TERM")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        consoleTrace("reclaimPortUsers escalating to KILL")
        _ = runKill(signal: "-KILL", pids: pids)
        waitUntilEnginePortVacant(timeout: 4.0)
    }

    private func establishCleanSlate() {
        consoleTrace("establishCleanSlate starting")
        let pids = recoverableEngineProcessIDs()
        consoleTrace("establishCleanSlate recoverable pids=\(pids.map(String.init).joined(separator: ","))")
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
        consoleTrace("establishCleanSlate remaining after TERM=\(remaining.map(String.init).joined(separator: ","))")
        if !remaining.isEmpty {
            _ = runKill(signal: "-KILL", pids: remaining)
        }
        waitUntilEnginePortVacant(timeout: 4.0)

        queue.sync {
            process = nil
            adoptedProcessIdentifier = nil
            adoptedProcessOwnership = .none
            isStopping = false
            state.pid = nil
            state.activeJobID = nil
            state.consecutiveHealthFailures = 0
        }
        consoleTrace("establishCleanSlate completed")
    }

    private func recoverableEngineProcessIDs() -> [Int32] {
        consoleTrace("recoverableEngineProcessIDs scanning")
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
            consoleTrace("recoverableEngineProcessIDs ps failed error=\(error.localizedDescription); returning pids=\(Array(pids).map(String.init).joined(separator: ","))")
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

        let result = Array(pids)
        consoleTrace("recoverableEngineProcessIDs result=\(result.map(String.init).joined(separator: ","))")
        return result
    }

    private func isLikelyRecoverableEngineOwner(portUsers: [Int32]) -> Bool {
        let result = portUsers.contains { pid in
            isRecoverableEngineCommand(processCommandLine(for: pid))
        }
        consoleTrace("isLikelyRecoverableEngineOwner pids=\(portUsers.map(String.init).joined(separator: ",")) result=\(result)")
        return result
    }

    private func isRecoverableEngineCommand(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        let kokoroPath = AppConfig.kokoroPath.lowercased()
        let result = lowercased.contains("kokoro_server")
            || (lowercased.contains("uvicorn") && lowercased.contains("kokoro"))
            || (lowercased.contains(kokoroPath) && lowercased.contains("python"))
        return result
    }

    private func processCommandLine(for pid: Int32) -> String {
        consoleTrace("processCommandLine pid=\(pid)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "command="]
        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            consoleTrace("processCommandLine ps failed pid=\(pid) error=\(error.localizedDescription)")
            return ""
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        consoleTrace("processCommandLine pid=\(pid) status=\(proc.terminationStatus) command=\(command)")
        return command
    }

    private func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let mibLength = UInt32(mib.count)
        let ok = mib.withUnsafeMutableBufferPointer { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return sysctl(base, mibLength, &info, &size, nil, 0) == 0
        }
        return ok && size > 0 && info.kp_proc.p_pid != 0
    }

    private func checkHealthSynchronously(timeout: TimeInterval) -> Bool {
        consoleTrace("checkHealthSynchronously timeout=\(timeout)")
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
            consoleTrace("checkHealthSynchronously timed out")
            return false
        }
        consoleTrace("checkHealthSynchronously result=\(isHealthy)")
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
