import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplySegmentsBackstopTests {
    @Test(arguments: [false, true])
    func deliveredOwnerInputStopsOnlyItsSegmentedReplies(ambient: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let segmented = try await rig.startReply(on: rig.first)
            let other = try await rig.startReply(on: rig.second)
            let plain = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                        audioStreamID: UUID())
            _ = await rig.first.peer.deliverRequestlessReply(recipientAudio(plain, sequence: 0))
            _ = try await recipientSocketReceive(on: rig.first.socket)
            let sibling = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                          audioStreamID: UUID())
            _ = await rig.first.peer.deliverRequestlessReply(segmentAudio(sibling, sequence: 0))
            _ = try await recipientSocketReceive(on: rig.first.socket)
            if ambient {
                let request = dispatchRequest(connection: await rig.first.session.connectionID)
                _ = try await rig.listener.dispatchAmbient(
                    request, selection: await rig.first.session.selectionGeneration
                )
            } else {
                _ = try await rig.recipient.submit(on: rig.first.session)
            }
            try await recipientSocketBarrier(on: rig.first.socket)
            try await recipientSocketBarrier(on: rig.second.socket)
            #expect(await rig.first.session.repliesInFlight == [plain.id])
            #expect(await rig.first.session.segmentedReplies.isEmpty)
            #expect(await rig.second.session.repliesInFlight == [other.id])
            #expect(await rig.listener.segmentTestStopped(segmented.id))
            #expect(await rig.listener.segmentTestStopped(sibling.id))
            #expect(rig.events.control.last?.event == "reply_backstop")
            #expect(rig.events.control.last?.detail == "outcome=stopped count=2")
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await rig.listener.publish(recipientAudio(segmented, sequence: 1))
            }
            let nextPlain = recipientAudio(plain, sequence: 1)
            guard case .delivered = await rig.first.peer.deliverRequestlessReply(nextPlain) else {
                Issue.record("unsegmented reply was stopped")
                return
            }
            _ = try await recipientSocketReceive(on: rig.first.socket)
            try #require(await rig.listener.publish(recipientAudio(other, sequence: 1)) == 1)
            _ = try await recipientSocketReceive(on: rig.second.socket)
        }
    }

    @Test(arguments: [false, true])
    func deliveredInputWithoutSegmentedRepliesDoesNotLog(ambient: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let reply = try await rig.startReply(on: rig.first, segmented: false)
            if ambient {
                let request = dispatchRequest(connection: await rig.first.session.connectionID)
                _ = try await rig.listener.dispatchAmbient(
                    request, selection: await rig.first.session.selectionGeneration
                )
            } else {
                _ = try await rig.recipient.submit(on: rig.first.session)
            }
            try await recipientSocketBarrier(on: rig.first.socket)
            #expect(await rig.first.session.repliesInFlight == [reply.id])
            #expect(await rig.first.session.segmentedReplies.isEmpty)
            #expect(rig.events.control.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func legacyOwnerInputNeverCutsAReply(seededSegment: Bool) async throws {
        try await ReplySegmentsRig.withDevices(firstCapable: false) { rig in
            let reply = try await rig.startReply(on: rig.first)
            // A synthetic marker proves the capability guard independently of legacy frame stripping.
            if seededSegment { await rig.first.session.seedLegacySegmentForBackstopTest(reply.id) }
            _ = try await rig.recipient.submit(on: rig.first.session)
            try await recipientSocketBarrier(on: rig.first.socket)
            #expect(await rig.first.session.repliesInFlight == [reply.id])
            #expect(await rig.first.session.segmentedReplies == (seededSegment ? [reply.id] : []))
            #expect(!(await rig.listener.segmentTestStopped(reply.id)))
            #expect(rig.events.control.isEmpty)
            try #require(await rig.listener.publish(recipientAudio(reply, sequence: 1)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
        }
    }

    @Test func refusedOrHeldInputDoesNotCutUntilACompleteHandoff() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let reply = try await rig.startReply(on: rig.first)
            let before = rig.events.control.count
            await rig.recipient.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
            let input = sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic")))
            let refused = await rig.first.session.receive(input)
            #expect(!refused.frames.isEmpty)
            #expect(await rig.first.session.repliesInFlight == [reply.id])
            #expect(rig.events.control.count == before)
            await rig.recipient.adapter.passHandoff()
            await rig.recipient.adapter.holdHandoff()
            let handoff = Task { await rig.first.session.receive(input) }
            await rig.recipient.adapter.waitForHandoff()
            #expect(await rig.first.session.repliesInFlight == [reply.id])
            #expect(!(await rig.listener.segmentTestStopped(reply.id)))
            #expect(rig.events.control.count == before)
            await rig.recipient.adapter.releaseHandoff()
            #expect(await handoff.value.frames.isEmpty)
            #expect(await rig.first.session.repliesInFlight.isEmpty)
            #expect(await rig.listener.segmentTestStopped(reply.id))
            try await recipientSocketBarrier(on: rig.first.socket)
        }
    }
}

private extension HostSession {
    func seedLegacySegmentForBackstopTest(_ reply: UUID) {
        segmentedReplies.insert(reply)
    }
}
