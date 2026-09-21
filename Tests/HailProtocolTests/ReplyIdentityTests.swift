import Foundation
import HailProtocolFixtures
import Testing
@testable import HailProtocol

@Suite struct ReplyIdentityTests {
    @Test func overlappingFixturesRemainDistinctByReplyAndStream() throws {
        let replies = Fixtures.all.filter { $0.name.hasPrefix("reply-") }.compactMap { example -> ReplyDescriptor? in
            switch example.frame.payload {
            case .text(let text): text.reply
            case .audio(let audio): audio.reply
            default: nil
            }
        }
        #expect(Set(replies.map(\.id)).count == 3)
        #expect(Set(replies.compactMap(\.audioStreamID)).count == 3)
        #expect(Set(replies.map(\.hostID)) == ["mac-main", "ziggy"])
        #expect(Set(replies.map(\.targetID)) == ["tmux:codex-hail"])
        for replyID in Set(replies.map(\.id)) {
            let group = replies.filter { $0.id == replyID }
            #expect(group.count == 2)
            #expect(Set(group.compactMap(\.audioStreamID)).count == 1)
        }
    }

    @Test func audioCannotClaimAnotherReplysStream() throws {
        let reply = ReplyDescriptor(
            id: UUID(), hostID: "mac-main", targetID: "tmux:codex", audioStreamID: UUID()
        )
        let payload = AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
            streamID: UUID(), bytes: Data([0, 0]), reply: reply
        )
        let frame = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .audio(payload))
        let encoded = try FrameCoding.encode(frame)
        #expect(throws: DecodingError.self) { try FrameCoding.decode(encoded) }
    }

    @Test func replyCannotClaimAnotherEnvelope() throws {
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:codex")
        let frame = Frame(
            timestamp: 1, target: "tmux:claude", source: reply.hostID,
            payload: .text(TextPayload(text: "done", reply: reply))
        )
        let encoded = try FrameCoding.encode(frame)
        #expect(throws: DecodingError.self) { try FrameCoding.decode(encoded) }
    }

    @Test func legacyAudioWithoutReplyIdentityStillDecodes() throws {
        let json = Data(#"""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000003","ts":1,"type":"audio",
        "target":"tmux:a","source":"tmux:a","payload":{"codec":"pcm16","sampleRate":24000,
        "channels":1,"sequence":0,"bytes":"AAA="}}
        """#.utf8)
        let frame = try FrameCoding.decode(json)
        guard case .audio(let audio) = frame.payload else {
            Issue.record("expected audio")
            return
        }
        #expect(audio.reply == nil)
        #expect(audio.streamID == nil)
        #expect(audio.isFinal)
    }
}
