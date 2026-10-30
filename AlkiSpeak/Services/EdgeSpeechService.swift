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
    /// The `2-` prefix selects the v2 token format produced by `EdgeDRM`; the
    /// synthesis endpoint now rejects the old plain-SHA-256 `1-` tokens.
    private var secMSGECVersion: String { "2-\(chromiumFullVersion)" }
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
        // The trailing "Z" is intentional: Edge itself sends it on this frame.
        return "X-RequestId:\(requestID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)Z\r\nPath:ssml\r\n\r\n\(ssml)"
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

    private static func generateSecMSGEC(trustedClientToken: String) -> String {
        EdgeDRM.secMSGECv2(unixTime: Date().timeIntervalSince1970, trustedClientToken: trustedClientToken)
    }

    /// Random 32-character uppercase-hex MUID, matching `edge-tts`'s
    /// `secrets.token_hex(16).upper()`, sent as the `muid` cookie.
    private static func generateMUID() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Generates Edge's v2 `Sec-MS-GEC` DRM token: `"<CS64 hex>-<SHA-256 hex>"`.
///
/// The input is the same as v1 — Windows file-time ticks (100 ns since 1601)
/// rounded down to a 5-minute boundary, followed by the trusted client token —
/// but the digest is now a SHA-256 seeded with a hidden 57-byte prefix (the
/// precomputed `sha256State` / `sha256Schedule` constants, with tweaks in the
/// first block) plus a CS64 checksum keyed off that digest. Ported from
/// `edge-tts`'s `drm.py` (`generate_sec_ms_gec_v2`); all arithmetic is
/// wrapping 32-bit, matching Python's `& 0xFFFFFFFF` masking.
enum EdgeDRM {
    static func secMSGECv2(unixTime: TimeInterval, trustedClientToken: String) -> String {
        let windowsEpochOffset: Int64 = 11_644_473_600
        var seconds = Int64(unixTime) + windowsEpochOffset
        seconds -= seconds % 300
        let ticks = seconds * 10_000_000
        let data = Array("\(ticks)\(trustedClientToken)".utf8)
        let digest = sha256Digest(data)
        let (cs0, cs1) = cs64Digest(data, digest: digest)
        let cs64 = (leBytes(cs0) + leBytes(cs1)).map { String(format: "%02X", $0) }.joined()
        let sha = digest.map { String(format: "%02X", $0) }.joined()
        return "\(cs64)-\(sha)"
    }

    // MARK: Modified SHA-256

