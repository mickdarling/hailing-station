import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic transport evidence; the CLI lock test separately proves producer ordering, not physical playout.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplyNewRequestQueueTests {
    @Test(arguments: [false, true])
    func admittedOwnerRequestPreservesSegmentedStreamThroughTerminal(ambient: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let first = try await rig.startReply(on: rig.first)
            let interactions = rig.events.interactionCount
            let next: ReplyDescriptor
            if ambient {
                let request = dispatchRequest(connection: await rig.first.session.connectionID)
                let outcome = try await rig.listener.dispatchAmbient(
                    request, selection: await rig.first.session.selectionGeneration
                )
                let owner = try #require(outcome)
                let context = try #require(await rig.first.session.replyRequests[owner]?.context)
                next = recipientDescriptor(context, audio: true)
            } else {
                next = recipientDescriptor(try await rig.recipient.submit(on: rig.first.session), audio: true)
            }
            #expect(await rig.first.session.repliesInFlight == [first.id])
            #expect(!(await rig.listener.segmentTestStopped(first.id)))
            #expect(rig.events.control.isEmpty)
            #expect(rig.events.interactionCount == interactions + 1)
            // Text can arrive while the first reply is playing. Audio follows the producer's held turn lock.
            let text = recipientText(next)
            #expect(try await rig.listener.publish(text) == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == text)
            for frame in [segmentAudio(first, sequence: 1), recipientAudio(first, sequence: 2, final: true),
                          segmentAudio(next, sequence: 0), recipientAudio(next, sequence: 1, final: true)] {
                #expect(try await rig.listener.publish(frame) == 1)
                #expect(try await recipientSocketReceive(on: rig.first.socket) == frame)
            }
            #expect(await rig.first.session.repliesInFlight.isEmpty)
            try await recipientSocketBarrier(on: rig.first.socket)
        }
    }

    @Test func explicitStopStillCutsSegmentedPlaybackImmediately() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let first = try await rig.startReply(on: rig.first)
            _ = try await rig.recipient.submit(on: rig.first.session)
            #expect(await rig.listener.stopReplyPlayback(
                connection: rig.first.session.connectionID, markQueuedAudio: true
            ) == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await rig.first.session.repliesInFlight.isEmpty)
            #expect(await rig.listener.segmentTestStopped(first.id))
            // Current main sends the stop control, not an audio terminal (#1241 remainder).
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await rig.listener.publish(recipientAudio(first, sequence: 1, final: true))
            }
            try await recipientSocketBarrier(on: rig.first.socket)
        }
    }
}
