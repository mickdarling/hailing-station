import Foundation
import Testing
@testable import HailProtocol

/// #609: a local session's unsolicited update, shown as a card naming the session (#371). Strict and closed.
@Suite struct SessionUpdateProtocolTests {
    private let update = UUID(uuidString: "0B0B0B0B-0000-4000-8000-0000000001B4") ?? UUID()

    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func roundTripsWithAndWithoutACard() throws {
        for priority in SessionUpdateCard.priorities {
            try roundTrip(.sessionUpdate(update: update, session: "Jarvis", priority: priority, text: "Done."))
            try roundTrip(.sessionUpdate(update: update, session: "Jarvis", priority: priority, text: "Done.",
                                         card: "PR #1 is green.\nhttps://example.com/pull/1"))
        }
        let decoded = try decodeControl(
            #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"Voice Work","#
                + #""priority":"info","text":"The deck is built."}"#
        )
        #expect(decoded == .sessionUpdate(update: update, session: "Voice Work", priority: "info",
                                          text: "The deck is built."))
    }

    @Test(arguments: [
        #"{"command":"session_update","session":"A","priority":"info","text":"x"}"#,
        #"{"command":"session_update","update":"nope","session":"A","priority":"info","text":"x"}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","priority":"info","text":"x"}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"","priority":"info","#
            + #""text":"x"}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"A\nB","#
            + #""priority":"info","text":"x"}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"A","#
            + #""priority":"Info","text":"x"}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"A","#
            + #""priority":"info","text":""}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"A","#
            + #""priority":"info","text":"x","card":null}"#,
        #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","session":"A","#
            + #""priority":"info","text":"x","target":"tmux:a"}"#
    ])
    func anythingOutsideTheShapeIsRefused(_ payload: String) {
        #expect(throws: DecodingError.self) { try decodeControl(payload) }
    }

    @Test func oversizedTextOrCardIsRefused() {
        let long = String(repeating: "a", count: PayloadLimits.maxTextBytes + 1)
        for (text, card) in [(long, "ok"), ("ok", long)] {
            let payload = #"{"command":"session_update","update":"0B0B0B0B-0000-4000-8000-0000000001B4","#
                + #""session":"A","priority":"info","text":"\#(text)","card":"\#(card)"}"#
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test func invalidSessionOrPriorityIsRefusedWhenEncodingToo() {
        for control in [
            ControlPayload.sessionUpdate(update: update, session: " A", priority: "info", text: "x"),
            .sessionUpdate(update: update, session: "A", priority: "urgent", text: "x")
        ] {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }
}
