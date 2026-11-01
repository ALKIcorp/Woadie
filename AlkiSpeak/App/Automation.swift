import AVFoundation
import Foundation
import Network
import os

// MARK: - alkispeak:// links

/// What an `alkispeak://` link asks for:
/// `alkispeak://speak?text=Hello&voice=edge:en-US-AriaNeural`,
/// `alkispeak://stop`, `alkispeak://pause` (pause or resume).
enum AutomationCommand: Equatable {
    case speak(text: String, voice: String?)
    case stop
    case pauseOrResume

    static let scheme = "alkispeak"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `alkispeak://speak` puts the command in the host; `alkispeak:speak` in the path.
        let command = (components.host ?? components.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        switch command {
        case "speak":
            guard let text = value("text") else { return nil }
            self = .speak(text: text, voice: value("voice"))
        case "stop":
            self = .stop
        case "pause", "resume", "toggle":
            self = .pauseOrResume
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

enum AutomationVoices {
    /// The voice a request names: an exact ID, or an available voice whose
    /// name or label matches, ignoring case. No name means `selected`.
    static func resolve(_ query: String?, in options: [VoiceOption], selected: String) -> String? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return selected
        }
        let usable = options.filter(\.isAvailable)
        if let exact = usable.first(where: { $0.id == query }) { return exact.id }
        return usable.first {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.label.caseInsensitiveCompare(query) == .orderedSame
        }?.id
    }
}

// MARK: - Joining clips

enum AudioJoiner {
    /// One 16-bit WAV from several clips (WAV or MP3, any sample rate),
    /// at the first clip's sample rate, mono.
    static func wav(from clips: [Data]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlkiSpeakJoin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var sources: [AVAudioFile] = []
        for (index, data) in clips.enumerated() {
            // AVAudioFile sniffs the format, but needs a plausible extension.
            let isWAV = data.prefix(4) == Data("RIFF".utf8)
            let url = directory.appendingPathComponent("\(index).\(isWAV ? "wav" : "mp3")")
            try data.write(to: url)
            sources.append(try AVAudioFile(forReading: url))
        }
        guard let first = sources.first else { return Data() }
        let sampleRate = first.processingFormat.sampleRate

        let outputURL = directory.appendingPathComponent("joined.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            for source in sources {
                let file: AVAudioFile
                if source.processingFormat.sampleRate == sampleRate, source.processingFormat.channelCount == 1 {
                    file = source
                } else {
                    file = try AVAudioFile(forReading: AVAudioPlaybackCoordinator.convert(source, toSampleRate: sampleRate, channels: 1))
                }
                try output.write(from: file.readAll())
            }
        }
        return try Data(contentsOf: outputURL)
    }
}

// MARK: - Local speech API

struct LocalAPISettings: Codable, Equatable {
    var enabled = false
    var port: UInt16 = 7790

    static let defaultsKey = "AlkiSpeak.localAPI"
    /// The bearer token lives in the Keychain under this account.
    static let tokenAccount = "local-speech-api"

    static func load(from defaults: UserDefaults = .standard) -> LocalAPISettings {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(LocalAPISettings.self, from: $0) } ?? LocalAPISettings()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Parses a complete request, or returns nil if more bytes are needed.
    /// Throws for something that isn't HTTP or is too large.
    static func parse(_ data: Data, maxBody: Int = 1 << 20) throws -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16 * 1024 { throw HTTPError.badRequest("Headers too large") }
            return nil
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { throw HTTPError.badRequest("Headers aren't UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw HTTPError.badRequest("Malformed request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { throw HTTPError.payloadTooLarge }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        )
    }
}

enum HTTPError: Error, Equatable {
    case badRequest(String)
    case payloadTooLarge
}

struct HTTPResponse: Equatable {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    /// OpenAI-style error body.
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": ["message": message, "type": "alkispeak_error"]])
    }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }
}

/// A tiny HTTP server on 127.0.0.1 so scripts and agents on this Mac can
/// speak through AlkiSpeak. Every request needs `Authorization: Bearer
/// <token>`; it only listens on the loopback interface.
final class LocalSpeechAPIServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.alki.Woadie", category: "LocalAPI")
    private let port: UInt16
    private let token: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let onFailure: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.alki.Woadie.local-api")
    private var listener: NWListener?

    init(
        port: UInt16,
        token: String,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.port = port
        self.token = token
        self.handler = handler
        self.onFailure = onFailure
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw HTTPError.badRequest("Invalid port") }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        // Bound to 127.0.0.1 itself, not every interface.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [logger, port, onFailure] state in
            if case .failed(let error) = state {
                logger.error("Local API listener on port \(port) failed: \(error.localizedDescription, privacy: .public)")
                if case .posix(.EADDRINUSE) = error {
                    onFailure("Port \(port) is already in use. Pick another port.")
                } else {
                    onFailure(error.localizedDescription)
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        logger.info("Local API listening on 127.0.0.1:\(self.port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            do {
                if let request = try HTTPRequest.parse(buffer) {
                    Task {
                        let response = await self.respond(to: request)
                        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            } catch HTTPError.payloadTooLarge {
                self.reply(.error(413, "The request body is too large."), on: connection)
            } catch {
                self.reply(.error(400, "That isn't a valid HTTP request."), on: connection)
            }
        }
    }

    private func reply(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .error(401, "Send the token from Settings → Automation as 'Authorization: Bearer <token>'.")
        }
        return await handler(request)
    }
}

// MARK: - Routing

/// What the links, Shortcuts and the local API drive.
@MainActor
protocol SpeechAutomationTarget: AnyObject {
    var automationVoices: [VoiceOption] { get }
    var selectedVoice: String { get }
    func resolveAutomationVoice(_ query: String?) -> String?
    func speakExternalText(_ text: String, voice: String?)
    func renderAutomationAudio(text: String, voice: String) async throws -> Data
    func stopPlayback()
}

