import Foundation
import Testing
@testable import HailProtocol
import HailProtocolFixtures

/// Pins the security-relevant literals so a PR that loosens a limit fails here even when every derived test,
/// fixture, and schema moves with it (#47 control-defaults guard, #62 review).
@Suite struct LimitsAndNegativesTests {
    @Test func limitLiteralsAreTheDocumentedOnes() {
        #expect(PayloadLimits.maxTextBytes == 8_192)
        #expect(PayloadLimits.maxAudioBytes == 65_536)
        #expect(PayloadLimits.maxImageBytes == 8_388_608)
        #expect(PayloadLimits.sampleRates == 8_000...96_000)
        #expect(PayloadLimits.channels == 1...2)
        #expect(PayloadLimits.dimensions == 1...16_384)
        #expect(ControlLimits.maxErrorMessage == 256)
        #expect(PayloadLimits.defaultMaxFrameBytes == 65_536 * 4 / 3 + 4_096)
    }

    @Test(arguments: Fixtures.invalidNames().filter { $0 != "envelope-over-frame-cap" })
    func everyNegativeFixtureIsRejectedByItsPayloadRule(name: String) throws {
        // maxBytes lifted so a negative is rejected by the rule under test, never by the size guard.
        let data = try Fixtures.invalidData(for: name)
        #expect(throws: DecodingError.self, "\(name) should fail decoding") {
            try FrameCoding.decode(data, maxBytes: .max)
        }
    }

    @Test func oversizedFrameFixtureHitsTheSizeGuardFirst() throws {
        let data = try Fixtures.invalidData(for: "envelope-over-frame-cap")
        #expect(data.count > PayloadLimits.defaultMaxFrameBytes)
        #expect(throws: FrameCoding.FrameTooLarge(size: data.count, limit: PayloadLimits.defaultMaxFrameBytes)) {
            try FrameCoding.decode(data)
        }
    }

    @Test func audioOverRawCapIsRejectedByThePayloadRuleNotTheSizeGuard() throws {
        let data = try Fixtures.invalidData(for: "audio-bytes-over-cap")
        #expect(data.count <= PayloadLimits.defaultMaxFrameBytes)
        #expect(throws: DecodingError.self) { try FrameCoding.decode(data) }
    }

    @Test(arguments: ["image", "frame"])
    func imageAndScreenFrameBytesOverTheCapAreRejected(type: String) {
        let blob = Data(count: PayloadLimits.maxImageBytes + 1).base64EncodedString()
        let extra = type == "frame" ? #","streamId":"s","index":0"# : ""
        let payload = #"{"mimeType":"image/png","width":1,"height":1,"bytes":"\#(blob)"\#(extra)}"#
        let json = Data("""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-0000000000EE","ts":1,"type":"\(type)","source":"t","payload":\(payload)}
        """.utf8)
        #expect(throws: DecodingError.self) { try FrameCoding.decode(json, maxBytes: .max) }
    }

    @Test func negativeFixturesExist() {
        #expect(Fixtures.invalidNames().count >= 29)
    }
}
