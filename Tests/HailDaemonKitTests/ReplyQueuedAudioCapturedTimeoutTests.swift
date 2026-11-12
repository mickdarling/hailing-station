#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioCapturedTimeoutTests {
    @Test(arguments: [false, true])
    func heldStopSendUsesCapturedScopeOnly(capture: Bool) async throws {
        let clock = QueuedAudioClock()
        let rig = try await clock.makeRig()
        let timeout = VoiceStopConfirmationHold(), wire = VoiceStopConfirmationHold()
        let entered = VoiceStopConfirmationHold(), waiting = VoiceStopConfirmationHold()
        var stopping: Task<String, Never>?
        defer { timeout.release(); wire.release(); clock.release() }
        do {
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let original = try #require(await listener.peers.values.first)
            let connection = await original.session.connectionID
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target, "recipient:other"])
            defer { other.close() }
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let covered = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let uncovered = recipientAudio(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other",
                audioStreamID: UUID()), sequence: 0, final: true)
            let oldT = try #require(await listener.replyAudio(.init(action: "enqueue", frame: covered)).ticket)
            let oldU = try #require(await listener.replyAudio(.init(action: "enqueue", frame: uncovered)).ticket)
            stopping = heldStop(listener, connection: connection, capture: capture,
                holds: CapturedStopHolds(timeout: timeout, wire: wire, entered: entered))
            await entered.wait()
            if capture {
                #expect(try await receiveFrame(on: rig.socket, step: "immediate cut before held send completes")
                    .payload == .control(.stopPlayback))
            }
            try await expire(queue, ticket: oldT, waiting: waiting, timeout: timeout, clock: clock)
            try await verify(listener, audio: covered, ticket: oldT, skipped: true, socket: other.sockets[0])
            try await verify(listener, audio: uncovered, ticket: oldU, skipped: !capture, socket: other.sockets[1])
            wire.release()
            #expect(await stopping?.value == "stopped")
            try await other.boundedBarrier(step: "only covered pre-cutoff audio is silent after full capture")
        } catch {
            wire.release(); timeout.release(); _ = await stopping?.value
            await rig.finish(); throw error
        }
        await rig.finish()
    }
}

extension ReplyQueuedAudioCapturedTimeoutTests {
    private func heldStop(
        _ listener: WebSocketListener, connection: UUID, capture: Bool,
        holds: CapturedStopHolds
    ) -> Task<String, Never> {
        let timeout = holds.timeout, wire = holds.wire, entered = holds.entered
        let hold: @Sendable () async -> Void = { entered.release(); await wire.wait() }
        let before: (@Sendable () async -> Void)? = capture ? nil : hold
        let after: (@Sendable () async -> Void)? = capture ? hold : nil
        return Task {
            await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue(before, operation: {
                    await ReplyAudioEnqueueTesting.$afterStopSend.withValue(after, operation: {
                        await listener.stopReplyPlayback(connection: connection, markQueuedAudio: true)
                    })
                })
            })
        }
    }
    private func expire(
        _ queue: ReplyAudioQueue, ticket: LocalReplyAudioTicket,
        waiting: VoiceStopConfirmationHold, timeout: VoiceStopConfirmationHold, clock: QueuedAudioClock
    ) async throws {
        let barrier = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(ticket)
            })
        }
        await waiting.wait()
        clock.advance(.milliseconds(250))
        timeout.release() // Drive timeout after a full deadline while the send completion is still held.
        try await barrier.value
    }
    private func verify(
        _ listener: WebSocketListener, audio: Frame, ticket: LocalReplyAudioTicket,
        skipped: Bool, socket: URLSessionWebSocketTask
    ) async throws {
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
            == LocalReplyAudioReport(skipped: skipped))
        if !skipped { #expect(try await receiveFrame(on: socket, step: "uncovered U plays") == audio) }
    }
}
private struct CapturedStopHolds: Sendable {
    let timeout: VoiceStopConfirmationHold
    let wire: VoiceStopConfirmationHold
    let entered: VoiceStopConfirmationHold
}
#endif
