import Foundation
import HailProtocol
import HailProtocolFixtures
import Testing

/// #923 PR A: optional content-free IDs change the wire shape only when supplied.
@Suite struct HeardTurnProtocolTests {
    private let turn = UUID(uuidString: "00000000-0000-4000-8000-000000000923")

    @Test(arguments: [false, true])
    func heardAndRefusedFramesRoundTrip(carriesTurn: Bool) throws {
        let value = try #require(turn)
        let identifier = carriesTurn ? value : nil
        for payload: ControlPayload in [
            .ambientHeard(targetID: "tmux:a", text: "synthetic request", turn: identifier),
            .error(code: .voiceRouteRefused, message: "synthetic refusal", turn: identifier)
        ] {
            let frame = Frame(timestamp: 1, source: "host", payload: .control(payload))
            let data = try FrameCoding.encode(frame)
            #expect(try FrameCoding.decode(data) == frame)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let encoded = try #require(object["payload"] as? [String: Any])
            #expect((encoded["turn"] as? String) == identifier?.uuidString)
            #expect(encoded.keys.contains("turn") == carriesTurn)
        }
        #expect(HeardTurns.capability == "heard_turns")
    }

    @Test func oldShapesDecodeWithNoTurnAndKeepLegacyErrorExtensions() throws {
        let heard = #"{"command":"ambient_heard","target":"tmux:a","text":"synthetic request"}"#
        #expect(try decode(heard) == .ambientHeard(targetID: "tmux:a", text: "synthetic request"))
        let refused = #"{"command":"error","code":"voice_route_refused","message":"synthetic refusal"}"#
        #expect(try decode(refused) == .error(code: .voiceRouteRefused, message: "synthetic refusal"))
        #expect(try decode(String(refused.dropLast()) + #", "extension":true}"#)
            == .error(code: .voiceRouteRefused, message: "synthetic refusal"))
    }

    @Test(arguments: ["null", "false", "123", "[]", "{}", #""""#, #""not-a-uuid""#,
                      #""00000000-0000-4000-8000-000000000923\n""#])
    func invalidTurnsAreRefused(raw: String) {
        for prefix in [
            #"{"command":"ambient_heard","target":"tmux:a","text":"synthetic request","turn":"#,
            #"{"command":"error","code":"voice_route_refused","message":"synthetic refusal","turn":"#
        ] {
            #expect(throws: DecodingError.self) { try decode(prefix + raw + "}") }
        }
    }

    @Test func unknownFieldsStillFailOnHeardTurnFrames() throws {
        let identifier = try #require(turn).uuidString
        for prefix in [
            #"{"command":"ambient_heard","target":"tmux:a","text":"synthetic request""#,
            #"{"command":"error","code":"voice_route_refused","message":"synthetic refusal""#
        ] {
            let payload = prefix + #", "turn":"\#(identifier)","unknown":true}"#
            #expect(throws: DecodingError.self) { try decode(payload) }
        }
    }

    @Test func turnIsRefusedOnEveryOtherControlCommand() throws {
        for example in Fixtures.all {
            guard case .control(let control) = example.frame.payload else { continue }
            if case .ambientHeard = control { continue }
            var object = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(control)
            ) as? [String: Any])
            object["turn"] = try #require(turn).uuidString
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ControlPayload.self, from: data) }
        }
    }

    @Test(arguments: ["paste_refused", "not_allowed", "future_refusal"])
    func turnIsRefusedOnOtherErrorCodes(code: String) throws {
        let identifier = try #require(turn).uuidString
        let payload = #"{"command":"error","code":"\#(code)","message":"synthetic","turn":"\#(identifier)"}"#
        #expect(throws: DecodingError.self) { try decode(payload) }
    }

    @Test func turnRequiresVoiceRouteRefusedWhenEncodingAnError() throws {
        let identifier = try #require(turn)
        for code in [ErrorCode.pasteRefused, .notAllowed, .unknown("future_refusal")] {
            #expect(throws: EncodingError.self) {
                try JSONEncoder().encode(ControlPayload.error(code: code, message: "synthetic", turn: identifier))
            }
        }
    }

    private func decode(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }
}
