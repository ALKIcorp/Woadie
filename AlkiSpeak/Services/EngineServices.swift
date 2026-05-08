import Foundation

final class ProcessEngineSupervisor: EngineSupervising {
    private var process: Process?
    private var isStopping = false
    var onUnexpectedTermination: ((Int32) -> Void)?

    var isRunning: Bool { process != nil }
    var processIdentifier: Int32? { process?.processIdentifier }

    func start() throws {
        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [
            "-lc",
            "cd \"\(AppConfig.kokoroPath)\"; source .venv/bin/activate; uvicorn kokoro_server:app --host 127.0.0.1 --port \(AppConfig.enginePort)"
        ]
        proc.standardError = Pipe()
        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            if self.isStopping {
                self.isStopping = false
                self.process = nil
                return
            }
            self.process = nil
            self.onUnexpectedTermination?(process.terminationStatus)
        }

        try proc.run()
        process = proc
    }

    func stop() {
        guard let process else { return }
        isStopping = true
        process.terminate()
        self.process = nil
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
}

final class KokoroSpeechGenerationService: SpeechGenerating {
    func checkHealth() async -> Bool {
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
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

    func synthesize(text: String, voice: String) async throws -> SpeechGenerationResult {
        var request = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice": voice,
            "rate": AppConfig.defaultRate
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlkiSpeakError.generation(
                code: "missing-http-response",
                title: "No Server Response",
                message: "The speech request did not return an HTTP response.",
                recoverySuggestion: "Restart the engine and try again."
            )
        }
        guard http.statusCode == 200 else {
            throw AlkiSpeakError.generation(
                code: "http-\(http.statusCode)",
                title: "Speech Request Failed",
                message: "The speech server returned \(http.statusCode).",
                recoverySuggestion: "Check the text and selected voice, then try again.",
                context: ["statusCode": "\(http.statusCode)"]
            )
        }

        return SpeechGenerationResult(
            audioData: data,
            latencyMs: http.value(forHTTPHeaderField: "X-Gen-ms").flatMap(Int.init),
            charCount: http.value(forHTTPHeaderField: "X-Char-Count").flatMap(Int.init)
        )
    }
}
