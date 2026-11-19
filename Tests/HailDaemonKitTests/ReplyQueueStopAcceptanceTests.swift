import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyQueueStopAcceptanceTests {
    @Test(arguments: [19_999, 20_000, 20_001])
    func exactQueueAdmissionBoundary(remainder: Int64) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        try await session.reserveTestAudioJob(reply)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        for _ in 0..<134 {
            rig.clock.advance(20_000)
            _ = await session.renewQueuedReplyAuthority()
        }
        rig.clock.advance(remainder)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)) == (remainder < 20_000))
    }

    @Test func unticketedFinalEnqueueMustOrderWithStopAcceptance() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        let queue = ReplyAudioQueue(now: rig.clock.instant)
        queue.register(context.connectionID)
        _ = try queue.ticket(frame: recipientAudio(reply, sequence: 0))
        await session.bindQueuedReplyAuthority(recipientText(reply), queue: queue)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        let stopWasAccepted = Mutex(false), submitted = Mutex(0)
        let accepted = await session.enqueueHostReply(recipientAudio(reply, sequence: 0), enqueue: { commit in
            // Accept Stop after the preliminary check but before commit acquires the queue/transport
            // locks. This synchronous interleaving needs neither a blocked thread nor a deadline.
            stopWasAccepted.withLock { $0 = queue.captureStop(context.connectionID) != nil }
            return commit {
                submitted.withLock { $0 += 1 }
                return true
            }
        })
        #expect(stopWasAccepted.withLock { $0 }, "Stop acceptance must complete before the commit")
        #expect(submitted.withLock { $0 } == 0, "No transport submission after accepted stop")
        #expect(!accepted, "Unticketed audio must not enqueue after its queue stop was accepted")
    }

    @Test(arguments: [false, true])
    func acceptedStopMustNotRetractLaterRequest(streamingLater: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            let old = recipientDescriptor(try await rig.recipient.submit(on: session), audio: true)
            _ = try await rig.listener.replyAudio(.init(action: "enqueue", frame: recipientAudio(old, sequence: 0)))
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let timeout = VoiceStopConfirmationHold()
            defer { release.release(); timeout.release() }
            let stopping = heldStop(rig, entered: entered, release: release, timeout: timeout)
            await entered.wait()
            let laterContext = try await rig.recipient.submit(on: session)
            let later = recipientDescriptor(laterContext, audio: true)
            let probe = recipientAudio(later, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            let waiting = VoiceStopConfirmationHold()
            let text = publishLaterText(later, rig: rig, waiting: waiting)
            await waiting.wait()
            let unreserved = try await rig.recipient.submit(on: session)
            release.release()
            #expect(await stopping.value == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(try await text.value == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            if streamingLater {
                #expect(try await rig.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: probe))
                    .skipped == false)
                _ = try await recipientSocketReceive(on: rig.first.socket)
            }
            let next = recipientAudio(later, sequence: streamingLater ? 1 : 0)
            #expect(await session.replyRequests[try #require(old.requestID)] == nil)
            #expect(await session.replyRequests[laterContext.id] != nil,
                    "Stop accepted before this request existed must preserve its publication authority")
            let checked = try? await rig.listener.replyAudio(.init(action: "check", ticket: ticket, frame: next))
            #expect(checked?.skipped == false)
            #expect(await session.replyRequests[unreserved.id] != nil)
            #expect(try await rig.listener.publish(next) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            #expect(await session.replyRequests[laterContext.id] != nil)
            #expect(!(await session.stoppedReplies.contains(later.id)))
        }
    }

    private func publishLaterText(
        _ reply: ReplyDescriptor, rig: ReplySegmentsRig, waiting: VoiceStopConfirmationHold
    ) -> Task<Int, any Error> {
        Task {
            try await ReplyAudioEnqueueTesting.$waitingForControl.withValue({ waiting.release() }, operation: {
                try await rig.listener.publish(recipientText(reply))
            })
        }
    }

    private func heldStop(
        _ rig: ReplySegmentsRig, entered: VoiceStopConfirmationHold,
        release: VoiceStopConfirmationHold, timeout: VoiceStopConfirmationHold
    ) -> Task<String, Never> {
        Task {
            await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    await rig.listener.stopReplyPlayback(
                        connection: rig.first.session.connectionID, markQueuedAudio: true
                    )
                })
            })
        }
    }
}
