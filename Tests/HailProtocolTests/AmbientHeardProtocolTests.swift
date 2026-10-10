import Foundation
import Testing
@testable import HailProtocol

/// #318: the user's own ambient request, sent to the device that spoke so it can show their words in the thread.
@Suite struct AmbientHeardProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    @Test func ambientHeardCarriesTheTargetAndTheHeardText() throws {
        let frame = Frame(timestamp: 1, source: "host",
                          payload: .control(.ambientHeard(targetID: "tmux:a", text: "Haili, what's next?")))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        #expect(try decodeControl(#"{"command":"ambient_heard","target":"tmux:a","text":"hi"}"#)
            == .ambientHeard(targetID: "tmux:a", text: "hi"))
    }

    @Test func ambientHeardRefusesMissingEmptyOversizedOrExtraFields() {
        let oversized = String(repeating: "a", count: PayloadLimits.maxTextBytes + 1)
        for payload in [
            #"{"command":"ambient_heard","target":"tmux:a"}"#,
            #"{"command":"ambient_heard","text":"hi"}"#,
            #"{"command":"ambient_heard","target":"tmux:a","text":""}"#,
            #"{"command":"ambient_heard","target":"","text":"hi"}"#,
            #"{"command":"ambient_heard","target":"tmux:a","text":5}"#,
            #"{"command":"ambient_heard","target":"tmux:a","text":"\#(oversized)"}"#,
            #"{"command":"ambient_heard","target":"tmux:a","text":"hi","request":"x"}"#,
            #"{"command":"ambient_heard","target":"tmux:a","text":"hi","from":"phone"}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test func theTextCapCountsBytesNotCharacters() throws {
        let atCap = String(repeating: "é", count: PayloadLimits.maxTextBytes / 2)
        #expect(try decodeControl(#"{"command":"ambient_heard","target":"tmux:a","text":"\#(atCap)"}"#)
            == .ambientHeard(targetID: "tmux:a", text: atCap))
        let over = atCap + "é"
        #expect(throws: DecodingError.self) {
            try decodeControl(#"{"command":"ambient_heard","target":"tmux:a","text":"\#(over)"}"#)
        }
    }
}
