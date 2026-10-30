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
    private let openRouterVoice = CloudVoice(providerID: CloudProvider.openRouter.id, model: "mistralai/voxtral-mini-tts-2603", voice: "en_paul_neutral", label: "Paul")

    override func setUp() {
        super.setUp()
        settings = InMemoryCloudSpeechSettingsStore(CloudSpeechSettings(voices: [openRouterVoice]))
        secrets = InMemorySecretStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        service = CloudSpeechGenerationService(settings: settings, secrets: secrets, session: URLSession(configuration: configuration))
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
}
