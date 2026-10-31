import Darwin
import Foundation
import os.log

/// Keeps a local voice server available for cloud voices that point at it.
protocol LocalVoiceServerEnsuring: AnyObject {
    /// Returns once the server answers, launching it first if nothing is listening.
    func ensureRunning() async throws
    /// Downloads (if needed) and loads a model, with no request time limit,
    /// so a first-time multi-GB download can't hit the speech timeout.
    func prepareModel(_ modelID: String) async throws
    /// Stops the server only if this app launched it (this run or, via the
    /// PID file, a run that was force-quit); a server started by hand is left alone.
    func stopOwnedServer()
}

/// Launches and supervises `mlx_audio.server` for the "Local mlx-audio" preset,
/// the same way `EngineManager` supervises Kokoro: probe first and adopt a
/// server that is already up, otherwise spawn one, wait for `/v1/models` to
/// answer, and terminate it when the app quits. Concurrent callers share one
/// launch, so a burst of segments never spawns two servers.
final class MLXAudioServerManager: LocalVoiceServerEnsuring, @unchecked Sendable {
    static let shared = MLXAudioServerManager()

    /// The preset's base URL (`http://localhost:8000/v1`) is fixed, so the
    /// supervised server binds that port on loopback only.
    static let port = 8000

    private let logger = Logger(subsystem: "com.alki.Woadie", category: "MLXAudioServer")
    private let executableURL: URL
    private let port: Int
    private let session: URLSession
    private let startupTimeout: TimeInterval
    private let pidFileURL: URL?
    private let isServerProcess: (pid_t) -> Bool
    private let lock = NSLock()
    private var process: Process?
    /// A server a force-quit run launched, found through the PID file.
    private var reclaimedPID: pid_t?
    private var launchTask: Task<Void, Error>?
    private var preparedModels: Set<String> = []
    private var prepareTasks: [String: Task<Void, Error>] = [:]

    init(
        executableURL: URL = MLXAudioServerManager.defaultExecutableURL,
        port: Int = MLXAudioServerManager.port,
        session: URLSession = .shared,
        startupTimeout: TimeInterval = 90,
        pidFileURL: URL? = MLXAudioServerManager.defaultPIDFileURL,
        isServerProcess: @escaping (pid_t) -> Bool = MLXAudioServerManager.isMLXAudioServerProcess
    ) {
        self.executableURL = executableURL
        self.port = port
        self.session = session
        self.startupTimeout = startupTimeout
        self.pidFileURL = pidFileURL
        self.isServerProcess = isServerProcess
    }

    /// `~/.venvs/mlx-audio/bin/mlx_audio.server`, overridable with `MLX_AUDIO_SERVER`.
    static var defaultExecutableURL: URL {
        if let env = ProcessInfo.processInfo.environment["MLX_AUDIO_SERVER"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: env.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".venvs/mlx-audio/bin/mlx_audio.server")
    }

    var isOwnedServerRunning: Bool {
        lock.withLock { (process?.isRunning ?? false) || reclaimedPID != nil }
    }

    func ensureRunning() async throws {
        if await isResponding() {
            reclaimOrphanIfNeeded()
            return
        }
        let task = lock.withLock { () -> Task<Void, Error> in
            if let launchTask { return launchTask }
            let task = Task { try await self.launchAndWait() }
            launchTask = task
            return task
        }
        do {
            try await task.value
            clearLaunchTask(task)
        } catch {
            clearLaunchTask(task)
            throw error
        }
    }

    func prepareModel(_ modelID: String) async throws {
        try await ensureRunning()
        let task = lock.withLock { () -> Task<Void, Error>? in
            if preparedModels.contains(modelID) { return nil }
            if let existing = prepareTasks[modelID] { return existing }
            let task = Task { try await self.loadModel(modelID) }
            prepareTasks[modelID] = task
            return task
        }
        guard let task else { return }
        do {
            try await task.value
            lock.withLock {
                preparedModels.insert(modelID)
                prepareTasks[modelID] = nil
            }
        } catch {
            lock.withLock { prepareTasks[modelID] = nil }
            throw error
        }
    }

    func stopOwnedServer() {
        let (owned, reclaimed) = lock.withLock { () -> (Process?, pid_t?) in
            defer {
                process = nil
                reclaimedPID = nil
                preparedModels = []
            }
            return (process, reclaimedPID)
        }
        if let owned, owned.isRunning {
            logger.info("Stopping mlx-audio server pid=\(owned.processIdentifier)")
            owned.terminate()
            waitForExit(pid: owned.processIdentifier) { owned.isRunning }
        } else if let reclaimed {
            logger.info("Stopping reclaimed mlx-audio server pid=\(reclaimed)")
            Darwin.kill(reclaimed, SIGTERM)
            waitForExit(pid: reclaimed) { Darwin.kill(reclaimed, 0) == 0 }
        }
        removePIDFile()
    }

    private func waitForExit(pid: pid_t, isAlive: () -> Bool) {
        let deadline = Date().addingTimeInterval(3.0)
        while isAlive() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isAlive() {
            Darwin.kill(pid, SIGKILL)
        }
    }

    // MARK: - Orphans

    /// If the PID file names a live mlx_audio.server, an earlier run launched
    /// it and then died without stopping it (e.g. force-quit from Xcode), so
    /// this run takes ownership and stops it on quit. A server the user
    /// started by hand has no PID file and stays theirs.
    private func reclaimOrphanIfNeeded() {
        lock.withLock {
            guard process == nil, reclaimedPID == nil, let pid = readPIDFile() else { return }
            if Darwin.kill(pid, 0) == 0, isServerProcess(pid) {
                reclaimedPID = pid
                logger.info("Reclaimed mlx-audio server left running by an earlier run pid=\(pid)")
            } else {
                removePIDFile()
            }
        }
    }