    private static let sha256Initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    private static let sha256State: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2
    ]
    private static let sha256Schedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0,
        0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564
    ]
    private static let roundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    ]
    private static let sha256Adjustment: UInt32 = 0xC9DC06A7
    private static let sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sigma1Adjustment: UInt32 = 0x000B92C0

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    private static func sigma0(_ x: UInt32) -> UInt32 { rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3) }
    private static func sigma1(_ x: UInt32) -> UInt32 { rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10) }

    private static func expandSchedule(_ words: inout [UInt32], from first: Int = 16) {
        for i in first..<64 {
            words.append(sigma1(words[i - 2]) &+ words[i - 7] &+ sigma0(words[i - 15]) &+ words[i - 16])
        }
    }

    /// Standard SHA-256 compression, optionally resuming at `firstRound`.
    /// Resuming at round 14 (the hidden-prefix block) swaps in the adjusted
    /// round-14 constant.
    private static func rounds(_ state: [UInt32], _ w: [UInt32], firstRound: Int = 0) -> [UInt32] {
        var k = roundConstants
        if firstRound == 14 { k[14] = sha256Adjustment }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in firstRound..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let t1 = h &+ s1 &+ (g ^ (e & (f ^ g))) &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let t2 = s0 &+ ((a & b) | (c & (a | b)))
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        return [a, b, c, d, e, f, g, h]
    }

    /// State after the hidden prefix plus the first seven bytes of `data`.
    private static func initialState(_ prefix: ArraySlice<UInt8>) -> [UInt32] {
        let bytes = Array(prefix)
        var w = [UInt32](repeating: 0, count: 14)
        w.append(beWord(bytes[0..<3]))
        w.append(beWord(bytes[3..<7]))
        for i in 16..<30 {
            var value = sha256Schedule[i - 16]
            if i - 2 >= 14 {
                value &+= i == 16 ? (sigma1(w[i - 2]) ^ sigma1Adjustment) : sigma1(w[i - 2])
            }
            if i - 7 >= 14 {
                value &+= w[i - 7]
            }
            if i - 15 >= 14 {
                value &+= i == 29 ? (sigma0(w[i - 15]) ^ sigma0Adjustment) : sigma0(w[i - 15])
            }
            w.append(value)
        }
        w.append(sigma1(w[28]) &+ w[23] &+ sigma0(w[15]) &+ w[14] &+ sha256Adjustment &- roundConstants[14])
        expandSchedule(&w, from: 31)
        let working = rounds(sha256State, w, firstRound: 14)
        return zip(sha256Initial, working).map { $0 &+ $1 }
    }

    private static func sha256Digest(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 7, "Token salt must contain at least seven bytes")
        let length = 57 + data.count
        var padded = Array(data[7...]) + [0x80]
        padded += [UInt8](repeating: 0, count: ((55 - length) % 64 + 64) % 64)
        padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(length * 8) >> (UInt64($0) * 8)) }
        var state = initialState(data[0..<7])
        for offset in stride(from: 0, to: padded.count, by: 64) {
            var w = (0..<16).map { beWord(padded[(offset + $0 * 4)..<(offset + $0 * 4 + 4)]) }
            expandSchedule(&w)
            let working = rounds(state, w)
            state = zip(state, working).map { $0 &+ $1 }
        }
        return state.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) } }
    }

    // MARK: CS64 checksum

    private static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), (0x3BEB65BC, 0x29514038),
        (0xC89C5933, 0xB328CBDF), (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
        (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB), (0x06064CF3, 0xFA51A3DA),
        (0xDA79FA60, 0x207CC464), (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167)
    ]
    private static let cs64Factor: UInt32 = 0x82893933
    private static let cs64Adjustment0: UInt32 = 0xF2F90B1A
    private static let cs64Adjustment1: UInt32 = 0x0B1A0000

    private static func rol16(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }

    private static func cs64Digest(_ data: [UInt8], digest: [UInt8]) -> (UInt32, UInt32) {
        let keyA = leWord(digest[0..<4]) | 1
        let keyB = leWord(digest[4..<8]) | 1
        let factors = [keyA &* cs64Factor, keyB &* cs64Factor]
        var terms = cs64Coefficients.enumerated().map { $0.element.0 &* factors[$0.offset % 2] }
        var offsets = cs64Coefficients.map { $0.1 }

        // Little-endian words of (0x00 + data), zero-padded to an even word count.
        var bytes: [UInt8] = [0] + data
        bytes += [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
        var words = stride(from: 0, to: bytes.count, by: 4).map { leWord(bytes[$0..<($0 + 4)]) }
        if words.count % 2 == 1 { words.append(0) }

        for (index, word) in words.enumerated() {
            let even = index % 2 == 0
            var term = word &* (even ? keyA : keyB)
            var offset = rol16(word) &* (even ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term &+= cs64Adjustment0 &* factors[0]
                offset &+= cs64Adjustment1
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAcc: UInt32 = 0, swapLast: UInt32 = 0, state: UInt32 = 0, acc: UInt32 = 0
        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index], y = terms[index + 1]
            var q = rol16(offsets[index] &+ x) &* 0x76F50F34
            swapAcc &+= rol16(q) &* 0xC3EFEA97 &+ q
            q = rol16(offsets[index + 1] &+ y) &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAcc &+= swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc &+= state
            var t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            acc &+= state
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }

    // MARK: Byte helpers

    private static func beWord(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func leWord(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func leBytes(_ word: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) }
    }
}

private struct EdgeVoiceEntry: Decodable {
    let shortName: String

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName"
    }
}
