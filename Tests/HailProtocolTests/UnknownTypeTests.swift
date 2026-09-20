import Foundation
import Testing
@testable import HailProtocol

@Suite struct UnknownTypeTests {
    private let unknownJSON = Data("""
    {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000002","ts":5,"type":"hologram","source":"tmux:x","payload":{"z":1}}
    """.utf8)

    @Test func unknownTypeDecodesInsteadOfFailing() throws {
        let frame = try FrameCoding.decode(unknownJSON)
        #expect(frame.payload == .unknown(type: "hologram", payload: .object(["z": .integer(1)])))
        #expect(frame.payload.type == nil)
        #expect(frame.source == "tmux:x")
    }

    @Test func controlWithUnknownCommandFailsRatherThanSilentlyPassing() {
        let json = Data("""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000003","ts":5,"type":"control","source":"terminal",\
        "payload":{"command":"reboot"}}
        """.utf8)
        #expect(throws: (any Error).self) { try FrameCoding.decode(json) }
    }

    @Test func unknownReencodesWithItsOriginalPayload() throws {
        let frame = try FrameCoding.decode(unknownJSON)
        let json = try #require(String(bytes: FrameCoding.encode(frame), encoding: .utf8))
        #expect(json.contains("\"type\":\"hologram\""))
        #expect(json.contains("\"payload\":{\"z\":1}"))
    }

    @Test func largeIntegersSurviveForwardingExactly() throws {
        let json = Data("""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000005","ts":5,"type":"future","source":"t",\
        "payload":{"seq":9007199254740993,"max":9223372036854775807,"ratio":0.5,"flag":true,"none":null}}
        """.utf8)
        let frame = try FrameCoding.decode(json)
        #expect(frame.payload == .unknown(type: "future", payload: .object([
            "seq": .integer(9_007_199_254_740_993), "max": .integer(.max), "ratio": .number(0.5),
            "flag": .bool(true), "none": .null
        ])))
        let out = try #require(String(bytes: FrameCoding.encode(frame), encoding: .utf8))
        #expect(out.contains("\"seq\":9007199254740993"))
        #expect(out.contains("\"max\":9223372036854775807"))
    }

    @Test func missingRequiredKeyStillFails() {
        let json = Data(#"{"v":1,"ts":5,"type":"text","source":"terminal","payload":{"text":"x"}}"#.utf8)
        #expect(throws: (any Error).self) { try FrameCoding.decode(json) }
    }
}
