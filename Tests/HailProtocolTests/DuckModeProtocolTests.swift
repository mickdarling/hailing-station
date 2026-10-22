import Foundation
import Testing
@testable import HailProtocol

/// #735: the host tells a device whether the owner's rubber-duck mode is on. Shaped exactly like `media_mode` (#612):
/// strict and closed, a boolean, an optional reason from a fixed vocabulary, and an expiry only while on.
@Suite struct DuckModeProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func theCapabilityAndReasonsAreFixed() {
        #expect(DuckMode.capability == "duck_mode")
        #expect(DuckMode.reasons == ["voice", "timeout", "device"])
    }

    @Test func onAndOffRoundTripWithTheirReasonAndExpiry() throws {
        try roundTrip(.duckMode(on: true))
        try roundTrip(.duckMode(on: false))
        for reason in DuckMode.reasons {
            try roundTrip(.duckMode(on: true, reason: reason, expires: 1_758_210_851_000))
            try roundTrip(.duckMode(on: false, reason: reason))
        }
        #expect(try decodeControl(#"{"command":"duck_mode","on":true,"reason":"device","expires":5}"#)
            == .duckMode(on: true, reason: "device", expires: 5))
        #expect(try decodeControl(#"{"command":"duck_mode","on":false}"#) == .duckMode(on: false))
    }

    /// Duck and media mode are distinct commands: one never decodes as the other.
    @Test func duckModeIsNotMediaMode() throws {
        #expect(try decodeControl(#"{"command":"duck_mode","on":true}"#) != .mediaMode(on: true))
        #expect(throws: DecodingError.self) {
            try decodeControl(#"{"command":"media_mode","on":true,"reason":"device"}"#)
        }
    }

    @Test(arguments: [
        #"{"command":"duck_mode"}"#, #"{"command":"duck_mode","on":"true"}"#, #"{"command":"duck_mode","on":null}"#,
        #"{"command":"duck_mode","on":true,"reason":"Voice"}"#, #"{"command":"duck_mode","on":true,"reason":"media"}"#,
        #"{"command":"duck_mode","on":true,"reason":1}"#, #"{"command":"duck_mode","on":true,"expires":0}"#,
        #"{"command":"duck_mode","on":true,"expires":-5}"#, #"{"command":"duck_mode","on":false,"expires":5}"#,
        #"{"command":"duck_mode","on":true,"expires":"soon"}"#,
        #"{"command":"duck_mode","on":true,"target":"tmux:a"}"#, #"{"command":"duck_mode","on":true,"text":"x"}"#
    ])
    func anythingElseIsRefused(_ payload: String) {
        #expect(throws: DecodingError.self) { try decodeControl(payload) }
    }

    @Test func invalidValuesAreRefusedWhenEncodingToo() {
        let refused: [ControlPayload] = [
            .duckMode(on: true, reason: "media"), .duckMode(on: false, expires: 5), .duckMode(on: true, expires: 0)
        ]
        for control in refused {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }
}
