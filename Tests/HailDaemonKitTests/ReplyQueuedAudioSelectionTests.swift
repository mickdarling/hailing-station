#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioSelectionTests {
    @Test(arguments: ["playback", "device", "privacy"])
    func selectionAfterCaptureKeepsOriginalTargetOnly(source: String) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let holds = SelectionStopHolds()
        var stopping: Task<Void, Never>?
        defer { holds.release() }
        do {
            if source != "playback" { try await rig.start() }
            let listener = rig.env.listener
            let peer = try #require(await listener.peers.values.first)
            let connection = await peer.session.connectionID
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target, "recipient:other"])
            defer { other.close() }
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let reply = uncorrelatedDescriptor(audio: true), text = recipientText(reply)
            // Deliver before issuing the audio-only ticket: it has neither a text destination nor a flight.
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: other.sockets[0], step: "B retains text") == text)
            let audio = recipientAudio(reply, sequence: 0, final: true)
            let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            let unrelated = try await queuedOtherTarget(on: other, listener: listener)
            stopping = Task { await stop(source, rig: rig, connection: connection, holds: holds) }
            await holds.entered.wait()
            if source != "privacy" {
                #expect(try await receiveFrame(on: rig.socket, step: "A stop before selection")
                    .payload == .control(.stopPlayback))
            }
            try await rig.pair.select("recipient:other", on: 0)
            holds.capture.release()
            await stopping?.value
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: audio)).skipped)
            // U's pre-stop audio really plays on C; the new selection neither marks U nor raises the floor.
            try await playOtherTarget(unrelated, on: other, listener: listener)
            try await playFresh(on: other, listener: listener)
            try await other.boundedBarrier(step: "B retains text without pre-stop audio")
        } catch {
            holds.release()
            await stopping?.value
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func selectionBetweenAcceptanceAndSessionHopRaisesOnlyCutoff(returnToOriginal: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let holds = SelectionStopHolds()
        var stopping: Task<Void, Never>?
        defer { holds.release() }
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            let unrelated = try await queuedAudioTicket(listener)
            let connection = try #require(rig.env.router.activeConnection())
            stopping = holdBeforeSession(rig, connection: connection, holds: holds)
            await holds.entered.wait() // Accepted under the queue lock; no session stop hop has occurred.
            expectStopped(queue, ticket: old, target: RecipientTestRig.target)
            try await rig.pair.select("recipient:other", on: 0)
            if returnToOriginal { try await rig.pair.select(RecipientTestRig.target, on: 0) }
            holds.capture.release()
            await stopping?.value
            #expect(try await receiveFrame(on: rig.socket, step: "A stop after selection")
                .payload == .control(.stopPlayback))
            // An unrelated target proves the floor, rather than only the original target mark, was raised.
            expectStopped(queue, ticket: unrelated, target: "unrelated:floor-proof")
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: audio)).skipped)
            try await playFresh(on: other, listener: listener)
            try await other.boundedBarrier(step: "B pre-cutoff audio silent")
        } catch {
            holds.release()
            await stopping?.value
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}

extension ReplyQueuedAudioSelectionTests {
    private func holdBeforeSession(
        _ rig: DeviceVoiceStopRig, connection: UUID, holds: SelectionStopHolds
    ) -> Task<Void, Never> {
        Task {
                await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await holds.timeout.wait() }, operation: {
                    await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                        holds.entered.release(); await holds.capture.wait()
                    }, operation: {
                        await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
                    })
                })
            }
    }

    private func stop(
        _ source: String, rig: DeviceVoiceStopRig, connection: UUID, holds: SelectionStopHolds
    ) async {
        let captured: @Sendable () async -> Void = {
            holds.entered.release(); await holds.capture.wait()
        }
        await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await holds.timeout.wait() }, operation: {
            await ReplyAudioEnqueueTesting.$afterStopSend.withValue(source == "privacy" ? nil : captured, operation: {
                await ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue(
                    source == "privacy" ? captured : nil, operation: {
                        switch source {
                        case "privacy": rig.env.router.holdReplies(connection, listener: rig.env.listener)
                        case "device": await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
                        default:
                            _ = await rig.env.listener.stopReplyPlayback(connection: connection, markQueuedAudio: true)
                        }
                    }
                )
            })
        })
        if source == "privacy" {
            await rig.env.router.mediaNotices.queued {}.value
        }
    }

    private func playOtherTarget(
        _ unrelated: (LocalReplyAudioTicket, Frame), on other: FallbackSocketPair, listener: WebSocketListener
    ) async throws {
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: unrelated.0, frame: unrelated.1))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: other.sockets[1], step: "C pre-stop U plays") == unrelated.1)
    }
    private func queuedOtherTarget(
        on pair: FallbackSocketPair, listener: WebSocketListener
    ) async throws -> (LocalReplyAudioTicket, Frame) {
        try await recipientSocketSend(sessionFrame(target: "recipient:other",
            payload: .text(TextPayload(text: "synthetic U input"))), on: pair.sockets[1])
        try await recipientSocketBarrier(on: pair.sockets[1], step: "C owns U input")
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other", audioStreamID: UUID())
        let audio = recipientAudio(reply, sequence: 0, final: true)
        let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
        return (ticket, audio)
    }
    private func expectStopped(_ queue: ReplyAudioQueue, ticket: LocalReplyAudioTicket, target: String) {
        if case .stopped = queue.enqueue(ticket, connection: nil, target: target, { true }) {} else {
            Issue.record("pre-cutoff target must be silent")
        }
    }
    private func playFresh(on pair: FallbackSocketPair, listener: WebSocketListener) async throws {
        let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
        let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[0], step: "B post-stop T plays") == audio)
    }
}

private struct SelectionStopHolds: Sendable {
    let capture = VoiceStopConfirmationHold()
    let entered = VoiceStopConfirmationHold()
    let timeout = VoiceStopConfirmationHold()
    func release() { capture.release(); timeout.release() }
}
#endif
