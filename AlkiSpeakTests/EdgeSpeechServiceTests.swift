import XCTest
@testable import Woadie

final class EdgeSpeechServiceTests: XCTestCase {
    func testIDPrefixRoundTrip() {
        let voiceID = EdgeSpeechGenerationService.idPrefix + "en-US-AriaNeural"
        XCTAssertEqual(EdgeSpeechGenerationService.stripPrefix(voiceID), "en-US-AriaNeural")
    }

    func testStripPrefixIsNoOpWithoutPrefix() {
        XCTAssertEqual(EdgeSpeechGenerationService.stripPrefix("af_heart"), "af_heart")
    }

    func testEdgeSourceReportsSynthesisSupported() {
        XCTAssertTrue(VoiceSource.edge.isSynthesisSupported)
    }

    func testEdgeVoiceOptionIsNotLocal() {
        let option = VoiceOption(id: EdgeSpeechGenerationService.idPrefix + "en-US-AriaNeural", label: "Edge - en-US-AriaNeural", source: .edge)
        XCTAssertFalse(option.isLocal)
    }
}
