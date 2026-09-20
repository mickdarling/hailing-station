import Foundation
import Testing
@testable import HailProtocol

@Suite struct PayloadValidationTests {
    private func frameJSON(type: String, payload: String) -> Data {
        Data("""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000009","ts":1,"type":"\(type)","source":"t","payload":\(payload)}
        """.utf8)
    }

    // Rejection cases live in fixtures/invalid (one source for the decoder test and the schema checker).

    @Test func boundaryValuesAreAccepted() throws {
        let audio = #"{"codec":"pcm16","sampleRate":96000,"channels":2,"sequence":0,"bytes":"AA=="}"#
        _ = try FrameCoding.decode(frameJSON(type: "audio", payload: audio))
        let image = #"{"mimeType":"image/png","width":16384,"height":1,"bytes":""}"#
        _ = try FrameCoding.decode(frameJSON(type: "image", payload: image))
    }

    @Test func perTypeRawCapsAreEnforced() {
        let longText = String(repeating: "t", count: PayloadLimits.maxTextBytes + 1)
        #expect(throws: (any Error).self) {
            try FrameCoding.decode(frameJSON(type: "text", payload: #"{"text":"\#(longText)","final":true}"#))
        }
        let audio = Data(repeating: 1, count: PayloadLimits.maxAudioBytes + 1).base64EncodedString()
        let audioJSON = #"{"codec":"pcm16","sampleRate":48000,"channels":1,"sequence":0,"bytes":"\#(audio)"}"#
        #expect(throws: (any Error).self) {
            try FrameCoding.decode(frameJSON(type: "audio", payload: audioJSON), maxBytes: .max)
        }
    }

    @Test func deepNestingInUnknownPayloadFailsCleanly() {
        let nested = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        #expect(throws: (any Error).self) { try FrameCoding.decode(frameJSON(type: "hologram", payload: nested)) }
        let shallow = String(repeating: "[", count: 50) + String(repeating: "]", count: 50)
        #expect((try? FrameCoding.decode(frameJSON(type: "hologram", payload: shallow))) != nil)
    }

    @Test func oversizedInputIsRefusedBeforeParsing() {
        let big = Data(repeating: UInt8(ascii: "x"), count: PayloadLimits.defaultMaxFrameBytes + 1)
        #expect(throws: FrameCoding.FrameTooLarge(size: big.count, limit: PayloadLimits.defaultMaxFrameBytes)) {
            try FrameCoding.decode(big)
        }
        #expect(throws: (any Error).self) { try FrameCoding.decode(big, maxBytes: big.count) }
    }
}
