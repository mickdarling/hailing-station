import Foundation
import Testing
@testable import HailProtocol

/// rightyo#164: the owner-voice status a host sends a device, and the input route kind a device tells a host. Both
/// closed vocabularies, both strict, neither carrying a name.
@Suite struct OwnerVoiceProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func bothCommandsRoundTripWithTheirClosedVocabularies() throws {
        for state in OwnerVoice.states { try roundTrip(.ownerVoice(state: state)) }
        for route in AmbientInput.routes { try roundTrip(.ambientInput(route: route)) }
        #expect(try decodeControl(#"{"command":"owner_voice","state":"unrecognized"}"#)
            == .ownerVoice(state: "unrecognized"))
        #expect(try decodeControl(#"{"command":"ambient_input","route":"car_audio"}"#)
            == .ambientInput(route: "car_audio"))
    }

    /// The route vocabulary is the diagnostic one, so the two can never drift apart.
    @Test func theRouteVocabularyIsTheDiagnosticOne() {
        #expect(AmbientInput.routes == DiagnosticField.route.tokens)
        #expect(AmbientInput.routes.contains("usb_audio") && AmbientInput.routes.contains("car_audio"))
    }

    @Test(arguments: [
        #"{"command":"owner_voice"}"#, #"{"command":"owner_voice","state":"Unrecognized"}"#,
        #"{"command":"owner_voice","state":"tentative"}"#, #"{"command":"owner_voice","state":null}"#,
        #"{"command":"owner_voice","state":1}"#, #"{"command":"owner_voice","state":"recognized","score":0.4}"#,
        #"{"command":"ambient_input"}"#, #"{"command":"ambient_input","route":"USB_AUDIO"}"#,
        #"{"command":"ambient_input","route":"Mick's AirPods"}"#, #"{"command":"ambient_input","route":null}"#,
        #"{"command":"ambient_input","route":"usb_audio","name":"Scarlett 2i2"}"#
    ])
    func anythingOutsideTheVocabularyIsRefused(_ payload: String) {
        #expect(throws: DecodingError.self) { try decodeControl(payload) }
    }

    @Test func unknownTokensAreRefusedWhenEncodingToo() {
        for control in [ControlPayload.ownerVoice(state: "tentative"), .ambientInput(route: "Scarlett 2i2")] {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control)))
            }
        }
    }
}
