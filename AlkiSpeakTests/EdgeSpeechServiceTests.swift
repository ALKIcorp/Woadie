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

    /// Fixed-time regression vector, captured when the v2 port was verified
    /// against the live synthesis endpoint (v1 tokens now get HTTP 403).
    func testSecMSGECv2MatchesKnownVector() {
        let token = EdgeDRM.secMSGECv2(unixTime: 1_700_000_000, trustedClientToken: "6A5AA1D4EAFF4E9FB37E23D68491D6F4")
        XCTAssertEqual(token, "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2")
    }

    func testSecMSGECv2IsStableWithinFiveMinuteWindow() {
        let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        XCTAssertEqual(
            EdgeDRM.secMSGECv2(unixTime: 1_700_000_100, trustedClientToken: token),
            EdgeDRM.secMSGECv2(unixTime: 1_700_000_399, trustedClientToken: token)
        )
    }

    func testEdgeVoiceOptionIsNotLocal() {
        let option = VoiceOption(id: EdgeSpeechGenerationService.idPrefix + "en-US-AriaNeural", label: "Edge - en-US-AriaNeural", source: .edge)
        XCTAssertFalse(option.isLocal)
    }
}
