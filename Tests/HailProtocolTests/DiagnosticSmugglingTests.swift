import Foundation
import Testing
@testable import HailProtocol

/// Byte-level validation (#234 round 2): the log's readers include AI agents, so no invisible or look-alike
/// text may ride inside an otherwise valid name, key, token or version.
@Suite struct DiagnosticSmugglingTests {
    private func frame(_ events: String) -> Data {
        Data(("{\"v\":1,\"id\":\"0B0B0B0B-0000-4000-8000-0000000000E2\",\"ts\":1,\"type\":\"control\","
              + "\"source\":\"t\",\"payload\":{\"command\":\"diagnostic\",\"events\":[\(events)]}}").utf8)
    }

    /// Invisible or look-alike text (#234 round 2): tag characters (ASCII smuggling), combining marks, zero-width
    /// joiners and fullwidth digits must never pass, even where they join a valid character into one grapheme.
    static let smuggled = [
        "1\u{E0041}\u{E0042}", "0.1.84\u{E0049}\u{E0047}\u{E004E}", "1\u{0301}", "1\u{200D}2", "\u{FF11}.0",
        "2\u{FE0F}", "1.\u{0663}"
    ]

    @Test(arguments: smuggled)
    func versionsAreCheckedOnBytesNotCharacters(value: String) {
        #expect(!DiagnosticLimits.isVersion(value))
        #expect(throws: DiagnosticEventInvalid(field: .os)) {
            try DiagnosticEvent(.appInfo, timestamp: 1, fields: [.os: .token(value)])
        }
    }

    @Test(arguments: [
        "user\u{E0041}", "user\u{0301}", "us\u{200D}er", "user\u{200B}", "\u{FF55}ser", "user\u{FE0F}"
    ])
    func tokensAreCheckedOnBytesNotCharacters(value: String) {
        #expect(throws: DiagnosticEventInvalid(field: .reason)) {
            try DiagnosticEvent(.ambientStop, timestamp: 1, fields: [.reason: .token(value)])
        }
        let json = "{\"ts\":1,\"name\":\"ambient_stop\",\"fields\":{\"reason\":\"\(value)\"}}"
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame(json)) }
    }

    @Test(arguments: ["ambient_stop\u{E0041}", "ambient_stop\u{0301}", "ambient\u{200D}_stop"])
    func eventNamesAndFieldKeysAreCheckedOnBytes(value: String) {
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame("{\"ts\":1,\"name\":\"\(value)\"}")) }
        let key = value.replacingOccurrences(of: "ambient_stop", with: "reason")
            .replacingOccurrences(of: "ambient\u{200D}_stop", with: "rea\u{200D}son")
        let json = "{\"ts\":1,\"name\":\"ambient_stop\",\"fields\":{\"\(key)\":\"user\"}}"
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame(json)) }
    }

    @Test func plainVersionsStillPass() {
        for value in ["0", "0.1.84", "26.0.1", "1.2.3.4", "999999"] { #expect(DiagnosticLimits.isVersion(value)) }
        for value in ["1.2.3.4.5", "1234567", "1..2", ".1", "1.", "", "1.2\n"] {
            #expect(!DiagnosticLimits.isVersion(value))
        }
    }
}
