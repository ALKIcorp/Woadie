import CryptoKit
import Foundation
import os.log

/// Speaks through Microsoft Edge's online neural TTS (the same engine the
/// `edge-tts` project wraps). No API key is required; the client just has to
/// present the same trusted-client token and DRM header Edge itself sends.
///
/// Voice IDs are prefixed with `"edge:"` (mirroring the existing `"apple:"`
/// convention for local voices) so `AppModel` can route requests to this
/// service without inspecting any other state.
final class EdgeSpeechGenerationService: SpeechGenerating {
    static let idPrefix = "edge:"

    private let logger = Logger(subsystem: "com.alki.Woadie", category: "EdgeTTS")
    private let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private let session: URLSession

    /// Microsoft gates the synthesis endpoint on a recent Chromium build number
    /// (sent both as the `Sec-MS-GEC-Version` query item and inside the
    /// User-Agent). When Edge requests start returning HTTP 403, bump this to
    /// the value shipped by the current `edge-tts` release (`constants.py`'s
    /// `CHROMIUM_FULL_VERSION`). The major component is derived for the UA.
    private let chromiumFullVersion = "143.0.3650.75"
    private var chromiumMajorVersion: String {
        String(chromiumFullVersion.prefix(while: { $0 != "." }))
    }
    private var secMSGECVersion: String { "1-\(chromiumFullVersion)" }
    private var userAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(chromiumMajorVersion).0.0.0 Safari/537.36 Edg/\(chromiumMajorVersion).0.0.0"
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkHealth() async -> Bool {
        var request = URLRequest(url: voicesListURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyVoiceHeaders(to: &request)
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func fetchVoices() async throws -> [String] {
        var request = URLRequest(url: voicesListURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applyVoiceHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AlkiSpeakError.engine(
                code: "edge.voices.http",
                title: "Edge Voice Fetch Failed",
                message: "Failed to fetch the Edge voice list.",
                recoverySuggestion: "Check the network connection and try refreshing voices."
            )
        }
        let entries = try JSONDecoder().decode([EdgeVoiceEntry].self, from: data)
        return entries.map { Self.idPrefix + $0.shortName }
    }

    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        let voiceName = Self.stripPrefix(voice)
        let startedAt = Date()
        do {
            let audioData = try await requestAudio(text: text, voiceName: voiceName)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info("Edge synthesis complete job=\(jobID?.uuidString ?? "none", privacy: .public) chars=\(text.count) elapsedMs=\(elapsedMs)")
            return SpeechGenerationResult(audioData: audioData, latencyMs: elapsedMs, charCount: text.count)
        } catch is CancellationError {
            throw AlkiSpeakError.generation(
                code: "cancelled",
                title: "Speech Request Cancelled",
                message: "The Edge speech request was cancelled before completion.",
                recoverySuggestion: "Start a new generation request when ready."
            )
        } catch let error as AlkiSpeakError {
            throw error
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            throw AlkiSpeakError.generation(
                code: "edge.request-failed",
                title: "Edge Speech Request Failed",
                message: "The Edge voice request failed after \(elapsedMs) ms.",
                recoverySuggestion: "Check the network connection and retry.",
                underlyingError: error
            )
        }
    }

    static func stripPrefix(_ voiceID: String) -> String {
        voiceID.hasPrefix(idPrefix) ? String(voiceID.dropFirst(idPrefix.count)) : voiceID
    }

    // MARK: - WebSocket synthesis

    private func requestAudio(text: String, voiceName: String) async throws -> Data {
        var request = URLRequest(url: synthesisURL())
        // The synthesis endpoint 403s a bare handshake — it requires the same
        // browser-identifying headers and MUID cookie that Edge sends.
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(Self.generateMUID());", forHTTPHeaderField: "Cookie")

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await task.send(.string(speechConfigMessage()))
        try await task.send(.string(ssmlMessage(requestID: requestID, voiceName: voiceName, text: text)))

        var audio = Data()
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let frame):
                if let chunk = Self.audioPayload(fromBinaryFrame: frame) {
                    audio.append(chunk)
                }
            case .string(let text):
                if text.contains("Path:turn.end") {
                    return audio
                }
                if text.contains("Path:response") || text.contains("Path:turn.start") {
                    continue
                }
            @unknown default:
                continue
            }
        }
    }

    /// Binary frames are `[2-byte big-endian header length][headers][audio bytes]`.
    private static func audioPayload(fromBinaryFrame frame: Data) -> Data? {
        guard frame.count > 2 else { return nil }
        let headerLength = Int(frame[0]) << 8 | Int(frame[1])
        let payloadStart = 2 + headerLength
        guard frame.count > payloadStart else { return nil }
        return frame.subdata(in: payloadStart..<frame.count)
    }

    private func speechConfigMessage() -> String {
        let timestamp = Self.xTimestamp()
        let body = """
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"\(outputFormat)"}}}}
        """
        return "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(body)"
    }

    private func ssmlMessage(requestID: String, voiceName: String, text: String) -> String {
        let timestamp = Self.xTimestamp()
        let escaped = Self.escapeForSSML(text)
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(voiceName)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escaped)</prosody></voice></speak>
        """
        return "X-RequestId:\(requestID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)\r\nPath:ssml\r\n\r\n\(ssml)"
    }

    private static func escapeForSSML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func xTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    // MARK: - Endpoints & DRM

    private func voicesListURL() -> URL {
        var components = URLComponents(string: "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list")!
        components.queryItems = [
            URLQueryItem(name: "trustedclienttoken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: Self.generateSecMSGEC(trustedClientToken: trustedClientToken)),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMSGECVersion)
        ]
        return components.url!
    }

    /// Browser-identifying headers Edge sends with the voices request. The
    /// endpoint currently tolerates their absence, but the synthesis endpoint
    /// does not — keeping them in sync future-proofs against the same gating.
    private func applyVoiceHeaders(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("muid=\(Self.generateMUID());", forHTTPHeaderField: "Cookie")
    }

    private func synthesisURL() -> URL {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secMSGEC = Self.generateSecMSGEC(trustedClientToken: trustedClientToken)
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID),
            URLQueryItem(name: "Sec-MS-GEC", value: secMSGEC),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMSGECVersion)
        ]
        return components.url!
    }

    /// Edge requires a rolling DRM token derived from the current time, rounded
    /// down to the nearest 5-minute boundary, converted to Windows file-time
    /// ticks (100-nanosecond intervals since 1601), and hashed with the trusted
    /// client token. Mirrors `edge-tts`'s `DRM.generate_sec_ms_gec`. Uses exact
    /// integer math so the ~10^17 tick value never loses precision.
    private static func generateSecMSGEC(trustedClientToken: String) -> String {
        let windowsEpochOffset: Int64 = 11_644_473_600
        var seconds = Int64(Date().timeIntervalSince1970) + windowsEpochOffset
        seconds -= seconds % 300
        let ticks = seconds * 10_000_000
        let toHash = "\(ticks)\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(toHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Random 32-character uppercase-hex MUID, matching `edge-tts`'s
    /// `secrets.token_hex(16).upper()`, sent as the `muid` cookie.
    private static func generateMUID() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }
}

private struct EdgeVoiceEntry: Decodable {
    let shortName: String

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName"
    }
}
