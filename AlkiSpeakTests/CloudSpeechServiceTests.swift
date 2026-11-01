import AVFoundation
import XCTest
@testable import Woadie

final class InMemoryCloudSpeechSettingsStore: CloudSpeechSettingsStoring {
    var settings: CloudSpeechSettings

    init(_ settings: CloudSpeechSettings = CloudSpeechSettings()) {
        self.settings = settings
    }

    func load() -> CloudSpeechSettings { settings }
    func save(_ settings: CloudSpeechSettings) { self.settings = settings }
}

final class InMemorySecretStore: SecretStoring {
    var secrets: [String: String] = [:]

    func secret(for account: String) -> String? { secrets[account] }
    func setSecret(_ value: String?, for account: String) throws {
        secrets[account] = (value?.isEmpty ?? true) ? nil : value
    }
}

final class FakeLocalVoiceServer: LocalVoiceServerEnsuring {
    var ensureCount = 0
    var stopCount = 0
    var preparedModels: [String] = []
    var error: Error?

    func ensureRunning() async throws {
        ensureCount += 1
        if let error { throw error }
    }

    func prepareModel(_ modelID: String) async throws {
        preparedModels.append(modelID)
        if let error { throw error }
    }

    func stopOwnedServer() { stopCount += 1 }
}

final class FakeElevenLabsCatalog: ElevenLabsCatalogFetching {
    var catalog = ElevenLabsCatalog(voices: [], models: [])
    func fetchCatalog() async throws -> ElevenLabsCatalog { catalog }
}

final class FakeCartesiaVoices: CartesiaVoiceFetching {
    var voices: [CartesiaCatalog.Voice] = []
    func fetchVoices() async throws -> [CartesiaCatalog.Voice] { voices }
}

final class FakeKokoroModel: NativeKokoroSynthesizing {
    var availableVoices = ["ff_siwis", "af_heart"]
    var calls: [(text: String, voice: String, language: String)] = []
    var samples: [Float] = [0, 0.5, -0.5, 1.5]

    func synthesize(text: String, voice: String, language: String, speed: Float) throws -> [Float] {
        calls.append((text, voice, language))
        return samples
    }
}