extension AppModel: SpeechAutomationTarget {
    var automationVoices: [VoiceOption] { voiceOptions.filter(\.isAvailable) }
}

/// The local API's endpoints:
/// - `GET /v1/voices`: the voices that can be used.
/// - `POST /v1/audio/speech` `{"input", "voice"?, "response_format"?}`: a WAV,
///   shaped like OpenAI's endpoint so existing clients work.
/// - `POST /v1/speak` `{"text", "voice"?}`: speaks out loud and returns at once.
/// - `POST /v1/stop`: stops speaking.
enum LocalAPIRouter {
    static let maxInputCharacters = 50_000

    @MainActor
    static func respond(to request: HTTPRequest, target: SpeechAutomationTarget) async -> HTTPResponse {
        // The `/v1` prefix is optional.
        let path = request.path.hasPrefix("/v1/") ? String(request.path.dropFirst(3)) : request.path
        switch (request.method, path) {
        case ("GET", "/voices"):
            let selected = target.selectedVoice
            let voices: [[String: Any]] = target.automationVoices.map {
                ["id": $0.id, "name": $0.name, "detail": $0.detail, "selected": $0.id == selected]
            }
            return .json(200, ["object": "list", "data": voices])

        case ("POST", "/audio/speech"):
            guard let body = jsonBody(request) else { return .error(400, "Send a JSON body.") }
            guard let input = text(body["input"]) else { return .error(400, "'input' is required.") }
            guard input.count <= maxInputCharacters else {
                return .error(413, "'input' is limited to \(maxInputCharacters.formatted()) characters.")
            }
            let format = (body["response_format"] as? String)?.lowercased() ?? "wav"
            guard format == "wav" else { return .error(400, "Only 'wav' is supported for 'response_format'.") }
            guard let voice = target.resolveAutomationVoice(body["voice"] as? String) else {
                return unknownVoice(body["voice"])
            }
            do {
                let audio = try await target.renderAutomationAudio(text: input, voice: voice)
                return HTTPResponse(status: 200, contentType: "audio/wav", body: audio, headers: ["X-AlkiSpeak-Voice": voice])
            } catch {
                return .error(503, (error as? AlkiSpeakError)?.message ?? error.localizedDescription)
            }

        case ("POST", "/speak"):
            guard let body = jsonBody(request) else { return .error(400, "Send a JSON body.") }
            guard let text = text(body["text"] ?? body["input"]) else { return .error(400, "'text' is required.") }
            guard text.count <= maxInputCharacters else {
                return .error(413, "'text' is limited to \(maxInputCharacters.formatted()) characters.")
            }
            guard let voice = target.resolveAutomationVoice(body["voice"] as? String) else {
                return unknownVoice(body["voice"])
            }
            target.speakExternalText(text, voice: voice)
            return .json(202, ["status": "speaking", "voice": voice])

        case ("POST", "/stop"):
            target.stopPlayback()
            return .json(200, ["status": "stopped"])

        case (_, "/voices"), (_, "/audio/speech"), (_, "/speak"), (_, "/stop"):
            return .error(405, "\(request.method) isn't supported here.")

        default:
            return .error(404, "No endpoint at \(request.path). Try GET /v1/voices.")
        }
    }

    private static func jsonBody(_ request: HTTPRequest) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func unknownVoice(_ value: Any?) -> HTTPResponse {
        .error(400, "No voice called '\(value as? String ?? "")'. GET /v1/voices lists them.")
    }
}

// MARK: - Running the API

/// Starts and stops the local API to match its settings, and holds its token.
@MainActor
@Observable
final class LocalAPIController {
    static let shared = LocalAPIController()

    private(set) var settings = LocalAPISettings.load()
    /// Listening on this port, or nil when off.
    private(set) var runningPort: UInt16?
    private(set) var errorMessage: String?

    @ObservationIgnored weak var target: SpeechAutomationTarget?
    @ObservationIgnored var secrets: SecretStoring?
    @ObservationIgnored private var server: LocalSpeechAPIServer?

    var token: String? { secrets?.secret(for: LocalAPISettings.tokenAccount) }

    func configure(target: SpeechAutomationTarget, secrets: SecretStoring) {
        self.target = target
        self.secrets = secrets
        restart()
    }

    func update(_ change: (inout LocalAPISettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        settings.save()
        restart()
    }

    func regenerateToken() {
        try? secrets?.setSecret(LocalAPISettings.makeToken(), for: LocalAPISettings.tokenAccount)
        restart()
    }

    private func restart() {
        server?.stop()
        server = nil
        runningPort = nil
        errorMessage = nil
        guard settings.enabled, let secrets else { return }
        var token = secrets.secret(for: LocalAPISettings.tokenAccount) ?? ""
        if token.isEmpty {
            token = LocalAPISettings.makeToken()
            do {
                try secrets.setSecret(token, for: LocalAPISettings.tokenAccount)
            } catch {
                errorMessage = "Couldn't save the API token to the Keychain."
                return
            }
        }
        let port = settings.port
        let server = LocalSpeechAPIServer(
            port: port,
            token: token,
            handler: { [weak self] request in
                await self?.handle(request) ?? .error(503, "AlkiSpeak is shutting down.")
            },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    self?.runningPort = nil
                    self?.errorMessage = message
                }
            }
        )
        do {
            try server.start()
            self.server = server
            runningPort = port
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let target else { return .error(503, "AlkiSpeak isn't ready yet.") }
        return await LocalAPIRouter.respond(to: request, target: target)
    }
}
