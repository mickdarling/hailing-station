import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplySegmentsListenerTests {
    @Test(arguments: [false, true])
    func sameReplyIsGatedAtEverySendBoundary(privacyClip: Bool) async throws {
        try await ReplySegmentsRig.withDevices(secondCapable: false) { rig in
            #expect(rig.first.hello.capabilities.contains(ReplySegments.capability))
            #expect(rig.second.hello.capabilities.contains(ReplySegments.capability))
            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                        audioStreamID: UUID())
            let frame = segmentAudio(reply, sequence: 0)
            for device in [rig.first, rig.second] {
                if privacyClip {
                    let result = await device.peer.deliverRequestlessClip(
                        [frame], hold: PrivateReplyHold(), onLateSuccess: [{}]
                    )
                    #expect(result.count == 1)
                } else {
                    guard case .delivered = await device.peer.deliverRequestlessReply(frame) else {
                        Issue.record("reply not delivered")
                        return
                    }
                }
            }
            let capableBytes = try await segmentSocketBytes(on: rig.first.socket)
            #expect(try capableBytes == FrameCoding.encode(frame))
            let legacyBytes = try await segmentSocketBytes(on: rig.second.socket)
            let expected = deviceFrame(frame, capable: false)
            #expect(try legacyBytes == FrameCoding.encode(expected))
            #expect(try FrameCoding.decode(legacyBytes) == expected)
            #expect(await rig.first.session.segmentedReplies == [reply.id])
            #expect(await rig.second.session.segmentedReplies.isEmpty)
        }
    }

    @Test func yieldIsScopedIdempotentAndStopsPublicationWithoutAStopFrame() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let reply = try await rig.startReply(on: rig.first)
            let other = recipientDescriptor(try await rig.recipient.submit(on: rig.second.session), audio: true)
            // The same connection can have another reply in flight without a new owner request.
            let sibling = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                          audioStreamID: UUID())
            _ = await rig.first.peer.deliverRequestlessReply(recipientAudio(sibling, sequence: 0))
            _ = try await recipientSocketReceive(on: rig.first.socket)
            try #require(await rig.listener.publish(recipientAudio(other, sequence: 0)) == 1)
            _ = try await recipientSocketReceive(on: rig.second.socket)
            try await rig.second.yield(reply.id, segment: 10_000)
            try await recipientSocketBarrier(on: rig.second.socket)
            #expect(!(await rig.listener.segmentTestStopped(reply.id)))
            #expect(await rig.first.session.repliesInFlight.contains(reply.id))
            try await rig.first.yield(reply.id, segment: 7)
            try await recipientSocketBarrier(on: rig.first.socket) // Also proves no stop_playback was sent.
            #expect(await rig.listener.segmentTestStopped(reply.id))
            #expect(await rig.first.session.segmentedReplies.isEmpty)
            #expect(await rig.first.session.repliesInFlight == [sibling.id])
            #expect(await rig.second.session.repliesInFlight == [other.id])
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await rig.listener.publish(recipientAudio(reply, sequence: 1, final: true))
            }
            #expect(await rig.first.peer.replyPublicationStatus(recipientAudio(reply, sequence: 1)) == .absent)
            try await rig.first.yield(reply.id)
            try await rig.first.yield(UUID())
            try await recipientSocketBarrier(on: rig.first.socket)
            let details = rig.events.control.filter { $0.event == "reply_yield" }.compactMap(\.detail)
            #expect(details == ["outcome=ignored segment=10000", "outcome=accepted segment=7",
                                "outcome=ignored segment=1", "outcome=ignored segment=1"])
            #expect(!details.joined().contains(reply.id.uuidString))
            // The listener's stop memory survives the yielding peer's departure.
            rig.first.close()
            #expect(await eventually { await rig.first.peer.ended })
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await rig.listener.publish(recipientAudio(reply, sequence: 1))
            }
        }
    }

    @Test func unknownAndFinishedYieldsDoNothing() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let reply = try await rig.startReply(on: rig.first)
            try #require(await rig.listener.publish(recipientAudio(reply, sequence: 1, final: true)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            try await rig.first.yield(reply.id)
            try await rig.first.yield(UUID())
            try await recipientSocketBarrier(on: rig.first.socket)
            #expect(await rig.first.session.repliesInFlight.isEmpty)
            #expect(await rig.first.session.segmentedReplies.isEmpty)
            #expect(await rig.first.session.stoppedReplies.isEmpty)
            #expect(!(await rig.listener.segmentTestStopped(reply.id)))
            #expect(rig.events.control.filter { $0.event == "reply_yield" }.map(\.detail)
                == ["outcome=ignored segment=1", "outcome=ignored segment=1"])
        }
    }

    @Test func peerTeardownClearsSegmentTracking() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            _ = try await rig.startReply(on: rig.first)
            #expect(await rig.first.session.segmentedReplies.count == 1)
            rig.first.close()
            #expect(await eventually { await rig.first.session.segmentedReplies.isEmpty })
        }
    }

    @Test func legacyPeerIsRefusedAndRemainsHealthy() async throws {
        try await ReplySegmentsRig.withDevices(firstCapable: false) { rig in
            let reply = try await rig.startReply(on: rig.first)
            try await rig.first.yield(reply.id, segment: 3)
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload
                == .control(.error(code: .unauthorized, message: "terminal action is not authorized")))
            try await recipientSocketBarrier(on: rig.first.socket)
            #expect(await rig.first.session.repliesInFlight == [reply.id])
            #expect(!(await rig.listener.segmentTestStopped(reply.id)))
            #expect(rig.events.control.last?.detail == "outcome=not_authorized segment=3")
            try #require(await rig.listener.publish(recipientAudio(reply, sequence: 1)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
        }
    }
}