/// Captures the outgoing request and replies with a canned response.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var responseHeaders: [String: String]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: Self.responseHeaders)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class CloudSpeechServiceTests: XCTestCase {
    private var settings: InMemoryCloudSpeechSettingsStore!
    private var secrets: InMemorySecretStore!
    private var service: CloudSpeechGenerationService!
    private var localServer: FakeLocalVoiceServer!
    private var stubSession: URLSession!
    private let openRouterVoice = CloudVoice(providerID: CloudProvider.openRouter.id, model: "mistralai/voxtral-mini-tts-2603", voice: "en_paul_neutral", label: "Paul")

    override func setUp() {
        super.setUp()
        settings = InMemoryCloudSpeechSettingsStore(CloudSpeechSettings(voices: [openRouterVoice]))
        secrets = InMemorySecretStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        stubSession = URLSession(configuration: configuration)
        localServer = FakeLocalVoiceServer()
        service = CloudSpeechGenerationService(settings: settings, secrets: secrets, session: stubSession, localServer: localServer)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.responseHeaders = nil
    }

    func testFetchVoicesReturnsPrefixedConfiguredIDs() async throws {
        let voices = try await service.fetchVoices()
        XCTAssertEqual(voices, [openRouterVoice.voiceID])
        XCTAssertTrue(CloudSpeechGenerationService.isCloudVoice(voices[0]))
    }

    func testSynthesizeSendsOpenAICompatibleRequest() async throws {
        try secrets.setSecret("sk-test", for: CloudProvider.openRouter.id)
        StubURLProtocol.handler = { _ in (200, Data([0xFF, 0xF3, 0x01])) }

        let result = try await service.synthesize(text: "Hello", voice: openRouterVoice.voiceID, jobID: nil)

        XCTAssertEqual(result.audioData, Data([0xFF, 0xF3, 0x01]))
        XCTAssertEqual(result.charCount, 5)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastBody)) as? [String: String])
        XCTAssertEqual(body, [
            "model": "mistralai/voxtral-mini-tts-2603",
            "input": "Hello",
            "voice": "en_paul_neutral",
            "response_format": "mp3"
        ])
    }

    func testMissingRequiredKeyFailsBeforeAnyNetworkCall() async {
        do {
            _ = try await service.synthesize(text: "Hi", voice: openRouterVoice.voiceID, jobID: nil)
            XCTFail("Expected a missing-key error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.cloud.api-key-missing")
            XCTAssertNil(StubURLProtocol.lastRequest)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testLocalProviderNeedsNoKeyAndSendsNoAuthorization() throws {
        let local = CloudVoice(providerID: CloudProvider.localMLX.id, model: "kokoro", voice: "af_heart", label: "Local")
        settings.settings.voices = [local]

        let request = try service.makeRequest(text: "Hi", voiceID: local.voiceID)

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8000/v1/audio/speech")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCustomProviderUsesSavedBaseURLAndRequiresOne() throws {
        let custom = CloudVoice(providerID: CloudProvider.custom.id, model: "m", voice: "v", label: "Custom")
        settings.settings.voices = [custom]
        XCTAssertThrowsError(try service.makeRequest(text: "Hi", voiceID: custom.voiceID))

        settings.settings.customBaseURL = "https://tts.example.com/v1/"
        let request = try service.makeRequest(text: "Hi", voiceID: custom.voiceID)
        XCTAssertEqual(request.url?.absoluteString, "https://tts.example.com/v1/audio/speech")
    }

    func testHTTPErrorSurfacesProviderMessage() async throws {
        try secrets.setSecret("sk-bad", for: CloudProvider.openRouter.id)
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"code":401,"message":"Invalid API key"}}"#.utf8)) }

        do {
            _ = try await service.synthesize(text: "Hi", voice: openRouterVoice.voiceID, jobID: nil)
            XCTFail("Expected an HTTP error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.cloud.http.401")
            XCTAssertTrue(error.message.contains("Invalid API key"))
        }
    }

    func testUnknownVoiceIDFails() {
        XCTAssertThrowsError(try service.makeRequest(text: "Hi", voiceID: CloudSpeechGenerationService.idPrefix + UUID().uuidString))
    }

    func testSpeechURLRejectsNonHTTPBases() {
        XCTAssertNil(CloudSpeechGenerationService.speechURL(base: "ftp://host/v1"))
        XCTAssertNil(CloudSpeechGenerationService.speechURL(base: "not a url"))
        XCTAssertEqual(CloudSpeechGenerationService.speechURL(base: " https://h/v1// ")?.absoluteString, "https://h/v1/audio/speech")
    }

    func testProviderMessageFallsBackToBodyText() {
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: Data(#"{"detail":"bad voice"}"#.utf8)), "bad voice")
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: Data("Gateway down".utf8)), "Gateway down")
        XCTAssertNil(CloudSpeechGenerationService.providerMessage(from: Data()))
    }

    // MARK: Local mlx-audio server

    func testLocalVoiceEnsuresServerBeforeRequesting() async throws {
        let local = CloudVoice(providerID: CloudProvider.localMLX.id, model: "qwen", voice: "Ryan", label: "Local")
        settings.settings.voices = [local]
        StubURLProtocol.handler = { _ in (200, Data([0x01])) }

        _ = try await service.synthesize(text: "Hi", voice: local.voiceID, jobID: nil)

        XCTAssertEqual(localServer.ensureCount, 1)
    }

    func testHostedVoiceNeverTouchesLocalServer() async throws {
        try secrets.setSecret("sk-test", for: CloudProvider.openRouter.id)
        StubURLProtocol.handler = { _ in (200, Data([0x01])) }

        _ = try await service.synthesize(text: "Hi", voice: openRouterVoice.voiceID, jobID: nil)

        XCTAssertEqual(localServer.ensureCount, 0)
    }

    func testLocalServerFailureStopsBeforeAnyRequest() async {
        let local = CloudVoice(providerID: CloudProvider.localMLX.id, model: "qwen", voice: "Ryan", label: "Local")
        settings.settings.voices = [local]
        localServer.error = AlkiSpeakError.generation(code: "mlx.not-installed", title: "t", message: "m", recoverySuggestion: "r")

        do {
            _ = try await service.synthesize(text: "Hi", voice: local.voiceID, jobID: nil)
            XCTFail("Expected the server error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.mlx.not-installed")
            XCTAssertNil(StubURLProtocol.lastRequest)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testManagerAdoptsAServerThatAlreadyAnswers() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (200, Data(#"{"object":"list","data":[]}"#.utf8))
        }
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent/mlx_audio.server"), session: stubSession, pidFileURL: nil)

        try await manager.ensureRunning()

        XCTAssertFalse(manager.isOwnedServerRunning, "An adopted server must not be treated as ours")
    }

    func testManagerReportsMissingInstall() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent/mlx_audio.server"), session: stubSession, pidFileURL: nil)

        do {
            try await manager.ensureRunning()
            XCTFail("Expected a not-installed error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.mlx.not-installed")
            XCTAssertTrue(error.message.contains("/nonexistent/mlx_audio.server"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: ElevenLabs

    func testElevenLabsRequestUsesVoicePathAndXIKey() throws {
        let voice = CloudVoice(providerID: CloudProvider.elevenLabs.id, model: "eleven_v4", voice: "JBFqnCBsd6RMkjVDRZzb", label: "George")
        settings.settings.voices = [voice]
        try secrets.setSecret("xi-test", for: CloudProvider.elevenLabs.id)

        let request = try service.makeRequest(text: "Hello", voiceID: voice.voiceID)

        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=mp3_44100_128")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["text": "Hello", "model_id": "eleven_v4"])
    }

    func testElevenLabsRequiresKey() {
        let voice = CloudVoice(providerID: CloudProvider.elevenLabs.id, model: "eleven_v4", voice: "abc", label: "A")
        settings.settings.voices = [voice]
        XCTAssertThrowsError(try service.makeRequest(text: "Hi", voiceID: voice.voiceID)) { error in
            XCTAssertEqual((error as? AlkiSpeakError)?.code, "generation.cloud.api-key-missing")
        }
    }

    func testElevenLabsVoiceIDIsPathEscaped() {
        let url = CloudSpeechGenerationService.elevenLabsSpeechURL(base: "https://api.elevenlabs.io/v1", voiceID: "a/b c")
        XCTAssertEqual(url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/a%2Fb%20c?output_format=mp3_44100_128")
        XCTAssertNil(CloudSpeechGenerationService.elevenLabsSpeechURL(base: "https://api.elevenlabs.io/v1", voiceID: ""))
    }

    func testElevenLabsErrorShapesAreReadable() {
        let object = Data(#"{"detail":{"type":"payment_required","code":"insufficient_credits","message":"Not enough credits"}}"#.utf8)
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: object), "Not enough credits")
        let list = Data(#"{"detail":[{"loc":["body","text"],"msg":"field required","type":"missing"}]}"#.utf8)
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: list), "field required")
    }

    func testCatalogListsVoicesAndOnlySpeechModels() async throws {
        try secrets.setSecret("xi-test", for: CloudProvider.elevenLabs.id)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi-test")
            switch request.url?.path {
            case "/v1/voices":
                return (200, Data(#"{"voices":[{"voice_id":"z1","name":"Zoe","category":"premade"},{"voice_id":"a1","name":"Adam","category":"cloned","labels":{"accent":"American"}}]}"#.utf8))
            case "/v1/models":
                return (200, Data(#"[{"model_id":"eleven_multilingual_sts_v2","name":"STS","can_do_text_to_speech":false},{"model_id":"eleven_flash_v2_5","name":"Flash v2.5","can_do_text_to_speech":true},{"model_id":"eleven_v4","name":"Eleven v4","can_do_text_to_speech":true}]"#.utf8))
            default:
                return (404, Data())
            }
        }
        let catalogService = ElevenLabsCatalogService(secrets: secrets, session: stubSession)

        let catalog = try await catalogService.fetchCatalog()

        XCTAssertEqual(catalog.voices.map(\.name), ["Adam", "Zoe"])
        XCTAssertEqual(catalog.models.map(\.modelID), ["eleven_flash_v2_5", "eleven_v4"])
        XCTAssertEqual(catalog.preferredModelID, "eleven_v4")
    }

    func testCatalogSurfacesBadKey() async throws {
        try secrets.setSecret("xi-bad", for: CloudProvider.elevenLabs.id)
        StubURLProtocol.handler = { _ in (401, Data(#"{"detail":{"code":"invalid_api_key","message":"Invalid API key"}}"#.utf8)) }
        let catalogService = ElevenLabsCatalogService(secrets: secrets, session: stubSession)

        do {
            _ = try await catalogService.fetchCatalog()
            XCTFail("Expected a 401")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.cloud.http.401")
            XCTAssertTrue(error.message.contains("Invalid API key"))
        }
    }

    // MARK: Gemini

    private let geminiVoice = CloudVoice(providerID: CloudProvider.gemini.id, model: "gemini-3.8-flash-tts", voice: "Kore", label: "Gemini Kore")

    private func geminiResponse(audio: Data) -> Data {
        let json: [String: Any] = ["steps": [
            ["type": "user_input", "content": [["type": "text", "text": "Hi"]]],
            ["type": "model_output", "content": [["type": "audio", "data": audio.base64EncodedString()]]]
        ]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testGeminiRequestUsesInteractionsShape() throws {
        settings.settings.voices = [geminiVoice]
        try secrets.setSecret("g-test", for: CloudProvider.gemini.id)

        let request = try service.makeRequest(text: "Have a wonderful day!", voiceID: geminiVoice.voiceID)

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash-tts")
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "audio")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "user_input")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "text", "text": "Have a wonderful day!"]])
        let speech = try XCTUnwrap((body["generation_config"] as? [String: Any])?["speech_config"] as? [[String: String]])
        XCTAssertEqual(speech, [["voice": "Kore"]])
    }

    func testGeminiSynthesizeDecodesEmbeddedWAV() async throws {
        settings.settings.voices = [geminiVoice]
        try secrets.setSecret("g-test", for: CloudProvider.gemini.id)
        let wav = Data("RIFF....WAVEfmt ".utf8) + Data(repeating: 0x7F, count: 32)
        StubURLProtocol.handler = { _ in (200, self.geminiResponse(audio: wav)) }

        let result = try await service.synthesize(text: "Hi", voice: geminiVoice.voiceID, jobID: nil)

        XCTAssertEqual(result.audioData, wav)
    }

    func testGeminiWithoutAudioFailsClearly() {
        let textOnly = Data(#"{"steps":[{"type":"model_output","content":[{"type":"text","text":"I can't do that"}]}]}"#.utf8)
        XCTAssertThrowsError(try CloudSpeechGenerationService.geminiAudio(from: textOnly)) { error in
            XCTAssertEqual((error as? AlkiSpeakError)?.code, "generation.cloud.gemini.no-audio")
        }
    }

    func testGeminiErrorMessageIsReadable() {
        let body = Data(#"{"error":{"code":"invalid_request","message":"API key not valid."}}"#.utf8)
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: body), "API key not valid.")
        // The live endpoint wraps the error in an array (seen 2026-10-30).
        let wrapped = Data(#"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#.utf8)
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: wrapped), "API key not valid. Please pass a valid API key.")
    }

    func testGeminiCatalogListsThirtyUniqueVoices() {
        XCTAssertEqual(GeminiSpeechCatalog.voices.count, 30)
        XCTAssertEqual(Set(GeminiSpeechCatalog.voices.map(\.name)).count, 30)
        XCTAssertEqual(GeminiSpeechCatalog.models.map(\.id), ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"])
    }

    // MARK: Local presets

    func testLocalPresetCatalogIsConsistent() {
        let models = LocalVoiceCatalog.models
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        // A cloning model has no presets: its voices come from recordings.
        XCTAssertTrue(models.allSatisfy { ($0.supportsVoiceCloning || !$0.voices.isEmpty) && !$0.license.isEmpty && $0.downloadGB > 0 })
        XCTAssertEqual(models.filter(\.supportsVoiceCloning).map(\.id), [LocalVoiceCatalog.cloningModelID])
        let labels = models.flatMap(\.voices).map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "Every preset needs its own label")
        XCTAssertEqual(models.first?.id, "mlx-community/Ming-3.0-tts-0.5B-bf16", "Best-quality model listed first")
    }

    // MARK: Ming voice design and expression tags

    func testLocalQwenVoiceStreamsWAVAndOthersOnlyAskForWAV() throws {
        let qwen = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", voice: "Ryan", label: "Ryan")
        let ming = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Ming-3.0-tts-0.5B-bf16", voice: "US_Emma", label: "Emma")
        settings.settings.voices = [qwen, ming]

        let qwenBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(service.makeRequest(text: "Hi", voiceID: qwen.voiceID).httpBody)) as? [String: Any])
        XCTAssertEqual(qwenBody["response_format"] as? String, "wav")
        XCTAssertEqual(qwenBody["stream"] as? Bool, true)

        let mingBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(service.makeRequest(text: "Hi", voiceID: ming.voiceID).httpBody)) as? [String: Any])
        XCTAssertEqual(mingBody["response_format"] as? String, "wav")
        XCTAssertNil(mingBody["stream"], "Streaming is only verified for Qwen3")
    }

    func testStreamedWAVChunksJoinIntoOneFile() async throws {
        let qwen = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", voice: "Ryan", label: "Ryan")
        settings.settings.voices = [qwen]
        let chunks: [[Int16]] = [[1, 2, 3, 4], [5, 6], [7]]
        StubURLProtocol.handler = { _ in (200, chunks.map(Self.wav).reduce(Data(), +)) }

        let result = try await service.synthesize(text: "Hi", voice: qwen.voiceID, jobID: nil)

        XCTAssertEqual(result.audioData, Self.wav([1, 2, 3, 4, 5, 6, 7]))
    }

    func testWAVJoinLeavesOtherResponsesAlone() {
        let single = Self.wav([1, 2, 3])
        XCTAssertEqual(CloudSpeechGenerationService.joinedWAVStream(single), single)
        let mp3 = Data([0xFF, 0xF3, 0x01, 0x02])
        XCTAssertEqual(CloudSpeechGenerationService.joinedWAVStream(mp3), mp3)
        let truncated = Self.wav([1, 2]) + Self.wav([3, 4]).dropLast(2)
        XCTAssertEqual(CloudSpeechGenerationService.joinedWAVStream(truncated), truncated)
    }

    /// A 24 kHz mono 16-bit WAV, laid out the way mlx-audio writes each chunk.
    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        samples.forEach { append($0) }
        return data
    }

    func testDesignedLocalVoiceSendsInstructInsteadOfVoice() throws {
        let designed = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Ming-3.0-tts-0.5B-bf16", voice: "", label: "Narrator", instructions: "A deep, slow documentary narrator.")
        let builtIn = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Ming-3.0-tts-0.5B-bf16", voice: "US_Emma", label: "Emma")
        settings.settings.voices = [designed, builtIn]

        let designedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(service.makeRequest(text: "Hi", voiceID: designed.voiceID).httpBody)) as? [String: String])
        XCTAssertEqual(designedBody["instruct"], "A deep, slow documentary narrator.")
        XCTAssertNil(designedBody["voice"], "Ming rejects voice and instruct together")

        let builtInBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(service.makeRequest(text: "Hi", voiceID: builtIn.voiceID).httpBody)) as? [String: String])
        XCTAssertEqual(builtInBody["voice"], "US_Emma")
        XCTAssertNil(builtInBody["instruct"])
    }

    func testSettingsSavedBeforeInstructionsStillLoad() throws {
        let legacy = Data(#"{"voices":[{"id":"41297353-7EC3-4BA4-952C-DAE6B0689DA2","providerID":"mlx-audio","model":"m","voice":"Ryan","label":"Qwen3 Ryan (local)"}],"customBaseURL":""}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudSpeechSettings.self, from: legacy)
        XCTAssertEqual(decoded.voices.first?.voice, "Ryan")
        XCTAssertNil(decoded.voices.first?.instructions)
        XCTAssertNil(decoded.voices.first?.speakers)
        XCTAssertFalse(decoded.voices[0].isDesigned)
        XCTAssertFalse(decoded.voices[0].isCloned)
    }

    // MARK: Voice cloning

    func testClonedVoiceSendsReferenceInsteadOfVoice() throws {
        let cloned = CloudVoice(
            providerID: CloudProvider.localMLX.id,
            model: LocalVoiceCatalog.cloningModelID,
            voice: "",
            label: "My voice (local)",
            referenceAudioPath: "/tmp/ref.wav",
            referenceText: "Hi, this is my voice."
        )
        settings.settings.voices = [cloned]

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(service.makeRequest(text: "Read this.", voiceID: cloned.voiceID).httpBody)) as? [String: Any])

        XCTAssertEqual(body["ref_audio"] as? String, "/tmp/ref.wav")
        XCTAssertEqual(body["ref_text"] as? String, "Hi, this is my voice.")
        XCTAssertEqual(body["model"] as? String, LocalVoiceCatalog.cloningModelID)
        XCTAssertNil(body["voice"], "Qwen3 Base rejects a voice name alongside a reference")
        XCTAssertNil(body["instruct"])
    }

    func testCloneReferenceIsConvertedTo24kMonoWAV() throws {
        let dir = try temporaryDirectory()
        let source = try writeTone(seconds: 5, sampleRate: 48_000, channels: 2, in: dir)
        let id = UUID()

        let stored = try VoiceCloneReference.store(from: source, id: id, in: dir)

        XCTAssertEqual(stored.lastPathComponent, "\(id.uuidString).wav")
        let file = try AVAudioFile(forReading: stored)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 5, accuracy: 0.05)
    }

    func testCloneReferenceRejectsTooShortAndTooLongClips() throws {
        let dir = try temporaryDirectory()
        let short = try writeTone(seconds: 1, sampleRate: 24_000, channels: 1, in: dir)
        let long = try writeTone(seconds: 31, sampleRate: 24_000, channels: 1, in: dir)

        for clip in [short, long] {
            XCTAssertThrowsError(try VoiceCloneReference.store(from: clip, id: UUID(), in: dir)) { error in
                XCTAssertEqual((error as? AlkiSpeakError)?.code, "generation.clone.reference")
            }
        }
    }

    func testCloneReferenceRemovalStaysInsideItsFolder() throws {
        let dir = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("keep.wav")
        try Data([1]).write(to: outside)
        let stored = try VoiceCloneReference.store(from: writeTone(seconds: 4, sampleRate: 24_000, channels: 1, in: dir), id: UUID(), in: dir)

        VoiceCloneReference.remove(atPath: outside.path, in: dir)
        VoiceCloneReference.remove(atPath: stored.path, in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Never delete files outside the clone folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    private func writeTone(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = 0.2 * sin(2 * .pi * 220 * Float(i) / Float(sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testOnlyMingAdvertisesTagsAndVoiceDesign() {
        let ming = LocalVoiceCatalog.model(withID: "mlx-community/Ming-3.0-tts-0.5B-bf16")
        let qwen = LocalVoiceCatalog.model(withID: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit")
        XCTAssertEqual(ming?.supportsVoiceDesign, true)
        XCTAssertTrue(ming?.expressionTags.contains("Laughter") ?? false)
        XCTAssertEqual(ming?.expressionTags.count, 14)
        XCTAssertEqual(qwen?.supportsVoiceDesign, false)
        XCTAssertEqual(qwen?.expressionTags, [])
    }

    func testHardCutNeverSplitsAnExpressionTag() {
        // No sentence ends, so the batcher must hard-cut near 250 characters;
        // place a tag so it straddles that cut.
        let lead = String(repeating: "word ", count: 49) + "and"   // 248 characters
        let text = lead + " [Laughter] " + String(repeating: "more words ", count: 30)
        let segments = TextBatcher.segments(for: text)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertEqual(segment.filter { $0 == "[" }.count, segment.filter { $0 == "]" }.count, "Split tag in: \(segment)")
        }
        XCTAssertTrue(segments.contains { $0.contains("[Laughter]") })
    }

    func testTagSafeCutLeavesClosedTagsAndPlainTextAlone() {
        let closed = Array("aaaa [Sigh] bbbbbbbb")
        XCTAssertEqual(TextBatcher.tagSafeCut(closed, at: 15), 15)
        let open = Array("aaaa [Surprise-oh] bbbb")
        XCTAssertEqual(TextBatcher.tagSafeCut(open, at: 10), 5)
        let plain = Array("no tags here at all")
        XCTAssertEqual(TextBatcher.tagSafeCut(plain, at: 10), 10)
    }

    // MARK: Gemini dialogue

    private let cast = [DialogueSpeaker(name: "Joe", voice: "Puck"), DialogueSpeaker(name: "Jane", voice: "Kore")]

    func testDialogueRequestTagsEachTurnAndStripsLabels() throws {
        let dialogue = CloudVoice(providerID: CloudProvider.gemini.id, model: "gemini-3.8-flash-tts", voice: "Puck+Kore", label: "Dialogue", speakers: cast)
        settings.settings.voices = [dialogue]
        try secrets.setSecret("g-test", for: CloudProvider.gemini.id)

        let request = try service.makeRequest(text: "Joe: How's it going today Jane?\nJane: Not too bad, how about you?", voiceID: dialogue.voiceID)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["text"] as? String }, ["How's it going today Jane?", "Not too bad, how about you?"])
        let speakersSaid = content.map { (($0["annotations"] as? [[String: String]])?.first)?["speaker"] }
        XCTAssertEqual(speakersSaid, ["Joe", "Jane"])
        XCTAssertEqual(content.first.flatMap { ($0["annotations"] as? [[String: String]])?.first?["type"] }, "speech_metadata")
        let speechConfig = try XCTUnwrap((body["generation_config"] as? [String: Any])?["speech_config"] as? [String: Any])
        XCTAssertEqual(speechConfig["speakers"] as? [[String: String]], [["speaker": "Joe", "voice": "Puck"], ["speaker": "Jane", "voice": "Kore"]])
    }

    func testDialogueWithNoSpokenTextFails() throws {
        let dialogue = CloudVoice(providerID: CloudProvider.gemini.id, model: "gemini-3.8-flash-tts", voice: "Puck+Kore", label: "Dialogue", speakers: cast)
        settings.settings.voices = [dialogue]
        try secrets.setSecret("g-test", for: CloudProvider.gemini.id)
        XCTAssertThrowsError(try service.makeRequest(text: "Joe:\nJane:  ", voiceID: dialogue.voiceID)) { error in
            XCTAssertEqual((error as? AlkiSpeakError)?.code, "generation.cloud.dialogue.empty")
        }
    }

    func testScriptParsingRules() {
        let script = """
        Opening line with no label.
        jane: Lowercase name still counts.
        And this line continues Jane.

        Joe: Note: colons later in a line are fine.
        Narrator: Unknown names stay part of the current turn.
        """
        let turns = DialogueScript.turns(in: script, speakers: ["Joe", "Jane"])
        XCTAssertEqual(turns, [
            .init(speaker: "Joe", text: "Opening line with no label."),
            .init(speaker: "Jane", text: "Lowercase name still counts. And this line continues Jane."),
            .init(speaker: "Joe", text: "Note: colons later in a line are fine. Narrator: Unknown names stay part of the current turn.")
        ])
    }

    func testScriptSegmentsSplitBetweenTurnsAndRelabelLongTurns() {
        let longTurn = String(repeating: "This sentence keeps Jane talking for a while. ", count: 12)
        let script = "Joe: Short opener.\nJane: \(longTurn)\nJoe: Short closer."
        let segments = DialogueScript.segments(for: script, speakers: ["Joe", "Jane"])

        XCTAssertGreaterThan(segments.count, 2)
        for segment in segments {
            let firstLine = segment.components(separatedBy: "\n").first ?? ""
            XCTAssertTrue(firstLine.hasPrefix("Joe: ") || firstLine.hasPrefix("Jane: "), "Unlabeled segment: \(segment)")
        }
        let rebuilt = segments.flatMap { DialogueScript.turns(in: $0, speakers: ["Joe", "Jane"]) }
        XCTAssertEqual(rebuilt.first, .init(speaker: "Joe", text: "Short opener."))
        XCTAssertEqual(rebuilt.last, .init(speaker: "Joe", text: "Short closer."))
        XCTAssertTrue(rebuilt.dropFirst().dropLast().allSatisfy { $0.speaker == "Jane" })
    }

    // MARK: Dialogue delivery notes

    func testDeliveryNotesBecomeTurnStyle() throws {
        let dialogue = CloudVoice(providerID: CloudProvider.gemini.id, model: "gemini-3.8-flash-tts", voice: "Puck+Kore", label: "Dialogue", speakers: cast)
        settings.settings.voices = [dialogue]
        try secrets.setSecret("g-test", for: CloudProvider.gemini.id)

        let request = try service.makeRequest(
            text: "Joe (cheerful and friendly): How's it going today Jane?\nJane: Not too bad, how about you?",
            voiceID: dialogue.voiceID
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let metadata = content.map { ($0["annotations"] as? [[String: String]])?.first ?? [:] }
        XCTAssertEqual(metadata[0], ["type": "speech_metadata", "speaker": "Joe", "style": "cheerful and friendly"])
        XCTAssertEqual(metadata[1], ["type": "speech_metadata", "speaker": "Jane"], "No note means no style key")
        XCTAssertEqual(content[0]["text"] as? String, "How's it going today Jane?", "The note is never spoken")
    }

    func testDeliveryNoteParsingRules() {
        let script = """
        JOE (Whisper: very soft): Can you hear me?
        Still whispering here.
        Jane ( ): An empty note is ignored.
        Jane(calm):No spaces needed.
        Joe (excited) Not a label without a colon.
        """
        XCTAssertEqual(DialogueScript.turns(in: script, speakers: ["Joe", "Jane"]), [
            .init(speaker: "Joe", text: "Can you hear me? Still whispering here.", style: "Whisper: very soft"),
            .init(speaker: "Jane", text: "An empty note is ignored."),
            .init(speaker: "Jane", text: "No spaces needed. Joe (excited) Not a label without a colon.", style: "calm")
        ])
    }

    func testSplittingKeepsEachTurnsNote() {
        let longTurn = String(repeating: "Jane keeps calmly explaining the plan. ", count: 12)
        let script = "Joe (nervous): Is it ready?\nJane (calm and relaxed): \(longTurn)"
        let segments = DialogueScript.segments(for: script, speakers: ["Joe", "Jane"])

        let rebuilt = segments.flatMap { DialogueScript.turns(in: $0, speakers: ["Joe", "Jane"]) }
        XCTAssertGreaterThan(rebuilt.count, 2)
        XCTAssertEqual(rebuilt.first, .init(speaker: "Joe", text: "Is it ready?", style: "nervous"))
        XCTAssertTrue(rebuilt.dropFirst().allSatisfy { $0.speaker == "Jane" && $0.style == "calm and relaxed" })
    }

    // MARK: Cartesia

    func testCartesiaRequestShape() throws {
        let voice = CloudVoice(providerID: CloudProvider.cartesia.id, model: "sonic-3.6", voice: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", label: "Skylar")
        settings.settings.voices = [voice]
        try secrets.setSecret("sk_car_test", for: CloudProvider.cartesia.id)

        let request = try service.makeRequest(text: "Hello there.", voiceID: voice.voiceID)

        XCTAssertEqual(request.url?.absoluteString, "https://api.cartesia.ai/tts/bytes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_car_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model_id"] as? String, "sonic-3.6")
        XCTAssertEqual(body["transcript"] as? String, "Hello there.")
        XCTAssertEqual(body["voice"] as? [String: String], ["id": "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"])
        let format = try XCTUnwrap(body["output_format"] as? [String: Any])
        XCTAssertEqual(format["container"] as? String, "mp3")
        XCTAssertEqual(format["sample_rate"] as? Int, 44100)
        XCTAssertEqual(format["bit_rate"] as? Int, 128000)
    }

    func testCartesiaVoicesPageAndSort() async throws {
        try secrets.setSecret("sk_car_test", for: CloudProvider.cartesia.id)
        var requestedCursors: [String?] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "starting_after" }?.value
            requestedCursors.append(cursor)
            if cursor == nil {
                return (200, Data(#"{"data":[{"id":"v2","name":"Zane","tagline":"Calm Narrator","language":"en"}],"has_more":true,"next_page":"v2"}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"v1","name":"Ava","tagline":"","language":"en"}],"has_more":false,"next_page":null}"#.utf8))
        }

        let voices = try await CartesiaVoiceService(secrets: secrets, session: stubSession).fetchVoices()

        XCTAssertEqual(voices.map(\.name), ["Ava", "Zane"])
        XCTAssertEqual(requestedCursors, [nil, "v2"])
    }

    func testCartesiaErrorMessageIsReadable() {
        let body = Data(#"{"error_code":"quota_exceeded","title":"Quota exceeded","message":"You have run out of credits.","request_id":"550e8400"}"#.utf8)
        XCTAssertEqual(CloudSpeechGenerationService.providerMessage(from: body), "You have run out of credits.")
    }

    // MARK: Native Kokoro

    private func nativeService(loadModel: @escaping @Sendable () async throws -> NativeKokoroSynthesizing) -> NativeKokoroSpeechService {
        NativeKokoroSpeechService(defaults: UserDefaults(suiteName: "WoadieTests.native.\(UUID().uuidString)")!, loadModel: loadModel)
    }

    func testNativeKokoroListsNothingUntilEnabled() async throws {
        let fake = FakeKokoroModel()
        let service = nativeService { fake }

        let disabledVoices = try await service.fetchVoices()
        XCTAssertEqual(disabledVoices, [])
        let disabledHealth = await service.checkHealth()
        XCTAssertFalse(disabledHealth, "Nothing should load or download before the user turns it on")

        service.isEnabled = true
        let voices = try await service.fetchVoices()
        XCTAssertEqual(voices, ["kokoro-native:af_heart", "kokoro-native:ff_siwis"])
        let health = await service.checkHealth()
        XCTAssertTrue(health)
    }

    func testNativeKokoroLoadsOnceAndPicksLanguageFromTheVoice() async throws {
        let fake = FakeKokoroModel()
        let loads = LoadCounter()
        let service = nativeService { await loads.increment(); return fake }
        service.isEnabled = true

        async let first = service.synthesize(text: "Bonjour", voice: "kokoro-native:ff_siwis", jobID: nil)
        async let second = service.synthesize(text: "Hello", voice: "kokoro-native:af_heart", jobID: nil)
        let results = try await [first, second]

        let loadCount = await loads.count
        XCTAssertEqual(loadCount, 1, "Concurrent first requests must share one model load")
        XCTAssertEqual(Set(fake.calls.map { "\($0.voice)/\($0.language)" }), ["ff_siwis/fr", "af_heart/en"])
        XCTAssertTrue(results.allSatisfy { $0.audioData.starts(with: Data("RIFF".utf8)) })
    }

    func testNativeKokoroListsCachedVoicesWithoutLoadingTheModel() async throws {
        let fake = FakeKokoroModel()
        let loads = LoadCounter()
        let service = nativeService { await loads.increment(); return fake }
        service.isEnabled = true
        _ = try await service.prepare()
        await service.release()

        let voices = try await service.fetchVoices()

        XCTAssertEqual(voices, ["kokoro-native:af_heart", "kokoro-native:ff_siwis"])
        let loaded = await service.checkHealth()
        XCTAssertFalse(loaded, "Listing voices from the cache must not load the model")
        let loadCount = await loads.count
        XCTAssertEqual(loadCount, 1)
    }

    func testNativeKokoroReloadsAfterRelease() async throws {
        let fake = FakeKokoroModel()
        let loads = LoadCounter()
        let service = nativeService { await loads.increment(); return fake }
        service.isEnabled = true

        _ = try await service.synthesize(text: "Hello", voice: "kokoro-native:af_heart", jobID: nil)
        await service.release()
        let releasedHealth = await service.checkHealth()
        XCTAssertFalse(releasedHealth)
        _ = try await service.synthesize(text: "Hello", voice: "kokoro-native:af_heart", jobID: nil)

        let loadCount = await loads.count
        XCTAssertEqual(loadCount, 2, "A released model loads again on the next request")
    }

    func testNativeKokoroLanguageMapping() {
        let cases = ["af_heart": "en", "bm_george": "en", "ef_dora": "es", "ff_siwis": "fr", "hf_alpha": "hi",
                     "if_sara": "it", "jf_alpha": "ja", "pf_dora": "pt", "zf_xiaobei": "zh"]
        for (voice, language) in cases {
            XCTAssertEqual(NativeKokoroSpeechService.language(forVoice: voice), language, voice)
        }
    }

    func testNativeKokoroWAVIsValidPCM16() {
        let wav = NativeKokoroSpeechService.wavData(samples: [0, 0.5, -0.5, 1.5], sampleRate: 24_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func u32(_ offset: Int) -> UInt32 { wav[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func i16(_ offset: Int) -> Int16 { Int16(bitPattern: UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8) }
        XCTAssertEqual(u32(24), 24_000, "sample rate")
        XCTAssertEqual(u32(40), 8, "data size")
        XCTAssertEqual([i16(44), i16(46), i16(48), i16(50)], [0, 16383, -16383, 32767], "clamped samples")
    }

    func testNativeKokoroWAVMatchesPerSampleConversion() {
        let samples: [Float] = (0..<4_001).map { Float($0 - 2_000) / 1_500 }
        let wav = NativeKokoroSpeechService.wavData(samples: samples, sampleRate: 24_000)
        let expected = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        let actual = stride(from: 44, to: wav.count, by: 2).map {
            Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)
        }
        XCTAssertEqual(actual, expected)
    }

    func testNativeKokoroUnknownVoiceAndFailedLoadAreClear() async throws {
        let service = nativeService { FakeKokoroModel() }
        service.isEnabled = true
        do {
            _ = try await service.synthesize(text: "Hi", voice: "kokoro-native:zz_nobody", jobID: nil)
            XCTFail("Expected a missing-voice error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.native-kokoro.voice-missing")
        }

        let attempts = LoadCounter()
        let flaky = nativeService {
            await attempts.increment()
            if await attempts.count == 1 { throw URLError(.notConnectedToInternet) }
            return FakeKokoroModel()
        }
        flaky.isEnabled = true
        do {
            _ = try await flaky.synthesize(text: "Hi", voice: "kokoro-native:af_heart", jobID: nil)
            XCTFail("Expected the first load to fail")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.native-kokoro.failed")
        }
        let retried = try await flaky.synthesize(text: "Hi", voice: "kokoro-native:af_heart", jobID: nil)
        XCTAssertFalse(retried.audioData.isEmpty, "A failed load is retried on the next request")
    }
}

actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

extension CloudSpeechServiceTests {
    // MARK: Native Kokoro, live (opt-in)

    /// Downloads the real CoreML model (~170 MB) and speaks with it. Skipped
    /// unless ALKISPEAK_LIVE_NATIVE_KOKORO=1 (pass TEST_RUNNER_ALKISPEAK_LIVE_NATIVE_KOKORO=1 to xcodebuild).
    func testLiveNativeKokoroSpeaks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALKISPEAK_LIVE_NATIVE_KOKORO"] == "1", "Live native Kokoro test is opt-in")
        let service = NativeKokoroSpeechService(defaults: UserDefaults(suiteName: "WoadieTests.native.live")!)
        service.isEnabled = true

        let loadStart = Date()
        let voiceCount = try await service.prepare()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let voices = try await service.fetchVoices()
        XCTAssertTrue(voices.contains("kokoro-native:af_heart"))

        for (voice, text) in [("kokoro-native:af_heart", "Hello from AlkiSpeak, running Kokoro natively on the Neural Engine."),
                              ("kokoro-native:ff_siwis", "Bonjour, ceci est Kokoro en français.")] {
            let start = Date()
            let result = try await service.synthesize(text: text, voice: voice, jobID: nil)
            let seconds = Date().timeIntervalSince(start)
            let audioSeconds = Double(result.audioData.count - 44) / 2 / Double(NativeKokoroSpeechService.sampleRate)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-\(NativeKokoroSpeechService.stripPrefix(voice)).wav")
            try result.audioData.write(to: url)
            print("LIVE native Kokoro \(voice): \(String(format: "%.2f", audioSeconds)) s audio in \(String(format: "%.2f", seconds)) s -> \(url.path)")
            XCTAssertGreaterThan(audioSeconds, 1.0)
        }
        print("LIVE native Kokoro: \(voiceCount) voices, load \(String(format: "%.1f", loadSeconds)) s")
    }
}

// MARK: - Rough-edge fixes

extension CloudSpeechServiceTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WoadieTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spawnSleeper() throws -> Process {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        return sleeper
    }

    func testOrphanedServerFromAForceQuitIsReclaimedAndStopped() async throws {
        let dir = try temporaryDirectory()
        let pidFile = dir.appendingPathComponent("server.pid")
        let orphan = try spawnSleeper()
        defer { if orphan.isRunning { orphan.terminate() } }
        try "\(orphan.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        StubURLProtocol.handler = { _ in (200, Data(#"{"object":"list","data":[]}"#.utf8)) }
        let manager = MLXAudioServerManager(
            executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession,
            pidFileURL: pidFile, isServerProcess: { $0 == orphan.processIdentifier }
        )

        try await manager.ensureRunning()
        XCTAssertTrue(manager.isOwnedServerRunning, "A server our earlier run launched is ours to stop")
        manager.stopOwnedServer()

        orphan.waitUntilExit()
        XCTAssertFalse(orphan.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testOwnedServerStopsAfterIdleTimeout() async throws {
        let dir = try temporaryDirectory()
        let pidFile = dir.appendingPathComponent("server.pid")
        let server = try spawnSleeper()
        defer { if server.isRunning { server.terminate() } }
        try "\(server.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        StubURLProtocol.handler = { _ in (200, Data(#"{"object":"list","data":[]}"#.utf8)) }
        let manager = MLXAudioServerManager(
            executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession, idleTimeout: 0.2,
            pidFileURL: pidFile, isServerProcess: { $0 == server.processIdentifier }
        )

        try await manager.ensureRunning()
        XCTAssertTrue(manager.isOwnedServerRunning)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertFalse(server.isRunning, "An owned server with no requests is stopped to free its memory")
        XCTAssertFalse(manager.isOwnedServerRunning)
    }

    func testServerInUseIsNotStoppedForIdle() async throws {
        let dir = try temporaryDirectory()
        let pidFile = dir.appendingPathComponent("server.pid")
        let server = try spawnSleeper()
        defer { if server.isRunning { server.terminate() } }
        try "\(server.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        StubURLProtocol.handler = { _ in (200, Data(#"{"object":"list","data":[]}"#.utf8)) }
        let manager = MLXAudioServerManager(
            executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession, idleTimeout: 0.2,
            pidFileURL: pidFile, isServerProcess: { $0 == server.processIdentifier }
        )

        manager.beginUse()
        try await manager.ensureRunning()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(server.isRunning, "A long request must not be cut off by the idle timer")

        manager.endUse()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(server.isRunning)
    }

    func testServerStartedByHandIsNeverStopped() async throws {
        let dir = try temporaryDirectory()
        let pidFile = dir.appendingPathComponent("server.pid")
        let stranger = try spawnSleeper()
        defer { stranger.terminate() }
        // A stale PID file naming a process that isn't mlx_audio.server.
        try "\(stranger.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        StubURLProtocol.handler = { _ in (200, Data(#"{"object":"list","data":[]}"#.utf8)) }
        let manager = MLXAudioServerManager(
            executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession,
            pidFileURL: pidFile, isServerProcess: { _ in false }
        )

        try await manager.ensureRunning()
        XCTAssertFalse(manager.isOwnedServerRunning)
        manager.stopOwnedServer()
        XCTAssertTrue(stranger.isRunning, "An unrelated process with a recycled PID must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path), "The stale PID file is cleared")
    }

    func testPrepareModelLoadsOnceWithNoShortTimeout() async throws {
        let posts = LoadCounter()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.query, "model_name=mlx-community/Some-Model")
                XCTAssertGreaterThanOrEqual(request.timeoutInterval, 3600)
                Task { await posts.increment() }
            }
            return (200, Data(#"{"status":"success"}"#.utf8))
        }
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession, pidFileURL: nil)

        async let first: Void = manager.prepareModel("mlx-community/Some-Model")
        async let second: Void = manager.prepareModel("mlx-community/Some-Model")
        _ = try await (first, second)
        try await manager.prepareModel("mlx-community/Some-Model")
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await posts.count
        XCTAssertEqual(count, 1, "Concurrent and repeat prepares share one load")
    }

    func testPrepareModelFailureIsReadable() async {
        StubURLProtocol.handler = { request in
            request.httpMethod == "POST" ? (500, Data(#"{"detail":"Repository not found"}"#.utf8)) : (200, Data())
        }
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent"), session: stubSession, pidFileURL: nil)
        do {
            try await manager.prepareModel("mlx-community/Missing")
            XCTFail("Expected a load error")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.mlx.model-load")
            XCTAssertTrue(error.message.contains("Repository not found"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testModelDownloadedCheckReadsTheHubCache() throws {
        let hub = try temporaryDirectory()
        let repo = hub.appendingPathComponent("models--mlx-community--Demo")
        XCTAssertFalse(MLXAudioServerManager.isModelDownloaded("mlx-community/Demo", hubCache: hub))

        try FileManager.default.createDirectory(at: repo.appendingPathComponent("snapshots/abc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repo.appendingPathComponent("blobs/123.incomplete").path, contents: Data())
        XCTAssertFalse(MLXAudioServerManager.isModelDownloaded("mlx-community/Demo", hubCache: hub), "A partial download isn't done")

        try FileManager.default.removeItem(at: repo.appendingPathComponent("blobs/123.incomplete"))
        XCTAssertTrue(MLXAudioServerManager.isModelDownloaded("mlx-community/Demo", hubCache: hub))
    }

    func testLocalVoiceWithMissingModelPreparesItBeforeSpeaking() async throws {
        let local = CloudVoice(providerID: CloudProvider.localMLX.id, model: "test/never-downloaded-\(UUID().uuidString)", voice: "Ryan", label: "Local")
        settings.settings.voices = [local]
        StubURLProtocol.handler = { _ in (200, Data([0x01])) }

        _ = try await service.synthesize(text: "Hi", voice: local.voiceID, jobID: nil)

        XCTAssertEqual(localServer.preparedModels, [local.model])
    }

    func testTwoSpeakersOnOneLineBecomeTwoTurns() {
        let turns = DialogueScript.turns(in: "Joe: Hi there. Jane (calm): Hello! JOE: Ready? Jane said: no split here.", speakers: ["Joe", "Jane"])
        XCTAssertEqual(turns, [
            .init(speaker: "Joe", text: "Hi there."),
            .init(speaker: "Jane", text: "Hello!", style: "calm"),
            .init(speaker: "Joe", text: "Ready? Jane said: no split here.")
        ])
        XCTAssertEqual(DialogueScript.splitInlineLabels("Joe: Mr. Smith: hello", speakers: ["Joe", "Jane"]), ["Joe: Mr. Smith: hello"])
    }

    func testOpenAIPresetRetiresOnShutdownDay() throws {
        let utc = Calendar(identifier: .gregorian)
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            DateComponents(calendar: utc, timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d).date!
        }
        XCTAssertFalse(CloudProvider.openAI.isRetired(asOf: date(2027, 1, 5)))
        XCTAssertTrue(CloudProvider.openAI.isRetired(asOf: date(2027, 1, 6)))
        XCTAssertTrue(CloudProvider.selectable(asOf: date(2026, 12, 1)).contains(.openAI))
        XCTAssertFalse(CloudProvider.selectable(asOf: date(2027, 2, 1)).contains(.openAI))
        XCTAssertNotNil(CloudProvider.openAI.notice)
        XCTAssertFalse(CloudProvider.elevenLabs.isRetired(asOf: date(2030, 1, 1)), "Other providers never retire")
    }
}

final class FirstSoundTests: XCTestCase {
    // MARK: Lead-in segment

    func testLeadInIsTheFirstSentenceLongEnoughToSoundNatural() throws {
        let text = "This opening sentence is short. So is this one. " + String(repeating: "Then a much longer stretch follows. ", count: 10)
        let split = try XCTUnwrap(TextBatcher.leadIn(of: text))

        XCTAssertEqual(split.lead, "This opening sentence is short.")
        XCTAssertTrue(split.rest.hasPrefix("So is this one."))

        // "Hi there." is too short to stand alone, so the lead runs to the next sentence.
        let greeting = try XCTUnwrap(TextBatcher.leadIn(of: "Hi there. Thanks for listening today. " + String(repeating: "More words follow. ", count: 8)))
        XCTAssertEqual(greeting.lead, "Hi there. Thanks for listening today.")
    }

    func testLeadInFallsBackToAClauseWhenTheFirstSentenceIsLong() throws {
        let text = "AlkiSpeak reads whatever you give it, and the first thing anyone notices is how long it takes before the voice starts. More text."
        let split = try XCTUnwrap(TextBatcher.leadIn(of: text))

        XCTAssertEqual(split.lead, "AlkiSpeak reads whatever you give it,")
    }

    func testLeadInLeavesShortTextAndUnbrokenTextAlone() {
        XCTAssertNil(TextBatcher.leadIn(of: "Short text that fits in one request."))
        XCTAssertNil(TextBatcher.leadIn(of: String(repeating: "word ", count: 60)), "no sentence or clause break to cut at")
        XCTAssertNil(TextBatcher.leadIn(of: "Hi, " + String(repeating: "word ", count: 60)), "a clause this short would sound clipped")
    }

    func testLeadInIgnoresNumbersAndNeverSplitsATag() {
        // The only "clause" marks are inside a number and a time.
        XCTAssertNil(TextBatcher.leadIn(of: "It costs 1,000 dollars at 3:30 in the afternoon " + String(repeating: "and more words ", count: 10)))
        // A clause break that sits inside an open tag isn't used.
        let tagged = "[Laughter, warm and long] " + String(repeating: "word ", count: 30)
        XCTAssertNil(TextBatcher.leadIn(of: tagged))
    }

    func testRequestPolicyStartsWithTheLeadInThenBatchesTheRest() {
        let text = "A quick first sentence. " + String(repeating: "Then a much longer stretch follows here. ", count: 15)
        let segments = EngineRequestPolicy.live.segments(for: text).map(\.text)

        XCTAssertEqual(segments.first, "A quick first sentence.")
        XCTAssertTrue(segments.allSatisfy { $0.count <= 250 })
        XCTAssertEqual(segments.joined(separator: " "), text.trimmingCharacters(in: .whitespaces))
    }

    func testRequestPolicySplitsAMediumParagraphSoSoundStartsSooner() {
        let text = "One short sentence comes first. " + String(repeating: "Another clause keeps going on. ", count: 4)
        XCTAssertLessThanOrEqual(text.count, 250)

        let segments = EngineRequestPolicy.live.segments(for: text)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "One short sentence comes first.")
    }

    func testRequestPolicyCanSkipTheLeadInForSlowEngines() {
        let text = "One short sentence comes first. " + String(repeating: "Another clause keeps going on. ", count: 4)

        XCTAssertEqual(EngineRequestPolicy.live.segments(for: text, leadIn: false).count, 1)
    }

    func testGenerationConcurrencyPerVoice() {
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "edge:en-US-AriaNeural", runsOnThisMac: false), 2)
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "cloud:\(UUID())", runsOnThisMac: false), 2)
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "cloud:\(UUID())", runsOnThisMac: true), 1, "mlx-audio voices")
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "af_heart", runsOnThisMac: false), 1)
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "kokoro-native:af_heart", runsOnThisMac: false), 1)
    }

    // MARK: Lookahead

    func testLookaheadDeliversInOrderEvenWhenLaterSegmentsFinishFirst() async {
        let queue = TTSQueue()
        await queue.enqueue(["Slow first.", "Fast second.", "Fast third."])
        let log = FirstSoundLog()

        await queue.process(maxConcurrent: 3, generate: { segment in
            // The first segment is the slowest, so it finishes last.
            try await Task.sleep(nanoseconds: segment.index == 0 ? 60_000_000 : 5_000_000)
            await log.add("done-\(segment.index)")
            return GeneratedSegment(audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"), durationSeconds: nil)
        }, onReady: { segment in
            await log.add("ready-\(segment.index)")
        })

        let events = await log.events
        XCTAssertEqual(events.filter { $0.hasPrefix("ready") }, ["ready-0", "ready-1", "ready-2"])
        XCTAssertLessThan(events.firstIndex(of: "done-1")!, events.firstIndex(of: "done-0")!, "segment 1 generated while 0 was still going")
    }

    func testLookaheadNeverRunsMoreThanTheLimitAtOnce() async {
        let queue = TTSQueue()
        await queue.enqueue((0..<6).map { "Segment \($0)." })
        let gauge = FirstSoundGauge()

        await queue.process(maxConcurrent: 2, generate: { segment in
            await gauge.enter()
            try await Task.sleep(nanoseconds: 10_000_000)
            await gauge.leave()
            return GeneratedSegment(audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"), durationSeconds: nil)
        }, onReady: { _ in })

        let peak = await gauge.peak
        XCTAssertEqual(peak, 2)
    }

    func testLookaheadStopsAtAFailureAfterDeliveringEarlierSegments() async {
        struct Boom: Error {}
        let queue = TTSQueue()
        await queue.enqueue(["Fine.", "Broken.", "Never played."])
        let log = FirstSoundLog()

        await queue.process(maxConcurrent: 3, generate: { segment in
            if segment.index == 1 { throw Boom() }
            try await Task.sleep(nanoseconds: 5_000_000)
            return GeneratedSegment(audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"), durationSeconds: nil)
        }, onReady: { segment in
            await log.add("ready-\(segment.index)")
        })

        let events = await log.events
        XCTAssertEqual(events, ["ready-0"])
        let snapshot = await queue.snapshot()
        guard case .failed = snapshot[1].status else { return XCTFail("segment 1 should be marked failed") }
    }

    func testCancellingStopsALookaheadRun() async {
        let queue = TTSQueue()
        await queue.enqueue(["One.", "Two.", "Three.", "Four."])
        let log = FirstSoundLog()

        let run = Task {
            await queue.process(maxConcurrent: 2, generate: { segment in
                try await Task.sleep(nanoseconds: 30_000_000)
                return GeneratedSegment(audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"), durationSeconds: nil)
            }, onReady: { segment in
                await log.add("ready-\(segment.index)")
            })
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await queue.cancel()
        await run.value

        let events = await log.events
        XCTAssertTrue(events.isEmpty, "nothing should play after cancel, got \(events)")
        let isProcessing = await queue.processing
        XCTAssertFalse(isProcessing)
    }
}

private actor FirstSoundLog {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

private actor FirstSoundGauge {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

final class AudioClipCacheTests: XCTestCase {
    private func makeCache(capacity: Int64 = AudioClipCache.defaultCapacityBytes) -> (AudioClipCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clip-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (AudioClipCache(directory: directory, capacityBytes: capacity), directory)
    }

    func testKeyIsStableAndChangesWithTextOrVoiceSetup() {
        let key = AudioClipCache.key(text: "Hello there.", voiceConfiguration: "edge:en-US-AriaNeural")

        XCTAssertEqual(key, AudioClipCache.key(text: "Hello there.", voiceConfiguration: "edge:en-US-AriaNeural"))
        XCTAssertEqual(key.count, 64)
        XCTAssertNotEqual(key, AudioClipCache.key(text: "Hello there!", voiceConfiguration: "edge:en-US-AriaNeural"))
        XCTAssertNotEqual(key, AudioClipCache.key(text: "Hello there.", voiceConfiguration: "edge:en-US-GuyNeural"))
        XCTAssertNotEqual(
            AudioClipCache.key(text: "Hi", voiceConfiguration: "cloud:1|{\"model\":\"a\"}"),
            AudioClipCache.key(text: "Hi", voiceConfiguration: "cloud:1|{\"model\":\"b\"}"),
            "editing a cloud voice's model must not replay old audio"
        )
    }

    func testStoredAudioComesBackAndMissesAreNil() async {
        let (cache, _) = makeCache()
        let audio = Data("RIFF-fake-audio".utf8)

        let missBefore = await cache.audio(forKey: "abc")
        XCTAssertNil(missBefore)
        await cache.store(audio, forKey: "abc")
        let hit = await cache.audio(forKey: "abc")
        XCTAssertEqual(hit, audio)
        let total = await cache.totalBytes()
        XCTAssertEqual(total, Int64(audio.count))
    }

    func testEvictsLeastRecentlyUsedPastCapacity() async throws {
        let (cache, directory) = makeCache(capacity: 250)
        let clip = Data(repeating: 1, count: 100)
        await cache.store(clip, forKey: "old")
        await cache.store(clip, forKey: "middle")
        // Make the order unambiguous, then use "old" so "middle" is the stalest.
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: directory.appendingPathComponent("old.audio").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200)], ofItemAtPath: directory.appendingPathComponent("middle.audio").path)
        _ = await cache.audio(forKey: "old")

        await cache.store(clip, forKey: "new")

        let old = await cache.audio(forKey: "old")
        let middle = await cache.audio(forKey: "middle")
        let new = await cache.audio(forKey: "new")
        XCTAssertNotNil(old, "recently used, so kept")
        XCTAssertNil(middle, "least recently used, so evicted")
        XCTAssertNotNil(new)
        let total = await cache.totalBytes()
        XCTAssertLessThanOrEqual(total, 250)
    }

    func testRemoveAllEmptiesTheCache() async {
        let (cache, _) = makeCache()
        await cache.store(Data(repeating: 2, count: 10), forKey: "a")
        await cache.store(Data(repeating: 3, count: 10), forKey: "b")

        await cache.removeAll()

        let total = await cache.totalBytes()
        let gone = await cache.audio(forKey: "a")
        XCTAssertEqual(total, 0)
        XCTAssertNil(gone)
    }
}

final class VoiceFallbackTests: XCTestCase {
    // MARK: Classifying errors

    func testFallsBackOnQuotaAuthNetworkServerAndEngineFailures() {
        func error(_ code: String) -> AlkiSpeakError {
            AlkiSpeakError.generation(code: code, title: "", message: "", recoverySuggestion: "")
        }
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.http.429")), .quota)
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.http.402")), .quota)
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.http.401")), .auth)
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.api-key-missing")), .auth)
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.http.503")), .server)
        XCTAssertEqual(VoiceFallback.reason(for: error("cloud.request-failed")), .network)
        XCTAssertEqual(VoiceFallback.reason(for: error("edge.request-failed")), .network)
        XCTAssertEqual(VoiceFallback.reason(for: error("native-kokoro.failed")), .unavailable)
        XCTAssertEqual(VoiceFallback.reason(for: AlkiSpeakError.engine(code: "wake-failed", title: "", message: "", recoverySuggestion: "")), .unavailable)
        XCTAssertEqual(VoiceFallback.reason(for: error(UsageMeter.capReachedCode)), .cap)
        XCTAssertEqual(VoiceFallback.reason(for: URLError(.timedOut)), .timeout)
        XCTAssertEqual(VoiceFallback.reason(for: URLError(.notConnectedToInternet)), .network)
        let timedOut = AlkiSpeakError.generation(
            code: "cloud.request-failed", title: "", message: "", recoverySuggestion: "",
            context: ["urlErrorCode": "\(URLError.Code.timedOut.rawValue)"]
        )
        XCTAssertEqual(VoiceFallback.reason(for: timedOut), .timeout)
    }

    func testDoesNotFallBackOnCancellationOrBadInput() {
        func error(_ code: String) -> AlkiSpeakError {
            AlkiSpeakError.generation(code: code, title: "", message: "", recoverySuggestion: "")
        }
        XCTAssertNil(VoiceFallback.reason(for: CancellationError()))
        XCTAssertNil(VoiceFallback.reason(for: URLError(.cancelled)))
        XCTAssertNil(VoiceFallback.reason(for: error("cancelled")))
        XCTAssertNil(VoiceFallback.reason(for: error("cloud.http.400")), "bad input fails the same anywhere")
        XCTAssertNil(VoiceFallback.reason(for: error("cloud.voice-missing")))
        XCTAssertNil(VoiceFallback.reason(for: error("cloud.dialogue.empty")))
    }

    // MARK: Usage

    private func isolatedDefaults() -> UserDefaults {
        let name = "usage-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testProviderKeys() {
        XCTAssertEqual(UsageMeter.providerKey(forVoice: "edge:en-US-AriaNeural", cloudProviderID: nil), "edge")
        XCTAssertEqual(UsageMeter.providerKey(forVoice: "kokoro-native:af_heart", cloudProviderID: nil), "kokoro-native")
        XCTAssertEqual(UsageMeter.providerKey(forVoice: "af_bella*0.60,am_michael*0.40", cloudProviderID: nil), "kokoro")
        XCTAssertEqual(UsageMeter.providerKey(forVoice: "cloud:x", cloudProviderID: "elevenlabs"), "elevenlabs")
        XCTAssertTrue(UsageMeter.freeProviders.contains("mlx-audio"))
        XCTAssertFalse(UsageMeter.freeProviders.contains("elevenlabs"))
    }

    func testRecordsPerMonthAndComputesSpend() async {
        var date = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let meter = UsageMeter(defaults: isolatedDefaults(), now: { date })
        await meter.update { $0.pricePerMillion["elevenlabs"] = 300 }

        await meter.record(provider: "elevenlabs", characters: 10_000)
        await meter.record(provider: "elevenlabs", characters: 5_000)
        date = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        await meter.record(provider: "elevenlabs", characters: 1_000)

        let settings = await meter.settings()
        XCTAssertEqual(settings.characters(forMonth: "2026-10", provider: "elevenlabs"), 15_000)
        XCTAssertEqual(settings.characters(forMonth: "2026-11", provider: "elevenlabs"), 1_000)
        XCTAssertEqual(settings.spend(forMonth: "2026-10", provider: "elevenlabs") ?? -1, 4.5, accuracy: 0.0001)
        XCTAssertNil(settings.spend(forMonth: "2026-10", provider: "edge"), "no price, no spend")
    }

    func testCapBlocksOnceReached() async throws {
        let meter = UsageMeter(defaults: isolatedDefaults())
        await meter.update { $0.monthlyCap["openai"] = 100 }
        await meter.record(provider: "openai", characters: 80)

        try await meter.checkCap(provider: "openai", adding: 20)
        do {
            try await meter.checkCap(provider: "openai", adding: 21)
            XCTFail("expected the cap to stop this")
        } catch {
            XCTAssertEqual(VoiceFallback.reason(for: error), .cap)
        }
        try await meter.checkCap(provider: "edge", adding: 1_000_000)
    }

    // MARK: Generating with fallback

    private final class FakeVoice: SpeechGenerating {
        var failures: [Error]
        private(set) var calls = 0
        let tag: String
        init(_ tag: String, failures: [Error] = []) { self.tag = tag; self.failures = failures }
        func checkHealth() async -> Bool { true }
        func fetchVoices() async throws -> [String] { [] }
        func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
            calls += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            return SpeechGenerationResult(audioData: Data("\(tag):\(text)".utf8), latencyMs: 1, charCount: text.count)
        }
    }

    @MainActor
    private func generator(_ voices: [FakeVoice], meter: UsageMeter, notices: @escaping (String) -> Void) -> FallbackGenerator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return FallbackGenerator(
            candidates: voices.map {
                .init(voice: $0.tag, label: $0.tag.capitalized, service: $0, cacheConfiguration: $0.tag, providerKey: $0.tag, needsPythonEngine: false)
            },
            cache: AudioClipCache(directory: directory),
            usage: meter,
            prepareEngine: { _ in },
            onFallback: { from, to, reason in notices("\(from.voice)->\(to.voice):\(reason.rawValue)") }
        )
    }

    @MainActor
    func testMovesToTheNextVoiceAndStaysThere() async throws {
        let quota = AlkiSpeakError.generation(code: "cloud.http.429", title: "", message: "", recoverySuggestion: "")
        let primary = FakeVoice("eleven", failures: [quota])
        let backup = FakeVoice("edge")
        var notices: [String] = []
        let gen = generator([primary, backup], meter: UsageMeter(defaults: isolatedDefaults())) { notices.append($0) }

        let first = try await gen.generate(text: "One.", jobID: nil)
        let second = try await gen.generate(text: "Two.", jobID: nil)

        XCTAssertEqual(String(decoding: first.result.audioData, as: UTF8.self), "edge:One.")
        XCTAssertEqual(String(decoding: second.result.audioData, as: UTF8.self), "edge:Two.")
        XCTAssertEqual(primary.calls, 1, "the failed voice isn't retried for later segments")
        XCTAssertEqual(notices, ["eleven->edge:quota"])
    }

    @MainActor
    func testCapReachedFallsBackWithoutCallingThePaidVoice() async throws {
        let meter = UsageMeter(defaults: isolatedDefaults())
        await meter.update { $0.monthlyCap["eleven"] = 3 }
        let primary = FakeVoice("eleven")
        let backup = FakeVoice("edge")
        var notices: [String] = []
        let gen = generator([primary, backup], meter: meter) { notices.append($0) }

        _ = try await gen.generate(text: "Too long.", jobID: nil)

        XCTAssertEqual(primary.calls, 0)
        XCTAssertEqual(notices, ["eleven->edge:cap"])
        let settings = await meter.settings()
        XCTAssertEqual(settings.characters(forMonth: UsageMeter.monthKey(for: Date()), provider: "edge"), 9)
    }

    @MainActor
    func testErrorsThatWouldFailAnywhereAreNotRetriedElsewhere() async {
        let badInput = AlkiSpeakError.generation(code: "cloud.http.400", title: "", message: "", recoverySuggestion: "")
        let primary = FakeVoice("eleven", failures: [badInput])
        let backup = FakeVoice("edge")
        let gen = generator([primary, backup], meter: UsageMeter(defaults: isolatedDefaults())) { _ in }

        do {
            _ = try await gen.generate(text: "Hi.", jobID: nil)
            XCTFail("expected the error to surface")
        } catch {
            XCTAssertEqual((error as? AlkiSpeakError)?.code, "generation.cloud.http.400")
        }
        XCTAssertEqual(backup.calls, 0)
    }

    @MainActor
    func testTheLastVoiceFailingSurfacesItsError() async {
        let down = AlkiSpeakError.generation(code: "cloud.http.503", title: "", message: "", recoverySuggestion: "")
        let gen = generator([FakeVoice("a", failures: [down]), FakeVoice("b", failures: [down])], meter: UsageMeter(defaults: isolatedDefaults())) { _ in }

        do {
            _ = try await gen.generate(text: "Hi.", jobID: nil)
            XCTFail("expected the error to surface")
        } catch {
            XCTAssertEqual(VoiceFallback.reason(for: error), .server)
        }
    }

    // MARK: Mixed formats in one job

    func testPlayerConvertsAClipToTheJobsFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let url = directory.appendingPathComponent("in.caf")
        do {
            // The writer finalizes the file when it goes out of scope.
            let file = try AVAudioFile(forWriting: url, settings: source.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            try file.write(from: buffer)
        }
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 44_100)

        let converted = try AVAudioFile(forReading: AVAudioPlaybackCoordinator.convert(AVAudioFile(forReading: url), toSampleRate: 24_000, channels: 1))

        XCTAssertEqual(converted.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(converted.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(converted.length) / 24_000, 1.0, accuracy: 0.05, "one second in, one second out")
    }
}

@MainActor
final class FakeAutomationTarget: SpeechAutomationTarget {
    var automationVoices: [VoiceOption] = [
        VoiceOption(id: "af_heart", label: "Heart", isLocal: false),
        VoiceOption(id: "edge:en-US-AriaNeural", label: "Aria", isLocal: false)
    ]
    var selectedVoice = "af_heart"
    var spoken: [(text: String, voice: String?)] = []
    var rendered: [(text: String, voice: String)] = []
    var stops = 0
    var audio = Data("RIFFfake".utf8)
    var renderError: Error?

    func resolveAutomationVoice(_ query: String?) -> String? {
        AutomationVoices.resolve(query, in: automationVoices, selected: selectedVoice)
    }

    func speakExternalText(_ text: String, voice: String?) {
        spoken.append((text, voice))
    }

    func renderAutomationAudio(text: String, voice: String) async throws -> Data {
        if let renderError { throw renderError }
        rendered.append((text, voice))
        return audio
    }

    func stopPlayback() {
        stops += 1
    }
}

final class AutomationTests: XCTestCase {
    // MARK: Links

    func testLinksParse() {
        XCTAssertEqual(
            AutomationCommand(url: URL(string: "alkispeak://speak?text=Hello%20there%2C%20you&voice=Aria")!),
            .speak(text: "Hello there, you", voice: "Aria")
        )
        XCTAssertEqual(AutomationCommand(url: URL(string: "AlkiSpeak://Speak?text=Hi")!), .speak(text: "Hi", voice: nil))
        XCTAssertEqual(AutomationCommand(url: URL(string: "alkispeak://speak?text=Hi&voice=")!), .speak(text: "Hi", voice: nil))
        XCTAssertEqual(AutomationCommand(url: URL(string: "alkispeak://stop")!), .stop)
        XCTAssertEqual(AutomationCommand(url: URL(string: "alkispeak://pause")!), .pauseOrResume)
        XCTAssertEqual(AutomationCommand(url: URL(string: "alkispeak:stop")!), .stop)
    }

    func testBadLinksAreRejected() {
        XCTAssertNil(AutomationCommand(url: URL(string: "alkispeak://speak")!), "no text")
        XCTAssertNil(AutomationCommand(url: URL(string: "alkispeak://speak?text=%20%20")!), "blank text")
        XCTAssertNil(AutomationCommand(url: URL(string: "alkispeak://delete-everything")!))
        XCTAssertNil(AutomationCommand(url: URL(string: "https://speak?text=Hi")!))
    }

    func testVoicesResolveByIDOrName() {
        let options = [
            VoiceOption(id: "af_heart", label: "Heart", isLocal: false),
            VoiceOption(id: "edge:en-US-AriaNeural", label: "Aria", isLocal: false),
            VoiceOption(id: "cloud:gone", label: "Gone", source: .api, isAvailable: false, appleQuality: nil)
        ]
        XCTAssertEqual(AutomationVoices.resolve(nil, in: options, selected: "af_heart"), "af_heart")
        XCTAssertEqual(AutomationVoices.resolve("  ", in: options, selected: "af_heart"), "af_heart")
        XCTAssertEqual(AutomationVoices.resolve("edge:en-US-AriaNeural", in: options, selected: "af_heart"), "edge:en-US-AriaNeural")
        XCTAssertEqual(AutomationVoices.resolve(options[1].name.uppercased(), in: options, selected: "af_heart"), "edge:en-US-AriaNeural")
        XCTAssertNil(AutomationVoices.resolve("cloud:gone", in: options, selected: "af_heart"), "unavailable voices aren't used")
        XCTAssertNil(AutomationVoices.resolve("Nobody", in: options, selected: "af_heart"))
    }

    // MARK: HTTP

    func testRequestParsesOnceComplete() throws {
        let raw = "POST /v1/speak?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 13\r\nAuthorization: Bearer abc\r\n\r\n"
        XCTAssertNil(try HTTPRequest.parse(Data((raw + "{\"text\":").utf8)), "body still arriving")
        XCTAssertNil(try HTTPRequest.parse(Data("POST /v1/speak HTTP/1.1\r\nHost: l".utf8)), "headers still arriving")

        let request = try XCTUnwrap(try HTTPRequest.parse(Data((raw + "{\"text\":\"Hi\"}").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/speak")
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"text\":\"Hi\"}")
    }

    func testOversizedRequestsAreRefused() {
        let raw = "POST /v1/speak HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        XCTAssertThrowsError(try HTTPRequest.parse(Data(raw.utf8))) { XCTAssertEqual($0 as? HTTPError, .payloadTooLarge) }
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: 65, count: 20_000)))
    }

    func testResponseSerializes() {
        let text = String(decoding: HTTPResponse.json(202, ["status": "speaking"]).serialized, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 21\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"status\":\"speaking\"}"))
    }

    // MARK: Routing

    private func request(_ method: String, _ path: String, _ body: Any? = nil) -> HTTPRequest {
        HTTPRequest(
            method: method,
            path: path,
            headers: [:],
            body: body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        )
    }

    private func json(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    @MainActor
    func testListsVoices() async {
        let target = FakeAutomationTarget()
        let response = await LocalAPIRouter.respond(to: request("GET", "/v1/voices"), target: target)
        XCTAssertEqual(response.status, 200)
        let voices = json(response)["data"] as? [[String: Any]]
        XCTAssertEqual(voices?.compactMap { $0["id"] as? String }, ["af_heart", "edge:en-US-AriaNeural"])
        XCTAssertEqual(voices?.first?["selected"] as? Bool, true)
    }

    @MainActor
    func testSpeakSpeaksAndReturnsAtOnce() async {
        let target = FakeAutomationTarget()
        let response = await LocalAPIRouter.respond(to: request("POST", "/v1/speak", ["text": "Hello", "voice": "Aria"]), target: target)
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(json(response)["voice"] as? String, "edge:en-US-AriaNeural")
        XCTAssertEqual(target.spoken.map(\.text), ["Hello"])
        XCTAssertEqual(target.spoken.first?.voice, "edge:en-US-AriaNeural")

        let withoutVoice = await LocalAPIRouter.respond(to: request("POST", "/speak", ["text": "Again"]), target: target)
        XCTAssertEqual(withoutVoice.status, 202)
        XCTAssertEqual(target.spoken.last?.voice, "af_heart", "no voice means the selected one")
    }

    @MainActor
    func testBadSpeakRequestsAreRejected() async {
        let target = FakeAutomationTarget()
        let noText = await LocalAPIRouter.respond(to: request("POST", "/v1/speak", ["voice": "Aria"]), target: target)
        let badVoice = await LocalAPIRouter.respond(to: request("POST", "/v1/speak", ["text": "Hi", "voice": "Nobody"]), target: target)
        let notJSON = await LocalAPIRouter.respond(to: HTTPRequest(method: "POST", path: "/v1/speak", headers: [:], body: Data("hi".utf8)), target: target)
        let tooLong = await LocalAPIRouter.respond(
            to: request("POST", "/v1/speak", ["text": String(repeating: "a", count: LocalAPIRouter.maxInputCharacters + 1)]),
            target: target
        )
        XCTAssertEqual([noText.status, badVoice.status, notJSON.status, tooLong.status], [400, 400, 400, 413])
        XCTAssertTrue(target.spoken.isEmpty)
        XCTAssertNotNil((json(badVoice)["error"] as? [String: Any])?["message"])
    }

    @MainActor
    func testSpeechEndpointReturnsWAV() async {
        let target = FakeAutomationTarget()
        let response = await LocalAPIRouter.respond(
            to: request("POST", "/v1/audio/speech", ["model": "tts-1", "input": "Hello", "voice": "af_heart"]),
            target: target
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "audio/wav")
        XCTAssertEqual(response.body, target.audio)
        XCTAssertEqual(response.headers["X-AlkiSpeak-Voice"], "af_heart")
        XCTAssertEqual(target.rendered.map(\.text), ["Hello"])
        XCTAssertTrue(target.spoken.isEmpty, "making audio doesn't play it")

        let mp3 = await LocalAPIRouter.respond(to: request("POST", "/v1/audio/speech", ["input": "Hi", "response_format": "mp3"]), target: target)
        XCTAssertEqual(mp3.status, 400)
    }

    @MainActor
    func testSpeechEndpointReportsGenerationFailures() async {
        let target = FakeAutomationTarget()
        target.renderError = AlkiSpeakError.generation(code: "x", title: "T", message: "Voice is down.", recoverySuggestion: "")
        let response = await LocalAPIRouter.respond(to: request("POST", "/v1/audio/speech", ["input": "Hi"]), target: target)
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual((json(response)["error"] as? [String: Any])?["message"] as? String, "Voice is down.")
    }

    @MainActor
    func testStopAndUnknownRoutes() async {
        let target = FakeAutomationTarget()
        let stop = await LocalAPIRouter.respond(to: request("POST", "/v1/stop"), target: target)
        let wrongMethod = await LocalAPIRouter.respond(to: request("GET", "/v1/speak"), target: target)
        let missing = await LocalAPIRouter.respond(to: request("GET", "/v1/nothing"), target: target)
        XCTAssertEqual([stop.status, wrongMethod.status, missing.status], [200, 405, 404])
        XCTAssertEqual(target.stops, 1)
    }

    // MARK: Server

    func testServerNeedsTheTokenAndOnlyListensLocally() async throws {
        let port = UInt16.random(in: 48_000...58_000)
        let server = LocalSpeechAPIServer(port: port, token: "secret") { request in
            .json(200, ["path": request.path])
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/voices")!)
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)

        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, wrong) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 401)

        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (body, allowed) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"path\":\"/v1/voices\"}")
    }

    // MARK: Joining audio

    private func wav(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ])
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    func testJoinsClipsOfDifferentFormatsIntoOneWAV() throws {
        let joined = try AudioJoiner.wav(from: [
            wav(seconds: 0.5, sampleRate: 24_000, channels: 1),
            wav(seconds: 0.5, sampleRate: 44_100, channels: 2)
        ])
        XCTAssertEqual(joined.prefix(4), Data("RIFF".utf8))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("joined-\(UUID().uuidString).wav")
        try joined.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 24_000, 1.0, accuracy: 0.05)
    }
}

