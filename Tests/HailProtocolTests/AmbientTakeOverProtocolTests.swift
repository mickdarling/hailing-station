import Foundation
import Testing
@testable import HailProtocol

/// #366: the wire vocabulary for ambient take-over. Devices are named by class only, from a closed set.
@Suite struct AmbientTakeOverProtocolTests {
    private func roundTrip(_ control: ControlPayload) throws -> String {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    @Test func ambientMovedHereCarriesOnlyAnOptionalDeviceClass() throws {
        #expect(try roundTrip(.ambientMovedHere(from: "phone"))
            .contains(#""payload":{"command":"ambient_moved_here","from":"phone"}"#))
        #expect(try roundTrip(.ambientMovedHere(from: nil)).contains(#""payload":{"command":"ambient_moved_here"}"#))
        #expect(try decodeControl(#"{"command":"ambient_moved_here","from":"pad"}"#) == .ambientMovedHere(from: "pad"))
    }

    @Test func ambientMovedHereRefusesFreeTextAndAnythingRidingAlong() {
        for payload in [
            #"{"command":"ambient_moved_here","from":"Mick's iPhone"}"#,
            #"{"command":"ambient_moved_here","from":"Phone"}"#,
            #"{"command":"ambient_moved_here","from":"pad","message":"x"}"#,
            #"{"command":"ambient_moved_here","target":"tmux:a"}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test func anUnlistedClassIsNeverEncoded() throws {
        let data = try JSONEncoder().encode(ControlPayload.ambientMovedHere(from: "watch"))
        #expect(String(bytes: data, encoding: .utf8) == #"{"command":"ambient_moved_here"}"#)
    }

    @Test func helloDeviceKindIsOptionalAndClosed() throws {
        let old = try decodeControl(#"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x"}}"#)
        #expect(old == .hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x")))
        let pad = try decodeControl(
            #"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x","deviceKind":"pad"}}"#
        )
        #expect(pad == .hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x", deviceKind: "pad")))
        // Strict: a value outside the vocabulary (here a device name) fails the hello.
        #expect(throws: DecodingError.self) {
            try decodeControl(
                #"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x","deviceKind":"Mick"}}"#
            )
        }
        #expect(HelloInfo(versions: [1], capabilities: [], deviceName: "x", deviceKind: "tv").deviceKind == nil)
        // Without a class the encoded hello is byte-identical to an older build's.
        #expect(!(try roundTrip(.hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x"))))
            .contains("deviceKind"))
    }

    @Test func movedMessagesNameOnlyAClass() {
        #expect(AmbientTakeOver.movedMessage(to: "pad") == "ambient moved to pad")
        #expect(AmbientTakeOver.movedMessage(to: "phone") == "ambient moved to phone")
        #expect(AmbientTakeOver.movedMessage(to: nil) == "ambient moved to another device")
        #expect(AmbientTakeOver.movedMessage(to: "Mick's iPad") == "ambient moved to another device")
        #expect(AmbientTakeOver.movedMessage(to: "pad").count <= ControlLimits.maxErrorMessage)
        #expect(AmbientTakeOver.moved("ambient moved to pad") == (true, "pad"))
        #expect(AmbientTakeOver.moved("ambient moved to another device") == (true, nil))
        #expect(AmbientTakeOver.moved("ambient busy") == (false, nil))
        #expect(AmbientTakeOver.moved("ambient stopped: listener exited") == (false, nil))
    }

    @Test func theSchemaListsTheCommandAndKeepsItStrict() {
        guard case .object(let root) = Schema.json, case .object(let defs)? = root["$defs"],
              case .object(let control)? = defs["control"], case .array(let rules)? = control["allOf"] else {
            Issue.record("schema shape changed")
            return
        }
        #expect(rules.contains(Schema.ambientMovedHerePayloadRule))
    }
}
