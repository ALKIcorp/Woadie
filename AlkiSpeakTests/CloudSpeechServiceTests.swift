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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
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
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent/mlx_audio.server"), session: stubSession)

        try await manager.ensureRunning()

        XCTAssertFalse(manager.isOwnedServerRunning, "An adopted server must not be treated as ours")
    }

    func testManagerReportsMissingInstall() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let manager = MLXAudioServerManager(executableURL: URL(fileURLWithPath: "/nonexistent/mlx_audio.server"), session: stubSession)

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
        XCTAssertTrue(models.allSatisfy { !$0.voices.isEmpty && !$0.license.isEmpty && $0.downloadGB > 0 })
        let labels = models.flatMap(\.voices).map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "Every preset needs its own label")
        XCTAssertEqual(models.first?.id, "mlx-community/Ming-3.0-tts-0.5B-bf16", "Best-quality model listed first")
    }

    // MARK: Ming voice design and expression tags

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