// MARK: - One delivery across segments

extension CloudSpeechServiceTests {
    private func clonedVoice(reference: String = "/tmp/ref.wav") -> CloudVoice {
        CloudVoice(
            providerID: CloudProvider.localMLX.id,
            model: LocalVoiceCatalog.cloningModelID,
            voice: "",
            label: "My voice (local)",
            referenceAudioPath: reference,
            referenceText: "Hi, this is my voice."
        )
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testClonedVoiceSamplesCloseToTheLikeliestReading() throws {
        let cloned = clonedVoice()
        settings.settings.voices = [cloned]

        let body = try jsonBody(service.makeRequest(text: "Read this.", voiceID: cloned.voiceID))

        XCTAssertEqual(body["temperature"] as? Double, 0.3)
        XCTAssertEqual(body["top_p"] as? Double, 0.8)
        XCTAssertEqual(body["repetition_penalty"] as? Double, 1.05)
    }

    func testClonedVoiceContinuesFromThePreviousSegment() throws {
        let dir = try temporaryDirectory()
        let reference = try writeTone(seconds: 4, sampleRate: 24_000, channels: 1, in: dir)
        let previous = try writeTone(seconds: 2, sampleRate: 48_000, channels: 2, in: dir)
        let cloned = clonedVoice(reference: reference.path)
        settings.settings.voices = [cloned]
        let context = SpeechContext(previousText: "The morning started quietly.", previousAudioURL: previous)

        let continuation = try XCTUnwrap(CloudSpeechGenerationService.continuationReference(for: cloned, context: context))
        defer { try? FileManager.default.removeItem(at: continuation.url) }

        XCTAssertEqual(continuation.text, "Hi, this is my voice. The morning started quietly.")
        let file = try AVAudioFile(forReading: continuation.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 24_000, 4 + VoiceCloneReference.continuationGap + 2, accuracy: 0.05)

        let body = try jsonBody(service.makeRequest(text: "Next.", voiceID: cloned.voiceID, context: context, continuation: continuation))
        XCTAssertEqual(body["ref_audio"] as? String, continuation.url.path)
        XCTAssertEqual(body["ref_text"] as? String, continuation.text)
    }

    func testContinuationNeedsTheClonedVoicesOwnPreviousClip() throws {
        let dir = try temporaryDirectory()
        let reference = try writeTone(seconds: 4, sampleRate: 24_000, channels: 1, in: dir)
        let previous = try writeTone(seconds: 2, sampleRate: 24_000, channels: 1, in: dir)
        let cloned = clonedVoice(reference: reference.path)

        XCTAssertNil(CloudSpeechGenerationService.continuationReference(for: cloned, context: .none), "the first segment starts from the recording")
        XCTAssertNil(CloudSpeechGenerationService.continuationReference(for: cloned, context: SpeechContext(previousAudioURL: previous)), "the words must come with the audio")
        XCTAssertNil(CloudSpeechGenerationService.continuationReference(for: openRouterVoice, context: SpeechContext(previousText: "Hi.", previousAudioURL: previous)))
        XCTAssertNil(try VoiceCloneReference.continuation(of: reference, then: previous, maximumAddedSeconds: 1), "a long previous clip would slow every request")
    }

    func testElevenLabsStitchesOntoTheSegmentsAround() throws {
        let voice = CloudVoice(providerID: CloudProvider.elevenLabs.id, model: "eleven_multilingual_v2", voice: "abc", label: "A")
        settings.settings.voices = [voice]
        try secrets.setSecret("xi-test", for: CloudProvider.elevenLabs.id)
        let context = SpeechContext(previousText: "Before.", nextText: "After.", previousRequestIDs: ["r1", "r2", "r3", "r4"])

        let body = try jsonBody(service.makeRequest(text: "Now.", voiceID: voice.voiceID, context: context))

        XCTAssertEqual(body["previous_text"] as? String, "Before.")
        XCTAssertEqual(body["next_text"] as? String, "After.")
        XCTAssertEqual(body["previous_request_ids"] as? [String], ["r2", "r3", "r4"], "ElevenLabs reads at most the last three")
    }

    func testElevenLabsReadsTheSegmentAloneWhenStitchingIsRefused() async throws {
        let voice = CloudVoice(providerID: CloudProvider.elevenLabs.id, model: "eleven_v4", voice: "abc", label: "A")
        settings.settings.voices = [voice]
        try secrets.setSecret("xi-test", for: CloudProvider.elevenLabs.id)
        StubURLProtocol.responseHeaders = ["request-id": "req-7"]
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { request in
            let body = (try? JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data())) as? [String: Any] ?? [:]
            bodies.append(body)
            return body["previous_text"] == nil ? (200, Data("mp3".utf8)) : (400, Data(#"{"detail":{"message":"not supported"}}"#.utf8))
        }

        let result = try await service.synthesize(text: "Now.", voice: voice.voiceID, jobID: nil, context: SpeechContext(previousText: "Before."))

        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies[1]["previous_text"])
        XCTAssertEqual(result.audioData, Data("mp3".utf8))
        XCTAssertEqual(result.requestID, "req-7")
    }
}

final class SegmentConsistencyTests: XCTestCase {
    // MARK: Segments

