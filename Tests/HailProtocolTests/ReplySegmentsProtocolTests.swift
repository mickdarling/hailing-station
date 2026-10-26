import Foundation
import HailProtocol
import Testing

/// #932 P1: wire vocabulary only; no sender advertises or acts on it yet.
@Suite struct ReplySegmentsProtocolTests {
    private let identifier = "00000000-0000-4000-8000-000000000932"

    @Test func segmentEndRoundTripsAndCapabilityIsStable() throws {
        let audio = try audioPayload()
        let encoded = try JSONEncoder().encode(audio)
        #expect(try JSONDecoder().decode(AudioPayload.self, from: encoded) == audio)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["segmentEnd"] as? Bool == true)
        #expect(ReplySegments.capability == "reply_segments")
        #expect(ReplySegments.maxSegmentEnds == 10_000)
    }

    @Test func legacyEncodingIsByteIdenticalAndUnknownAudioKeysAreIgnored() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var audio = AudioPayload(codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: 0, bytes: Data())
        let expected = #"{"bytes":"","channels":1,"codec":"pcm16","final":true,"sampleRate":16000,"sequence":0}"#
        #expect(try encoder.encode(audio) == Data(expected.utf8))
        audio.isSegmentEnd = false
        #expect(try encoder.encode(audio) == Data(expected.utf8))
        let extended = String(expected.dropLast()) + #", "future_audio_key":true}"#
        #expect(try decodeAudio(extended) == audio)
    }

    @Test(arguments: ["false", "null", "0", "1", "\"true\"", "[]", "{}"])
    func invalidSegmentEndValuesAreRefused(raw: String) throws {
        var object = try audioObject()
        object.removeValue(forKey: "segmentEnd")
        let base = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: DecodingError.self) {
            try decodeAudio(String(base.dropLast()) + ",\"segmentEnd\":" + raw + "}")
        }
    }

    @Test(arguments: ["final", "resume", "streamId", "reply"])
    func segmentEndRequiresNonFinalReplyStreamWithoutResume(field: String) throws {
        var object = try audioObject()
        if field == "final" || field == "resume" { object[field] = true } else { object.removeValue(forKey: field) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioPayload.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test(arguments: [1, 10_000])
    func replyYieldRoundTrips(segment: Int) throws {
        let reply = try #require(UUID(uuidString: identifier))
        let control = ControlPayload.replyYield(reply: reply, segment: segment)
        let encoded = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(ControlPayload.self, from: encoded) == control)
        #expect(try decodeControl(#"{"command":"reply_yield","reply":"\#(identifier)","segment":\#(segment)}"#)
            == control)
    }

    @Test(arguments: ["0", "-1", "10001", "1.5", "\"1\"", "null", "true", "[]", "{}"])
    func invalidSegmentCountsAreRefused(raw: String) {
        #expect(throws: DecodingError.self) {
            try decodeControl(#"{"command":"reply_yield","reply":"\#(identifier)","segment":\#(raw)}"#)
        }
    }

    @Test(arguments: ["null", "false", "1", "\"not-a-uuid\"", "\"\"", "[]", "{}",
                      #""00000000-0000-4000-8000-000000000932\n""#])
    func invalidReplyIdentifiersAreRefused(raw: String) {
        #expect(throws: DecodingError.self) {
            try decodeControl(#"{"command":"reply_yield","reply":\#(raw),"segment":1}"#)
        }
    }

    @Test func missingFieldsAndExtraKeysAreRefused() {
        for payload in [
            #"{"command":"reply_yield","segment":1}"#,
            #"{"command":"reply_yield","reply":"\#(identifier)"}"#,
            #"{"command":"reply_yield","reply":"\#(identifier)","segment":1,"extra":null}"#,
            #"{"command":"reply_yield","reply":"\#(identifier)","segment":1,"text":"synthetic"}"#
        ] {
            #expect(throws: DecodingError.self) { try decodeControl(payload) }
        }
    }

    @Test(arguments: [0, -1, 10_001])
    func encoderRefusesInvalidSegmentCounts(segment: Int) throws {
        let reply = try #require(UUID(uuidString: identifier))
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(ControlPayload.replyYield(reply: reply, segment: segment))
        }
    }

    private func audioPayload() throws -> AudioPayload {
        let stream = try #require(UUID(uuidString: identifier))
        let reply = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target", audioStreamID: stream)
        return AudioPayload(codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: 0,
                            streamID: stream, isFinal: false, bytes: Data(), reply: reply, isSegmentEnd: true)
    }

    private func audioObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(audioPayload())) as? [String: Any])
    }

    private func decodeAudio(_ payload: String) throws -> AudioPayload {
        try JSONDecoder().decode(AudioPayload.self, from: Data(payload.utf8))
    }

    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }
}
