import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyQueueStopCoverageTests {
    @Test func noReservationMustOrderTransportWithAcceptedStop() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        let queue = ReplyAudioQueue(now: rig.clock.instant)
        queue.register(context.connectionID)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        let stopAccepted = Mutex(false), submissions = Mutex(0)
        let accepted = await session.enqueueHostReply(recipientAudio(reply, sequence: 1), enqueue: { commit in
            // This callback precedes the final queue/transport locks. Accept Stop synchronously here;
            // waiting for a GCD worker would block the cooperative executor under parallel test load.
            stopAccepted.withLock { $0 = queue.captureStop(context.connectionID) != nil }
            return commit { submissions.withLock { $0 += 1 }; return true }
        })
        #expect(stopAccepted.withLock { $0 })
        #expect(!accepted)
        #expect(submissions.withLock { $0 } == 0)
    }

    @Test func unmarkedStopMustPreserveLaterRequest() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            _ = try await rig.recipient.submit(on: session)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            defer { release.release() }
            let stopping = Task {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    await rig.listener.stopReplyPlayback(connection: session.connectionID, markQueuedAudio: false)
                })
            }
            await entered.wait()
            let later = try await rig.recipient.submit(on: session)
            release.release()
            #expect(await stopping.value == "stopped")
            _ = try await recipientSocketReceive(on: rig.first.socket)
            let preserved = await session.replyRequests[later.id] != nil
            #expect(preserved)
        }
    }
}

extension ReplyQueueStopCoverageTests {
    @Test(arguments: [false, true])
    func realListenerMustRejectUnreservedContinuationAfterAcceptance(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            let old = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let timeout = VoiceStopConfirmationHold()
            defer { release.release(); timeout.release() }
            let stopping = Task {
                await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                    await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                        entered.release(); await release.wait()
                    }, operation: {
                        await rig.listener.stopReplyPlayback(
                            connection: session.connectionID, markQueuedAudio: markQueued
                        )
                    })
                })
            }
            await entered.wait()
            let delivered = try? await rig.listener.publish(recipientAudio(old, sequence: 1))
            if delivered == 1 { _ = try await recipientSocketReceive(on: rig.first.socket) }
            #expect(delivered != 1)
            release.release()
            _ = await stopping.value
            _ = try await recipientSocketReceive(on: rig.first.socket)
        }
    }

    @Test func stopOnOtherConnectionMustPreserveBoundRequestAuthority() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.second.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            _ = try await rig.listener.replyAudio(.init(action: "enqueue", frame: recipientAudio(reply, sequence: 0)))
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.second.socket)
            #expect(await rig.listener.stopReplyPlayback(
                connection: rig.first.session.connectionID, markQueuedAudio: true
            ) == "stopped")
            _ = try await recipientSocketReceive(on: rig.first.socket)
            rig.recipient.clock.advance(20_000)
            _ = await session.renewQueuedReplyAuthority()
            let preserved = await session.replyRequests[context.id] != nil
            #expect(preserved)
        }
    }
}
