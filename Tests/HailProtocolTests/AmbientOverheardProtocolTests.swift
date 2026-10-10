import Foundation
import Testing
@testable import HailProtocol

/// #398: overheard turns, sent only within the scope the device asked for.
@Suite struct AmbientOverheardProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func bothCommandsRoundTripWithTheirClosedVocabularies() throws {
        for speaker in AmbientOverheard.speakers {
            try roundTrip(.ambientOverheard(targetID: "tmux:a", text: "Pass the salt.", speaker: speaker))
        }
        for scope in AmbientOverheard.scopes { try roundTrip(.overheardScope(scope: scope)) }
        #expect(try decodeControl(#"{"command":"overheard_scope","scope":"everyone"}"#)
            == .overheardScope(scope: "everyone"))
    }

    @Test func ambientOverheardRefusesBadOrExtraFields() {
        let oversized = String(repeating: "a", count: PayloadLimits.maxTextBytes + 1)
        for payload in [
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":"Owner"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":"Speaker B"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"","speaker":"owner"}"#,
            #"{"command":"ambient_overheard","target":"","text":"hi","speaker":"owner"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"\#(oversized)","speaker":"owner"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":"owner","role":"x"}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test func overheardScopeRefusesAnythingButAKnownScope() {
        for payload in [
            #"{"command":"overheard_scope"}"#,
            #"{"command":"overheard_scope","scope":"all"}"#,
            #"{"command":"overheard_scope","scope":"Owner"}"#,
            #"{"command":"overheard_scope","scope":"owner","target":"tmux:a"}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }
}