    func testSegmentsEndAtSentencesAndComeOutEven() {
        let text = (1...12).map { "Sentence number \($0) carries on for a little while here." }.joined(separator: " ")
        let segments = TextBatcher.segments(for: text)
        let lengths = segments.map(\.count)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.hasSuffix(".") })
        XCTAssertEqual(segments.joined(separator: " "), text)
        XCTAssertTrue(lengths.allSatisfy { $0 <= 250 })
        XCTAssertLessThanOrEqual(lengths.max()! - lengths.min()!, 60, "segments should be about the same size: \(lengths)")
    }

    func testALongSentenceSplitsAtClausesBeforeSpaces() {
        let text = Array(repeating: "this clause runs on for quite a while", count: 10).joined(separator: ", ") + "."
        XCTAssertGreaterThan(text.count, 300)

        let segments = TextBatcher.segments(for: text)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.dropLast().allSatisfy { $0.hasSuffix(",") }, "\(segments)")
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    func testUnpunctuatedTextIsCutBetweenWords() {
        let text = String(repeating: "Long text without punctuation ", count: 40).trimmingCharacters(in: .whitespaces)

        let segments = TextBatcher.segments(for: text)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 250 })
        XCTAssertEqual(segments.joined(separator: " "), text, "every cut falls on a space")
    }

    func testAScrapAtTheEndJoinsTheSegmentBefore() {
        let first = String(repeating: "A", count: 205) + "."
        XCTAssertEqual(TextBatcher.segments(for: first + " Ok."), [first + " Ok."])
    }

    func testLongSizingKeepsAQuickOpeningThenReadsParagraphs() {
        let text = (1...30).map { "Sentence \($0) of a longer reading goes on like this." }.joined(separator: " ")

        let segments = EngineRequestPolicy.live.segments(for: text, leadIn: false, sizing: .long).map(\.text)

        XCTAssertGreaterThan(segments.count, 2)
        XCTAssertLessThanOrEqual(segments[0].count, 250, "the first request is as quick as before")
        XCTAssertTrue(segments.dropFirst().allSatisfy { $0.count > 250 && $0.count <= 550 }, "\(segments.map(\.count))")
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    func testVoicesThatStitchRequestsGenerateOneAtATime() {
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "cloud:\(UUID())", runsOnThisMac: false, chainsRequests: true), 1)
        XCTAssertEqual(EngineRequestPolicy.generationConcurrency(forVoice: "cloud:\(UUID())", runsOnThisMac: false), 2)
    }

    // MARK: Chain

    func testSegmentChainHandsOnTextAudioAndAnUnbrokenRunOfRequestIDs() async {
        let chain = SegmentChain(texts: ["a.", "b.", "c.", "d.", "e."])
        for index in 0..<4 {
            await chain.record(index: index, audioURL: URL(fileURLWithPath: "/tmp/\(index).wav"), requestID: "r\(index)")
        }

        let first = await chain.context(for: 0)
        XCTAssertNil(first.previousText)
        XCTAssertEqual(first.nextText, "b.")
        XCTAssertNil(first.previousAudioURL)
        XCTAssertEqual(first.previousRequestIDs, [])

        let last = await chain.context(for: 4)
        XCTAssertEqual(last.previousText, "d.")
        XCTAssertNil(last.nextText)
        XCTAssertEqual(last.previousAudioURL, URL(fileURLWithPath: "/tmp/3.wav"))
        XCTAssertEqual(last.previousRequestIDs, ["r1", "r2", "r3"])

        // A cached segment has no request ID, which breaks the run.
        await chain.record(index: 2, audioURL: URL(fileURLWithPath: "/tmp/2.wav"), requestID: nil)
        let afterGap = await chain.context(for: 4)
        XCTAssertEqual(afterGap.previousRequestIDs, ["r3"])
    }

    func testAFallbackVoiceGetsOnlyTheSurroundingText() {
        let context = SpeechContext(previousText: "a.", nextText: "c.", previousAudioURL: URL(fileURLWithPath: "/tmp/a.wav"), previousRequestIDs: ["r"])
        XCTAssertEqual(context.textOnly, SpeechContext(previousText: "a.", nextText: "c."))
    }

    func testChainPausesFitWhereTheTextWasSplit() {
        let chain = SegmentChain(texts: ["It ended.", "and then,", "mid", "Done."])
        XCTAssertEqual(chain.pause(after: 0), ClipConditioner.sentencePause)
        XCTAssertEqual(chain.pause(after: 1), ClipConditioner.clausePause)
        XCTAssertEqual(chain.pause(after: 2), ClipConditioner.wordPause)
        XCTAssertEqual(chain.pause(after: 3), 0, "nothing after the last segment")
        XCTAssertEqual(ClipConditioner.pause(after: "He said “stop.”", isLast: false), ClipConditioner.sentencePause)
    }

    // MARK: Conditioning

    private let rate: Double = 24_000

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func testConditioningTrimsSilenceLevelsSpeechAndEndsOnThePause() {
        let clip = silence(0.5) + tone(seconds: 1, amplitude: 0.05) + silence(0.7)

        let output = ClipConditioner.condition(clip, sampleRate: rate, trailingPause: 0.25)

        let seconds = Double(output.count) / rate
        XCTAssertEqual(seconds, 1 + 2 * ClipConditioner.edgeMargin + 0.25, accuracy: 0.03)
        XCTAssertEqual(output[0], 0, "faded in")
        let speech = output[Int(0.3 * rate)..<Int(0.8 * rate)]
        XCTAssertEqual(rms(speech), ClipConditioner.targetLevel, accuracy: 0.005)
        XCTAssertTrue(output.suffix(Int(0.25 * rate)).allSatisfy { $0 == 0 })
    }

    func testConditioningBringsQuietAndLoudClipsToOneLevel() {
        let quiet = ClipConditioner.condition(tone(seconds: 1, amplitude: 0.03), sampleRate: rate, trailingPause: 0)
        let loud = ClipConditioner.condition(tone(seconds: 1, amplitude: 0.4), sampleRate: rate, trailingPause: 0)

        XCTAssertEqual(rms(quiet[2_400..<21_600]), rms(loud[2_400..<21_600]), accuracy: 0.003)
    }

    func testConditioningNeverPushesPeaksPastTheCeiling() {
        var clip = tone(seconds: 1, amplitude: 0.02)
        clip[12_000] = 0.6

        let output = ClipConditioner.condition(clip, sampleRate: rate, trailingPause: 0)

        XCTAssertLessThanOrEqual(output.map(abs).max()!, ClipConditioner.peakCeiling + 0.0001)
    }

    func testConditionedClipIsAWAVAtTheSameRate() throws {
        let data = AudioPCM.wav(silence(0.2) + tone(seconds: 0.5, amplitude: 0.1) + silence(0.2), sampleRate: rate)

        let conditioned = ClipConditioner.condition(data, trailingPause: 0.1)
        let decoded = try AudioPCM.decode(conditioned)

        XCTAssertEqual(decoded.sampleRate, rate)
        XCTAssertEqual(Double(decoded.samples.count) / rate, 0.5 + 2 * ClipConditioner.edgeMargin + 0.1, accuracy: 0.03)
    }

    func testConditioningLeavesUnreadableAudioAlone() {
        let data = Data("not audio".utf8)
        XCTAssertEqual(ClipConditioner.condition(data, trailingPause: 0.2), data)
    }
}