    static var defaultPIDFileURL: URL? {
        workingDirectoryURL?.appendingPathComponent("server.pid")
    }

    private func readPIDFile() -> pid_t? {
        guard let pidFileURL,
              let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }

    private func writePIDFile(_ pid: pid_t) {
        guard let pidFileURL else { return }
        try? "\(pid)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func removePIDFile() {
        guard let pidFileURL else { return }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// True when `pid`'s command line runs `mlx_audio.server`, so a recycled
    /// PID belonging to something else is never killed.
    static func isMLXAudioServerProcess(_ pid: pid_t) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return false }
        ps.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.contains("mlx_audio.server")
    }

    // MARK: - Models

    private func loadModel(_ modelID: String) async throws {
        guard var components = URLComponents(string: "http://127.0.0.1:\(port)/v1/models") else { return }
        components.queryItems = [URLQueryItem(name: "model_name", value: modelID)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The server answers only once the download and load finish; a
        // 3 GB model can take many minutes on a slow connection.
        request.timeoutInterval = 3600
        logger.info("Preparing mlx-audio model \(modelID, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = CloudSpeechGenerationService.providerMessage(from: data) ?? "HTTP \(status)"
            throw AlkiSpeakError.generation(
                code: "mlx.model-load",
                title: "Couldn't Load Local Model",
                message: "mlx-audio couldn't load \(modelID): \(detail)",
                recoverySuggestion: "Check the model ID and your internet connection, then try again."
            )
        }
    }

    /// The Hugging Face hub cache mlx-audio downloads into:
    /// `$HF_HUB_CACHE`, else `$HF_HOME/hub`, else `~/.cache/huggingface/hub`.
    static var huggingFaceHubCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"], !hub.isEmpty { return URL(fileURLWithPath: hub) }
        if let home = env["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    /// True once a model's snapshot exists with no partial blobs left, i.e.
    /// a first request won't have to download it.
    static func isModelDownloaded(_ modelID: String, hubCache: URL = huggingFaceHubCache) -> Bool {
        let repo = hubCache.appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(atPath: repo.appendingPathComponent("snapshots").path),
              !snapshots.isEmpty
        else { return false }
        let blobs = (try? fm.contentsOfDirectory(atPath: repo.appendingPathComponent("blobs").path)) ?? []
        return !blobs.contains { $0.hasSuffix(".incomplete") }
    }

    // MARK: - Launch

    private func clearLaunchTask(_ task: Task<Void, Error>) {
        lock.withLock {
            if launchTask == task { launchTask = nil }
        }
    }

    private func launchAndWait() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AlkiSpeakError.generation(
                code: "mlx.not-installed",
                title: "mlx-audio Not Installed",
                message: "Couldn't find the mlx-audio server at \(executableURL.path).",
                recoverySuggestion: "Install it into ~/.venvs/mlx-audio (pip install \"mlx-audio[server]\"), or set MLX_AUDIO_SERVER to its path."
            )
        }
        let proc = try launchIfNeeded()
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if await isResponding() {
                logger.info("mlx-audio server ready pid=\(proc.processIdentifier)")
                return
            }
            guard proc.isRunning else {
                throw AlkiSpeakError.generation(
                    code: "mlx.exited",
                    title: "mlx-audio Server Stopped",
                    message: "The mlx-audio server exited during startup (status \(proc.terminationStatus)).",
                    recoverySuggestion: "Check \(Self.logURL?.path ?? "the mlx-audio log") — port \(port) may be taken by another program."
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw AlkiSpeakError.generation(
            code: "mlx.startup-timeout",
            title: "mlx-audio Server Didn't Start",
            message: "The mlx-audio server didn't answer within \(Int(startupTimeout)) seconds.",
            recoverySuggestion: "Check \(Self.logURL?.path ?? "the mlx-audio log") and try again."
        )
    }

    private func launchIfNeeded() throws -> Process {
        try lock.withLock {
            if let process, process.isRunning { return process }
            let proc = Process()
            proc.executableURL = executableURL
            proc.arguments = ["--host", "127.0.0.1", "--port", "\(port)"]
            proc.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
            // mlx_audio.server creates ./logs on startup. An app launched from
            // Finder runs with cwd "/", which is read-only, so the server
            // would crash before binding the port.
            if let workingDirectory = Self.workingDirectoryURL {
                proc.currentDirectoryURL = workingDirectory
            }
            if let logURL = Self.logURL, let handle = Self.openLog(at: logURL) {
                proc.standardOutput = handle
                proc.standardError = handle
            } else {
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
            }
            try proc.run()
            process = proc
            preparedModels = []
            writePIDFile(proc.processIdentifier)
            logger.info("Launched mlx-audio server pid=\(proc.processIdentifier) port=\(self.port)")
            return proc
        }
    }

    private func isResponding() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Logging

    static var logURL: URL? {
        supportDirectory(named: nil)?.appendingPathComponent("mlx-audio-server.log")
    }

    /// `~/Library/Application Support/Woadie/mlx-audio`, the server's cwd.
    static var workingDirectoryURL: URL? {
        supportDirectory(named: "mlx-audio")
    }

    private static func supportDirectory(named child: String?) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        var directory = base.appendingPathComponent("Woadie", isDirectory: true)
        if let child { directory.appendPathComponent(child, isDirectory: true) }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return directory
    }

    private static func openLog(at url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}
