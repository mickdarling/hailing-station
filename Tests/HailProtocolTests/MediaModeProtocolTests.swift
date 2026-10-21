import Foundation
import Testing
@testable import HailProtocol

/// #612: the host tells a device whether the owner's spoken media mode (#551) is on. Strict and closed: a boolean, an
/// optional reason from a fixed vocabulary, and an expiry only while on.
@Suite struct MediaModeProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func onAndOffRoundTripWithTheirReasonAndExpiry() throws {
        try roundTrip(.mediaMode(on: true))
        try roundTrip(.mediaMode(on: false))
        for reason in MediaMode.reasons {
            try roundTrip(.mediaMode(on: true, reason: reason, expires: 1_758_210_851_000))
            try roundTrip(.mediaMode(on: false, reason: reason))
        }
        #expect(try decodeControl(#"{"command":"media_mode","on":true,"reason":"voice","expires":5}"#)
            == .mediaMode(on: true, reason: "voice", expires: 5))
        #expect(try decodeControl(#"{"command":"media_mode","on":false}"#) == .mediaMode(on: false))
    }

    @Test(arguments: [
        #"{"command":"media_mode"}"#, #"{"command":"media_mode","on":"true"}"#, #"{"command":"media_mode","on":null}"#,
        #"{"command":"media_mode","on":true,"reason":"Voice"}"#, #"{"command":"media_mode","on":true,"reason":"tv"}"#,
        #"{"command":"media_mode","on":true,"reason":1}"#, #"{"command":"media_mode","on":true,"expires":0}"#,
        #"{"command":"media_mode","on":true,"expires":-5}"#, #"{"command":"media_mode","on":false,"expires":5}"#,
        #"{"command":"media_mode","on":true,"expires":"soon"}"#,
        #"{"command":"media_mode","on":true,"target":"tmux:a"}"#
    ])
    func anythingElseIsRefused(_ payload: String) {
        #expect(throws: DecodingError.self) { try decodeControl(payload) }
    }

    @Test func invalidValuesAreRefusedWhenEncodingToo() {
        let refused: [ControlPayload] = [
            .mediaMode(on: true, reason: "tv"), .mediaMode(on: false, expires: 5), .mediaMode(on: true, expires: 0)
        ]
        for control in refused {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }
}
