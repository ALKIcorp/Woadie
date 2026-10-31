import Darwin
import Foundation
import os.log

/// Keeps a local voice server available for cloud voices that point at it.
protocol LocalVoiceServerEnsuring: AnyObject {
    /// Returns once the server answers, launching it first if nothing is listening.
    func ensureRunning() async throws
    /// Stops the server only if this app launched it; an adopted server is left alone.
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
    private let lock = NSLock()
    private var process: Process?
    private var launchTask: Task<Void, Error>?

    init(
        executableURL: URL = MLXAudioServerManager.defaultExecutableURL,
        port: Int = MLXAudioServerManager.port,
        session: URLSession = .shared,
        startupTimeout: TimeInterval = 90
    ) {
        self.executableURL = executableURL
        self.port = port
        self.session = session
        self.startupTimeout = startupTimeout
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
        lock.withLock { process?.isRunning ?? false }
    }

    func ensureRunning() async throws {
        if await isResponding() { return }
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

    func stopOwnedServer() {
        let owned = lock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        guard let owned, owned.isRunning else { return }
        logger.info("Stopping mlx-audio server pid=\(owned.processIdentifier)")
        owned.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while owned.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if owned.isRunning {
            Darwin.kill(owned.processIdentifier, SIGKILL)
        }
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
            if let logURL = Self.logURL, let handle = Self.openLog(at: logURL) {
                proc.standardOutput = handle
                proc.standardError = handle
            } else {
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
            }
            try proc.run()
            process = proc
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
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let directory = base.appendingPathComponent("Woadie", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("mlx-audio-server.log")
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
