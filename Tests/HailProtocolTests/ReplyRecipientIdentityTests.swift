import Foundation
import Testing
@testable import HailProtocol

@Suite struct ReplyRecipientIdentityTests {
    @Test func legacyDescriptorOmitsRequestIdentity() throws {
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "tmux:test")
        let data = try JSONEncoder().encode(reply)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["request"] == nil)
        #expect(try JSONDecoder().decode(ReplyDescriptor.self, from: data).requestID == nil)
    }

    @Test func explicitNullRequestIsRejectedRatherThanDowngraded() throws {
        let data = try descriptorData(request: NSNull())
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReplyDescriptor.self, from: data) }
    }

    @Test func textAndEveryAudioSegmentRetainExactRequestIdentity() throws {
        let request = UUID()
        let stream = UUID()
        let reply = ReplyDescriptor(
            id: UUID(), hostID: "mac-test", targetID: "tmux:test", audioStreamID: stream,
            priority: .urgent, interruption: .duck, requestID: request
        )
        let text = Frame(
            timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "synthetic reply", reply: reply))
        )
        let decoded = try FrameCoding.decode(FrameCoding.encode(text))
        guard case .text(let payload) = decoded.payload else {
            Issue.record("expected text payload")
            return
        }
        #expect(payload.reply == reply)
        for sequence in 0..<3 {
            let audio = AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                streamID: stream, isFinal: sequence == 2, bytes: Data([0, 0]), reply: reply
            )
            let frame = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .audio(audio))
            let decodedAudio = try FrameCoding.decode(FrameCoding.encode(frame))
            guard case .audio(let payload) = decodedAudio.payload else {
                Issue.record("expected audio payload")
                return
            }
            #expect(payload.reply == reply)
            #expect(payload.reply?.requestID == request)
            #expect(payload.sequence == sequence)
            #expect(payload.isFinal == (sequence == 2))
        }
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        #expect(object["request"] as? String == request.uuidString)
        #expect(object["requestID"] == nil)
    }

    @Test func malformedRequestIdentityIsRejected() throws {
        let invalid: [Any] = [true, 123, [], ["id": UUID().uuidString], "not-a-uuid", "", "device-name"]
        for request in invalid {
            let data = try descriptorData(request: request)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReplyDescriptor.self, from: data) }
        }
    }

    @Test func requestIdentityCannotOverrideEnvelopeOrStreamProvenance() throws {
        let reply = ReplyDescriptor(
            id: UUID(), hostID: "mac-test", targetID: "tmux:test", audioStreamID: UUID(), requestID: UUID()
        )
        for frame in [
            Frame(timestamp: 1, target: "tmux:other", source: reply.hostID,
                  payload: .text(TextPayload(text: "synthetic reply", reply: reply))),
            Frame(timestamp: 1, target: reply.targetID, source: "mac-other",
                  payload: .text(TextPayload(text: "synthetic reply", reply: reply))),
            Frame(timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
                streamID: UUID(), bytes: Data([0, 0]), reply: reply
            )))
        ] {
            let data = try FrameCoding.encode(frame)
            #expect(throws: DecodingError.self) { try FrameCoding.decode(data) }
        }
    }

    private func descriptorData(request: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "host": "mac-test", "target": "tmux:test",
            "priority": "normal", "interruption": "enqueue", "request": request
        ])
    }
}
