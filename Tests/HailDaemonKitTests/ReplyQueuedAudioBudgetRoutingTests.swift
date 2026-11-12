#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioBudgetRoutingTests {
    @Test func routingRaceExhaustsSharedBudgetAndKeepsCorrelatedText() async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate()
        let enqueue = VoiceStopConfirmationHold(), routed = VoiceStopConfirmationHold()
        let waiting = VoiceStopConfirmationHold()
        defer { clock.release(); timeout.release(); enqueue.release() }
        let rig = try await clock.makeRig()
        var publication: Task<LocalReplyAudioReport, any Error>?
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
            let reply = recipientDescriptor(context, audio: true)
            let text = queuedTextCard(reply), audio = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "correlated card retained") == text)
            let ticket = try await queuedAudioTicket(listener)
            publication = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                    try await ReplyAudioEnqueueTesting.$beforeEnqueue.withValue({
                        routed.release(); await enqueue.wait()
                    }, operation: {
                        try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                    })
                })
            }
            await routed.wait()
            try await exhaust(queue, clock: clock, timeout: timeout, enqueue: enqueue, waiting: waiting)
            #expect(try await publication?.value == LocalReplyAudioReport(skipped: true, reason: "wait_budget"))
            #expect(rig.details("reply_audio_skipped")
                == ["reason=wait_budget request=\(context.id.uuidString) ticket=\(ticket.position)"])
            #expect(!queue.valid(ticket)); try await rig.pair.boundedBarrier(step: "wait-budget audio never published")
        } catch {
            enqueue.release(); clock.release(); publication?.cancel()
            _ = try? await publication?.value
            await rig.finish(); throw error
        }
        await rig.finish()
    }
}

extension ReplyQueuedAudioBudgetRoutingTests {
    private func exhaust(
        _ queue: ReplyAudioQueue, clock: QueuedAudioClock, timeout: QueuedAudioGate,
        enqueue: VoiceStopConfirmationHold, waiting: VoiceStopConfirmationHold
    ) async throws {
        let unrelated = UUID()
        queue.register(unrelated)
        defer { queue.forget(unrelated) }
        let first = try capture(queue, unrelated, timeout)
        enqueue.release()
        await waiting.wait() // The routed publication hit .pending at its final enqueue and registered the retry.
        await clock.sleepEntered.wait()
        clock.advance(.milliseconds(125))
        let second = try capture(queue, unrelated, timeout)
        queue.resolve(first, targets: ["unrelated"])
        clock.advance(.milliseconds(125))
        clock.release() // Wakes the existing waiter even though the second successful stop is still unresolved.
        // The shared deadline expires while the second stop still has unknown associations.
        // The second unknown stop remains pending through the refusal.
        _ = second
    }
    private func capture(
        _ queue: ReplyAudioQueue, _ connection: UUID, _ timeout: QueuedAudioGate
    ) throws -> ReplyAudioQueue.Stop {
        try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
    }
}
#endif
