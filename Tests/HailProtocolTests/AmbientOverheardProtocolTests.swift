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
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":"owner","role":"x"}"#,
            #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":null}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test func unknownTokensAreRefusedWhenEncodingToo() {
        for control in [ControlPayload.overheardScope(scope: "all"),
                        .ambientOverheard(targetID: "tmux:a", text: "hi", speaker: "Owner")] {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }

    /// #434: a known guest's display name rides only on `other`, within RightyO's own display-name bound.
    @Test(arguments: ["Ben", "Zoë", "Ben O'Neil", "李雷", String(repeating: "B", count: AmbientOverheard.maxNameScalars)])
    func aGuestsNameRoundTripsWithSpeakerOther(_ name: String) throws {
        try roundTrip(.ambientOverheard(targetID: "tmux:a", text: "Pass the salt.", speaker: "other", name: name))
        let wire = #"{"command":"ambient_overheard","target":"tmux:a","text":"hi","speaker":"other","name":"\#(name)"}"#
        let decoded = try decodeControl(wire)
        #expect(decoded == .ambientOverheard(targetID: "tmux:a", text: "hi", speaker: "other", name: name))
    }

    @Test(arguments: [
        #""name":"Ben","speaker":"owner""#, #""name":"","speaker":"other""#, #""name":" Ben","speaker":"other""#,
        #""name":"Ben ","speaker":"other""#, #""name":"Ben\nSmith","speaker":"other""#,
        #""name":"Ben\u0007","speaker":"other""#, #""name":"Ben‎","speaker":"other""#,
        #""name":1,"speaker":"other""#, #""name":null,"speaker":"other""#,
        #""name":"\#(String(repeating: "B", count: AmbientOverheard.maxNameScalars + 1))","speaker":"other""#
    ])
    func aBadOrMisplacedNameIsRefused(_ fields: String) {
        #expect(throws: DecodingError.self) {
            try decodeControl(#"{"command":"ambient_overheard","target":"tmux:a","text":"hi",\#(fields)}"#)
        }
    }

    @Test func aNameIsRefusedWhenEncodingOnOwnerOrOutOfBounds() {
        for (speaker, name) in [("owner", "Ben"), ("other", ""), ("other", "Ben\n"), ("other", " Ben")] {
            let control = ControlPayload.ambientOverheard(targetID: "tmux:a", text: "hi", speaker: speaker, name: name)
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }

    @Test func overheardScopeRefusesAnythingButAKnownScope() {
        for payload in [
            #"{"command":"overheard_scope"}"#,
            #"{"command":"overheard_scope","scope":"all"}"#,
            #"{"command":"overheard_scope","scope":"Owner"}"#,
            #"{"command":"overheard_scope","scope":"owner","target":"tmux:a"}"#,
            #"{"command":"overheard_scope","scope":1}"#,
            #"{"command":"overheard_scope","scope":null}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }
}
