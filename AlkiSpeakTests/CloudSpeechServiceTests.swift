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
    var error: Error?

    func ensureRunning() async throws {
        ensureCount += 1
        if let error { throw error }
    }

    func stopOwnedServer() { stopCount += 1 }
}

final class FakeElevenLabsCatalog: ElevenLabsCatalogFetching {
    var catalog = ElevenLabsCatalog(voices: [], models: [])
    func fetchCatalog() async throws -> ElevenLabsCatalog { catalog }
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
}
