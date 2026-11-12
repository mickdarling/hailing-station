#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioExpiryTests {
    @Test(arguments: ["issuance", "association", "validation", "enqueue"])
    func abandonedAndSupersededTicketsExpireWithoutResurrection(pruning: String) throws {
        #expect(ReplyAudioQueue.jobLifetime == .seconds(26 * 3_600))
        let clock = QueuedAudioClock(), queue = clock.queue()
        let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0)
        let abandoned = try queue.ticket(), superseded = try queue.ticket(frame: frame)
        let streaming = try queue.ticket(frame: frame)
        clock.advance(.seconds(24 * 3_600))
        // A queued CLI job still has its whole stream lifetime after the 24-hour queue bound.
        #expect(queue.valid(abandoned))
        #expect(queue.valid(superseded))
        queue.associate(abandoned, frame: frame)
        #expect(queue.outstandingCount == 3)
        #expect(queue.enqueue(streaming, connection: nil, target: "U", publishing: true, { true }) == .sent(true))
        clock.advance(.seconds(2 * 3_600))
        switch pruning {
        case "issuance":
            let fresh = try queue.ticket()
            #expect(fresh.position == streaming.position + 1)
            #expect(queue.outstandingCount == 1)
            queue.finish(fresh)
        case "association": queue.associate(abandoned, frame: frame)
        case "validation": #expect(!queue.valid(superseded))
        default: #expect(queue.enqueue(superseded, connection: nil, target: "U", { true }) == .expired)
        }
        #expect(queue.outstandingCount == 0)
        for ticket in [abandoned, superseded, streaming] {
            queue.associate(ticket, frame: frame)
            #expect(!queue.valid(ticket))
            #expect(queue.enqueue(ticket, connection: nil, target: "U", { true }) == .expired)
        }
        #expect(queue.outstandingCount == 0)
    }

    @Test func terminalRefusalAndFinishedStreamCannotBeAssociatedAgain() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let finished = try await queuedAudioTicket(listener)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: finished, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "finished stream") == audio)
            let refused = try await queuedAudioTicket(listener)
            let unrouted = recipientAudio(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other",
                audioStreamID: UUID()), sequence: 0)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.replyAudio(.init(action: "check", ticket: refused, frame: unrouted))
            }
            #expect(rig.details("reply_audio_refused") == [
                "reason=noRecipient request=none ticket=\(refused.position)"
            ])
            for ticket in [finished, refused] {
                queue.associate(ticket, frame: audio)
                #expect(!queue.valid(ticket))
                #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio)).skipped)
            }
            #expect(queue.outstandingCount == 0)
            try await rig.pair.boundedBarrier(step: "terminal tickets stay invalid")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
extension ReplyQueuedAudioExpiryTests {
    @Test(arguments: ["check", "publish"])
    func requestPendingClearsResolvedBarrierBeforeNewUnknownStop(action: String) async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { clock.release(); timeout.release() }
        let rig = try await clock.makeRig()
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue, unrelated = UUID()
            queue.register(unrelated)
            let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
            let session = try #require(await listener.peers.values.first).session
            await session.queueTestCommit(context.id, committed: false)
            let audio = recipientAudio(recipientDescriptor(context, audio: true), sequence: 0, final: true)
            let ticket = try await queuedAudioTicket(listener)
            let first = try capture(queue, connection: unrelated, timeout: timeout)
            let checking = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                    try await listener.replyAudio(.init(action: action, ticket: ticket, frame: audio))
                })
            }
            await waiting.wait()
            await clock.sleepEntered.wait()
            queue.resolve(first, targets: [])
            await #expect(throws: LocalReplyRefusal.requestPending) { try await checking.value }
            clock.advance(.milliseconds(500))
            let second = try capture(queue, connection: unrelated, timeout: timeout)
            #expect(queue.enqueue(ticket, connection: nil, target: RecipientTestRig.target, { true }) == .pending)
            queue.resolve(second, targets: [])
            await session.queueTestCommit(context.id, committed: true)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "uncovered retry plays after requestPending") == audio)
            #expect(queue.outstandingCount == 0 && rig.details("reply_audio_skipped").isEmpty)
            #expect(rig.details("reply_audio_refused") == [
                "reason=requestPending request=\(context.id.uuidString) ticket=\(ticket.position)"
            ])
            try await rig.pair.boundedBarrier(step: "requestPending retry publishes once")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
    private func capture(
        _ queue: ReplyAudioQueue, connection: UUID, timeout: QueuedAudioGate
    ) throws -> ReplyAudioQueue.Stop {
        try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
    }
    @Test func requestPendingPreservesTicketForSameFrameRetry() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
            let peer = try #require(await listener.peers.values.first)
            let session = await peer.session
            let audio = recipientAudio(recipientDescriptor(context, audio: true), sequence: 0, final: true)
            let ticket = try await queuedAudioTicket(listener)
            await session.queueTestCommit(context.id, committed: false)
            for _ in 0..<2 {
                await #expect(throws: LocalReplyRefusal.requestPending) {
                    try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio))
                }
                #expect(queue.valid(ticket))
                #expect(queue.outstandingCount == 1)
            }
            #expect(rig.details("reply_audio_refused") == Array(repeating:
                "reason=requestPending request=\(context.id.uuidString) ticket=\(ticket.position)", count: 2))
            await session.queueTestCommit(context.id, committed: true)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "same-frame retry succeeds once") == audio)
            #expect(!queue.valid(ticket))
            try await rig.pair.boundedBarrier(step: "no retry duplicate")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
extension HostSession {
    fileprivate func queueTestCommit(_ request: UUID, committed: Bool) { replyRequests[request]?.committed = committed }
}
#endif
