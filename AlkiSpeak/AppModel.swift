import Foundation
import AVFoundation
import SwiftUI

enum EngineStatus: String {
    case off
    case warmingUp
    case on
    case error

    var label: String {
        switch self {
        case .off: return "OFF"
        case .warmingUp: return "WARMING UP"
        case .on: return "ON"
        case .error: return "ERROR"
        }
    }

    var color: Color {
        switch self {
        case .off: return .secondary
        case .warmingUp: return .orange
        case .on: return .green
        case .error: return .red
        }
    }
}

enum AppConfig {
    static let kokoroPath = "/Volumes/ALKI SD/MACBOOK PRO STORAGE/ALKI Corp Dev/tts/kokoro"
    static let serverBaseURL = URL(string: "http://127.0.0.1:7777")!
    static let defaultVoice = "af_heart"
    static let defaultRate = 24000
    static let healthTimeoutSeconds: TimeInterval = 20
}

@MainActor
final class AppModel: ObservableObject {
    struct ChatItem: Identifiable {
        let id = UUID()
        let text: String
        let isUser: Bool
    }

    @Published var status: EngineStatus = .off
    @Published var voices: [String] = [AppConfig.defaultVoice]
    @Published var selectedVoice: String = AppConfig.defaultVoice
    @Published var inputText: String = ""
    @Published var lastLatencyMs: Int? = nil
    @Published var message: String = ""
    @Published var chatItems: [ChatItem] = []
    @Published var showPortInUseAlert: Bool = false
    @Published var portInUsePids: [Int32] = []

    private var process: Process?
    private var audioPlayer: AVAudioPlayer?
    private var isStopping = false

    var canSpeak: Bool {
        status == .on && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEngineRunning: Bool {
        process != nil
    }

    var startStopLabel: String {
        isEngineRunning ? "Stop Engine" : "Start Engine"
    }

    var lastLatencyMsText: String {
        if let lastLatencyMs {
            return "\(lastLatencyMs) ms"
        }
        return "—"
    }

    func startEngine() {
        guard process == nil else { return }
        message = ""
        status = .warmingUp

        let pids = findListeningPidsOnPort()
        if !pids.isEmpty {
            status = .off
            message = "Port 7777 is already in use."
            portInUsePids = pids
            showPortInUseAlert = true
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [
            "-lc",
            "cd \"\(AppConfig.kokoroPath)\"; source .venv/bin/activate; uvicorn kokoro_server:app --host 127.0.0.1 --port 7777"
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isStopping {
                    self.isStopping = false
                    self.process = nil
                    self.status = .off
                    return
                }
                self.process = nil
                self.status = .error
                self.message = "Engine stopped unexpectedly (code \(process.terminationStatus))."
            }
        }

        do {
            try proc.run()
            process = proc
            Task { await waitForHealth() }
        } catch {
            status = .error
            message = "Failed to start engine: \(error.localizedDescription)"
        }
    }

    func stopEngine() {
        guard let process else { return }
        isStopping = true
        message = ""
        status = .off
        process.terminate()
        self.process = nil
    }

    func toggleEngine() {
        if isEngineRunning {
            stopEngine()
        } else {
            startEngine()
        }
    }

    func refreshVoices() {
        Task {
            await fetchVoices()
        }
    }

    func speak() {
        guard canSpeak else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        chatItems.append(ChatItem(text: text, isUser: true))

        Task {
            do {
                let data = try await postSpeak(text: text, voice: selectedVoice)
                try playAudio(data: data)
            } catch {
                status = .error
                message = "Speak failed: \(error.localizedDescription)"
                chatItems.append(ChatItem(text: "Error: \(error.localizedDescription)", isUser: false))
            }
        }
    }

    private func waitForHealth() async {
        let deadline = Date().addingTimeInterval(AppConfig.healthTimeoutSeconds)
        while Date() < deadline {
            if await checkHealth() {
                status = .on
                message = ""
                await fetchVoices()
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        status = .error
        message = "Engine health check timed out."
    }

    private func checkHealth() async -> Bool {
        var req = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (obj?["ok"] as? Bool) == true
        } catch {
            return false
        }
    }

    private func fetchVoices() async {
        var req = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("voices"))
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                message = "Failed to fetch voices."
                return
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let voices = obj?["voices"] as? [String] ?? []
            if voices.isEmpty {
                message = "Voice list empty. Using last voice."
                return
            }
            self.voices = voices
            if !voices.contains(selectedVoice) {
                selectedVoice = voices.first ?? AppConfig.defaultVoice
            }
        } catch {
            message = "Failed to fetch voices: \(error.localizedDescription)"
        }
    }

    private func postSpeak(text: String, voice: String) async throws -> Data {
        var req = URLRequest(url: AppConfig.serverBaseURL.appendingPathComponent("speak"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "text": text,
            "voice": voice,
            "rate": AppConfig.defaultRate
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AlkiSpeak", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]) 
        }
        if let msString = http.value(forHTTPHeaderField: "X-Gen-ms"), let ms = Int(msString) {
            lastLatencyMs = ms
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "AlkiSpeak", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"]) 
        }
        return data
    }

    private func playAudio(data: Data) throws {
        audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
    }

    func confirmPortSwitchAndStart() {
        Task {
            await terminatePortUsers()
            startEngine()
        }
    }

    private func findListeningPidsOnPort() -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = [
            "-tiTCP:7777",
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

    private func terminatePortUsers() async {
        let pids = portInUsePids
        guard !pids.isEmpty else { return }

        // Try graceful shutdown first.
        _ = runKill(signal: "-TERM", pids: pids)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if findListeningPidsOnPort().isEmpty {
                portInUsePids = []
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Force kill if still listening.
        _ = runKill(signal: "-KILL", pids: pids)
        portInUsePids = []
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
